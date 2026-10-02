import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mng_core/mng_core.dart';

import '../data/location_service.dart';
import '../data/trip_repository.dart';

/// What the tracking screen reads and what every button on it calls.
///
/// The three methods are the screen's only outlets, so an exception escaping
/// any of them reaches the framework as an unhandled async error rather than as
/// anything the rider can read. All three therefore catch, all three repaint
/// whatever they decided -- including the paths that decide nothing, because a
/// model that changed without a `notifyListeners` is a screen showing yesterday's
/// state -- and `error` is what `TrackingScreen` paints in red.
class TrackingController extends ChangeNotifier {
  TrackingController({required this.trips, required Trip initialTrip})
    : _trip = initialTrip,
      // Seeded from the trip and not invented. `Trip.etaMinutes` is parsed
      // from the row's `eta_minutes` (`mng_core/lib/src/models/trip.dart:51`)
      // and is what the driver app writes as it moves, so the badge has to
      // show that number or nothing. This used to start null, which meant the
      // `EtaBadge` could not render until the first `refresh`, and `refresh`
      // then overwrote the row's number with a hardcoded 4.
      etaMinutes = initialTrip.etaMinutes {
    // The trip this is built with may already name a driver -- and in
    // production it does: the shell constructs this controller at the moment a
    // driver is assigned, so `initialTrip.driverId` is set and the
    // "has the driver changed?" test in `sync` is false from the first poll on.
    //
    // Without this the driver card is never looked up at all, which is the state
    // the card was in before any of this: `driver` and `driverVehicle` could
    // never be filled, so the guard above the card never passed and the rider
    // saw nothing for the whole ride.
    //
    // Fire and forget because a constructor cannot await. It is not an unhandled
    // error waiting to happen: `loadDriverContact` catches everything it can be
    // handed and records the message instead.
    unawaited(loadDriverContact());
  }

  final TripRepository trips;

  Trip? _trip;
  Trip? get trip => _trip;

  /// The assigned driver's own details, as far as the `contact` function will
  /// tell a rider.
  ///
  /// Null until the lookup succeeds. `DriverProfile` and `Vehicle` were the types
  /// here once and could never be filled: `profiles` is readable only by its
  /// owner and `vehicles` only by their owner, so the rider app cannot construct
  /// either from anything it is allowed to read. Both fields stayed null
  /// forever, the card's guard never passed, and the tests that "proved" the
  /// plate rendered were asserting against fixtures no production path could
  /// produce.
  ///
  /// `DriverContact` is what the `contact` function actually answers with, in
  /// the rider-asking-about-the-driver direction that function was built for and
  /// that this app never called.
  DriverContact? driverContact;

  /// Whether [loadDriverContact] has been asked for and has not answered.
  ///
  /// Separate from [driverContact] being null, because those two states mean
  /// opposite things to the rider: "we are still asking" and "there is nothing
  /// there". Collapsing them is how a screen ends up showing a blank gap where a
  /// driver should be.
  bool driverContactPending = false;

  /// Why the driver lookup failed, or null if it has not failed.
  String? driverContactFailed;

  /// The ETA the pill renders, or null when the row does not carry one. Mirrored
  /// from `Trip.etaMinutes` and never fabricated: a live-tracking screen that
  /// shows a constant number is worse than one that shows none.
  int? etaMinutes;
  bool sosRaised = false;
  String? error;

  /// The device's last known position, for the map's "you are here" pin and
  /// its rider-facing note when there is no fix.
  ///
  /// Null until the first [refresh], and null on a trip screen is not a bug:
  /// the map is still correct, because it is fitted to the trip's own pickup
  /// and dropoff rather than to the rider. Kept separate from [error] on
  /// purpose — a refused location permission is not a failed trip, and putting
  /// it in [error] would paint a live ride's screen red for something the
  /// rider can fix in Settings without the ride being affected.
  DeviceLocation? location;

