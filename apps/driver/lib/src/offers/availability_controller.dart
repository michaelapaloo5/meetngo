import 'package:flutter/foundation.dart';
import 'package:mng_core/mng_core.dart';

import '../data/driver_repository.dart';

/// The online toggle, and the one refusal that matters.
///
/// `onTrip` is the third value of `driver_availability` and nothing in the plan
/// ever wrote it. That left a driver who accepted an offer still reading
/// `availability = 'online'`, which is the exact value
/// `match_offers_for_trip` filters on, so the same driver could be fanned
/// another trip's offer while already driving one. [beginTrip] and [endTrip] are
/// the two halves of that, and they are on this class rather than in the shell
/// because the invariant is about the driver's availability, not about which
/// screen happens to be showing.
class AvailabilityController extends ChangeNotifier {
  /// [online] seeds the toggle for a test that needs "this driver is already on
  /// the queue" without a repository write first. Production goes through
  /// [adoptStored], which reads the value the server actually holds.
  ///
  /// It is a constructor argument rather than a public setter on [online] on
  /// purpose: a setter would let any screen move the toggle without passing the
  /// refusal in [setOnline], which is the one thing the toggle must not skip.
  ///
  /// The initialising form is unavailable -- Dart has no private named
  /// parameters, so a named seed cannot be written `this._online`.
  // ignore: prefer_initializing_formals
  AvailabilityController(this._repo, {bool online = false}) : _online = online;

  final DriverRepository _repo;

  bool _online;
  bool get online => _online;

  bool _busy = false;
  bool get busy => _busy;

  String? error;

  /// Why the driver was not allowed to do the thing they just asked to do.
  String? refusalReason;

  /// Set while a trip is holding the driver off the queue, so [endTrip] knows
  /// to put them back.
  bool _resumeWhenTripEnds = false;

  /// Reads the value the server already holds, on load.
  ///
  /// `onTrip` counts as a resume: a driver whose phone died mid-trip comes back
  /// to a profile that says `onTrip`, and the trip they are still on is what
  /// the shell re-reads, so the resume flag has to be set from the stored value
  /// rather than from whether this session saw the accept.
  void adoptStored(DriverAvailability stored) {
    _online = stored == DriverAvailability.online;
    _resumeWhenTripEnds = stored == DriverAvailability.online ||
        stored == DriverAvailability.onTrip;
    notifyListeners();
  }

  bool get canToggle => !_busy;

  /// Goes online or offline, or refuses.
  ///
  /// Going offline is the only refused direction. A driver who is mid-trip
  /// cannot leave the queue, because the matcher would stop seeing them while
  /// they are still carrying a rider, and because the trip screen and the home
  /// screen would then disagree about what the driver is doing.
  Future<bool> setOnline(bool value) async {
    error = null;
    refusalReason = null;

    if (!value) {
      final Trip? active;
      try {
        active = await _repo.activeTrip();
      } on DriverAuthFailure catch (e) {
        error = 'Could not check your current trip: ${e.message}';
        notifyListeners();
        return false;
      }
      if (active != null && active.state.isActive) {
        refusalReason = 'Finish or cancel your current trip before going offline';
        notifyListeners();
        return false;
      }
    }

    _busy = true;
    notifyListeners();
    try {
      await _repo.setAvailability(
        value ? DriverAvailability.online : DriverAvailability.offline,
      );
      _online = value;
      if (value) await _publishLocation();
      return true;
    } on DriverAuthFailure catch (e) {
      error = e.message;
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// The driver accepted an offer, so they are no longer available for another.
  Future<void> beginTrip() async {
    if (!_online) return;
    _online = false;
    try {
      await _repo.setAvailability(DriverAvailability.onTrip);
    } on DriverAuthFailure catch (e) {
      error = 'Trip accepted, but going off the queue failed: ${e.message}';
    }
    notifyListeners();
  }

  /// The trip is over, so put the driver back on the queue if they chose to be
  /// on it.
  ///
  /// Only does anything when a trip actually held them, so finishing a trip as
  /// an offline driver does not silently put them online.
  Future<void> endTrip() async {
    if (!_resumeWhenTripEnds) return;
    _resumeWhenTripEnds = false;
    _online = true;
    try {
      await _repo.setAvailability(DriverAvailability.online);
      await _publishLocation();
    } on DriverAuthFailure catch (e) {
      error = 'Trip finished, but going back online failed: ${e.message}';
    }
    notifyListeners();
  }

  /// Publishes a position, so `match_offers_for_trip` can see this driver at
  /// all: it requires `exists (select 1 from driver_locations l where
  /// l.driver_id = d.id)`, and a driver who has never published one is
  /// invisible to the matcher however online and approved they are.
  ///
  /// A failure here is reported and does not undo going online. The
  /// availability write has already succeeded, the driver is genuinely online,
  /// and the only thing lost is their position -- which they can retry from the
  /// toggle. Failing the whole toggle would report a refusal the server did not
  /// make.
  ///
  /// Both ways this can go wrong are named, because a driver who is online and
  /// invisible to the matcher waits for requests that cannot arrive and the
  /// screen said nothing:
  ///  * no position at all -- location is off, or the permission was refused.
  ///    `currentLocation` answers null rather than throwing, so a `try` with only
  ///    a catch reports the throwing case and misses this one;
  ///  * a position that would not publish -- the write is refused.
  Future<void> _publishLocation() async {
    GeoPoint? here;
    try {
      here = await _repo.currentLocation();
    } on Object {
      // Same message as a null: either way there is no position to publish.
    }
    if (here == null) {
      error = 'Your location is not available, so ride requests cannot reach you';
      notifyListeners();
      return;
    }
    try {
      await _repo.updateLocation(here);
    } on Object {
      error = 'Your location could not be published, so ride requests cannot '
          'reach you';
      notifyListeners();
    }
  }
}