  /// Where the driver assigned to this trip is, and which way it is facing.
  ///
  /// Null until a driver is assigned and has published a position. The rider's
  /// map draws this as a car pointing the way the driver is driving, because
  /// the thing they are watching is a vehicle arriving: a dot is the same mark
  /// used for "this is you", and it has no way of showing which way the driver
  /// is approaching from.
  ///
  /// Only ever advanced, never cleared -- see the read in [refresh].
  VehicleFix? driverPoint;

  /// Whether the driver card has been looked up for the *current* driver.
  ///
  /// A bool rather than "is [driverContact] null", because a driver who leaves
  /// and is replaced mid-ride would otherwise keep the first driver's name,
  /// photo and plate -- the one case where showing stale data is worse than
  /// showing none, since the rider would be looking for the wrong car.
  bool _contactIsForCurrentDriver = false;

  /// Which driver [driverContact] was fetched for.
  String? _contactDriverId;

  /// Call the assigned driver, if there is anything to call.
  ///
  /// Returns the contact rather than dialling, because *what* to do with a
  /// number is the screen's decision, not the model's: offering the dialler,
  /// the clipboard and a full-screen read of the digits is the rider app's copy
  /// of the driver's own contact sheet, and putting it here would make this
  /// class know about sheets.
  ///
  /// Null when no driver is assigned yet, when the lookup has not finished, or
  /// when it failed -- and in all three the caller has something to *say*, which
  /// is why this is a nullable answer rather than a thrown error.
  DriverContact? get callableDriver {
    final contact = driverContact;
    if (contact == null || !_contactIsForCurrentDriver) return null;
    return contact.callable ? contact : null;
  }

  /// The number to read out when it cannot be dialled.
  ///
  /// Separate from [callableDriver] because "this driver has no phone number"
  /// and "we do not have their details yet" need different sentences, and a
  /// rider told the first when it is really the second will not enter a number
  /// that does not exist.
  DriverContact? get knownDriver {
    final contact = driverContact;
    if (contact == null || !_contactIsForCurrentDriver) return null;
    return contact;
  }

  /// How many times [refresh] has run. The location read is skipped until the
  /// trip read has succeeded, because asking the OS for a fix before the map
  /// has anything to draw it on spends a permission prompt on nothing.
  bool _tripReadAtLeastOnce = false;

  /// The message for a call that never reached the server. `raiseSos` and
  /// `activeTrip` are direct PostgREST requests, so a dropped connection
  /// surfaces as the raw exception postgrest does not convert, and naming that
  /// type here would mean importing `package:http/http.dart` — `http` is
  /// `dependency: transitive` in `pubspec.lock` and is not in `pubspec.yaml`, so
  /// the import is a `depend_on_referenced_packages` info, which is fatal under
  /// the `--fatal-infos` this repo's CI runs. `http`'s `ClientException` is
  /// declared `implements Exception` (`http-1.6.0/lib/src/exception.dart:6`),
  /// so `on Exception` is the clause that catches it. `TypeError` is an `Error`,
  /// not an `Exception`, so a null-assertion fault still escapes rather than
  /// being reported as a network problem.
  static const _unreachable = 'Could not reach the server';

  /// Adopt a fresh row for this trip, then re-read everything that moves.
  ///
  /// Takes the trip as an argument rather than reading it, because the shell
  /// already polls for the trip -- it has to, to decide whether a driver has been
  /// assigned and whether the ride is over. Reading it a second time here would
  /// double the API traffic of a live ride to get the same answer twice, and on a
  /// metered Ghanaian connection that is a real cost, not a rounding error.
  ///
  /// This method is the one production path, and before it existed there was
  /// none: [refresh] was correct, was unit-tested, and had **zero callers in
  /// `lib/`**. The shell built this controller inside a
  /// `ChangeNotifierProvider(create:)`, which runs once, and then refreshed
  /// `_trip` in its own `State` -- so this controller's `_trip` stayed frozen at
  /// the value it was constructed with for the whole ride.
  ///
  /// Everything the rider was missing came from that one fact:
  ///
  /// - the headline never left `matched`, because it reads `_trip.state`
  /// - the pickup OTP panel never appeared, because it is gated on
  ///   `trip.state == TripState.arriving`
  /// - the driver's car was never drawn, because [driverPoint] is only read in
  ///   [_readDriverPosition], which only [refresh] called -- and the car looked
  ///   broken on a ride that was working perfectly
  /// - the ETA pill was pinned to the number from the moment of matching
  Future<void> sync(Trip fresh) async {
    // A driver who appears part-way through a trip -- re-matched, or the rider
    // opened the screen before the match landed -- has never been looked up.
    // "Changed", not "gained": a driver who leaves and is replaced has to be
    // looked up again, and comparing only against null would keep the first
    // driver's card on screen for the rest of the ride.
    final gainedDriver = fresh.driverId != _trip?.driverId;
    _trip = fresh;
    etaMinutes = fresh.etaMinutes;
    await _readLocation();
    await _readDriverPosition();
    if (gainedDriver) await loadDriverContact();
    notifyListeners();
  }

  /// Fetch the driver's name, photo and car for the tracking card.
  ///
  /// Idempotent and cheap to repeat: the answer does not change during a ride,
  /// so once loaded this is a no-op unless it has failed. That matters because
  /// [sync] runs every three seconds for the length of the trip, and a rider
  /// should not cost a round trip every three seconds for a fact that cannot
  /// have changed.
  Future<void> loadDriverContact() async {
    final trip = _trip;
    final driverId = trip?.driverId;
    final tripId = trip?.id;
    if (tripId == null || driverId == null) return;
    if (driverContactPending) return;
    // Only skip when the card on screen is already this driver's. The driver id
    // is captured *before* the await rather than read off `_trip` after it,
    // because a re-match during the round trip would otherwise let a late answer
    // for the previous driver overwrite the new one's.
    final alreadyHaveThisDriver =
        _contactIsForCurrentDriver && _contactDriverId == driverId;
    if (alreadyHaveThisDriver) return;
    driverContactPending = true;
    driverContactFailed = null;
    notifyListeners();
    try {
      final answer = await trips.driverContact(tripId);
      if (_trip?.driverId != driverId) {
        // The driver changed while this was in flight. Discarded rather than
        // shown: the rider would be reading one driver's plate and looking for
        // another's car.
        return;
      }
      driverContact = answer;
      _contactDriverId = driverId;
      _contactIsForCurrentDriver = true;
    } on TripRequestFailure catch (e) {
      // Kept as a message rather than folded into `error`. `error` paints the
      // whole screen red, and a rider whose driver card could not load is not
      // in a failed ride -- they are in a ride where one panel failed, and the
      // difference matters when they are deciding whether to press Cancel.
      driverContactFailed = e.message;
    } on Exception {
      driverContactFailed = 'We could not get your driver\'s details.';
    } finally {
      driverContactPending = false;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    error = null;
    // Declared here rather than inside the `try`, because the `catch` below
    // returns having left it false, and `loadDriverContact` after the catch
    // still needs to know whether a driver was newly assigned.
    var gainedDriver = false;
    try {
      final fresh = await trips.activeTrip();
      // A null active trip is not a reason to skip the notification. The
      // `error = null` above is already a state change, and returning before
      // `notifyListeners` would clear it in the model while the red line stayed
      // on screen until some *other* call happened to repaint.
      if (fresh != null) {
        // Assigned to the outer variable, not shadowed. A local here would be a
        // second binding with the same name and the `if` at the bottom would
        // read the outer one, which is always false -- so the driver card would
        // never load and nothing would say why.
        gainedDriver = fresh.driverId != _trip?.driverId;
        _trip = fresh;
        // The row's own ETA, in both directions: a driver that was 7 minutes out
        // and is now 2 has to show 2, and a row that stops carrying one has to
        // stop showing a pill. The two `== TripState.arriving` /
        // `== TripState.matched` branches that used to assign a literal 4 were
        // the whole of the old behaviour and they were never read off anything.
        etaMinutes = fresh.etaMinutes;
      }
      _tripReadAtLeastOnce = true;
    } on Exception catch (e) {
      // The trip on screen is left as it was: a failed read is not evidence
      // about the trip, and replacing it with nothing would take the screen's
      // whole reason to exist away.
      _report(e);
    }
    if (_tripReadAtLeastOnce) {
      await _readLocation();
      await _readDriverPosition();
    }
    // Same reason as in `sync`: a driver who has just appeared has never been
    // looked up, and the card would otherwise sit empty for the whole ride.
    if (gainedDriver) await loadDriverContact();
    notifyListeners();
  }

  /// Reads the device position for the map.
  ///
  /// Every failure is swallowed on purpose and the previous reading is kept:
  /// a location that cannot be read is a map without a blue dot, and the trip
  /// underneath it is unaffected. Letting a `SocketException` or a platform
  /// channel error out of here would reach the framework as an unhandled async
  /// error on a screen the rider is relying on to find their car.
  Future<void> _readLocation() async {
    try {
      location = await trips.locate();
    } on Object {
      // Left as it was.
    }
  }

  /// Reads where the assigned driver is, so the car can be drawn on the map.
  ///
  /// Same contract as [_readLocation]: failures are swallowed and the last good
  /// position is kept, because a car that stops updating for one poll is a car
  /// that is still where it was, and a car that vanishes is worse than one that
  /// lags. The database decides whether this is readable at all -- the
  /// `rider reads driver location while assigned` policy allows it only while a
  /// trip of the rider's is live with that driver on it -- so before a driver is
  /// assigned this is null by policy, not by a check here.
  Future<void> _readDriverPosition() async {
    try {
      final read = await trips.assignedDriverLocation(trip?.driverId);
      // Only ever advanced, never cleared on a null. A driver whose phone has
      // no fix this second is still somewhere on the last road they were on,
      // and blanking the car because one poll came back empty would make the
      // map flicker through the whole ride.
      //
      // The same applies to the heading, and it is why the previous fix is kept
      // rather than replaced by a bearing-less one: a car whose heading drops
      // to north mid-junction looks like it turned around, which is the one
      // thing a rider watching it approach would be certain of and wrong about.
      if (read != null && read.bearing != null) driverPoint = read;
    } on Object {
      // Left as it was.
    }
  }

  Future<void> cancel() async {
    final current = _trip;
    if (current == null) return;
    error = null;
    if (!canTransition(current.state, TripState.cancelled)) {
      error = 'This trip can no longer be cancelled';
      notifyListeners();
      return;
    }
    try {
      await trips.cancelTrip(current.id);
    } on Exception catch (e) {
      // State is not touched, so the cancel button stays live and the rider can
      // try again. `cancel-trip` answers a trip it will not cancel with a 409,
      // which reaches here as a `TripRequestFailure` carrying that function's
      // own `error` string.
      _report(e);
      notifyListeners();
      return;
    }
    // `clearDriver: true`, and not `driverId: null`: `copyWith` keeps the
    // existing driver whenever `driverId` is null, because null is also the
    // value that means "unchanged" (`mng_core/lib/src/models/trip.dart:77`). A
    // cancelled trip that still names its driver is a trip a driver-side
    // screen would offer to act on.
    _trip = current.copyWith(state: TripState.cancelled, clearDriver: true);
    notifyListeners();
  }

  /// Raise the safety alert, and say whether it landed.
  ///
  /// Returns whether a row reached `sos_events`, because the caller needs to
  /// tell the rider so. It used to return `void` and paint an optimistic
  /// banner, which meant a rider could be told "Help is on the way" for an alert
  /// that was rolled back a moment later -- and a safety feature that lies about
  /// whether it fired is worse than one that does not fire.
  ///
  /// False when there is no trip, when it has already been raised, or when the
  /// write failed. All three are answers the caller can act on.
  Future<bool> raiseSos() async {
    if (sosRaised) return false;
    final current = _trip;
    if (current == null) return false;
    error = null;
    sosRaised = true;
    notifyListeners();
    try {
      await trips.raiseSos(current.id, 'Rider pressed the safety button');
      return true;
    } on Exception catch (e) {
      // Rolled back, not left standing, so the button is live again and the
      // rider can press it a second time.
      sosRaised = false;
      _report(e);
      return false;
    } finally {
      notifyListeners();
    }
  }

  void _report(Exception e) {
    error = e is TripRequestFailure ? e.message : _unreachable;
  }
}
