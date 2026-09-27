import 'package:flutter/foundation.dart';
import 'package:mng_core/mng_core.dart';
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
  TrackingController({
    required this.trips,
    required Trip initialTrip,
    DriverProfile? initialDriver,
  })  : _trip = initialTrip,
        // Seeded from the trip and not invented. `Trip.etaMinutes` is parsed
        // from the row's `eta_minutes` (`mng_core/lib/src/models/trip.dart:51`)
        // and is what the driver app writes as it moves, so the badge has to
        // show that number or nothing. This used to start null, which meant the
        // `EtaBadge` could not render until the first `refresh`, and `refresh`
        // then overwrote the row's number with a hardcoded 4.
        etaMinutes = initialTrip.etaMinutes,
        driver = initialDriver;

  final TripRepository trips;

  Trip? _trip;
  Trip? get trip => _trip;

  DriverProfile? driver;
  Vehicle? driverVehicle;

  /// The ETA the pill renders, or null when the row does not carry one. Mirrored
  /// from `Trip.etaMinutes` and never fabricated: a live-tracking screen that
  /// shows a constant number is worse than one that shows none.
  int? etaMinutes;
  bool sosRaised = false;
  String? error;

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

  Future<void> refresh() async {
    error = null;
    try {
      final fresh = await trips.activeTrip();
      // A null active trip is not a reason to skip the notification. The
      // `error = null` above is already a state change, and returning before
      // `notifyListeners` would clear it in the model while the red line stayed
      // on screen until some *other* call happened to repaint.
      if (fresh != null) {
        _trip = fresh;
        // The row's own ETA, in both directions: a driver that was 7 minutes out
        // and is now 2 has to show 2, and a row that stops carrying one has to
        // stop showing a pill. The two `== TripState.arriving` /
        // `== TripState.matched` branches that used to assign a literal 4 were
        // the whole of the old behaviour and they were never read off anything.
        etaMinutes = fresh.etaMinutes;
      }
    } on Exception catch (e) {
      // The trip on screen is left as it was: a failed read is not evidence
      // about the trip, and replacing it with nothing would take the screen's
      // whole reason to exist away.
      _report(e);
    }
    notifyListeners();
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

  Future<void> raiseSos() async {
    if (sosRaised) return;
    final current = _trip;
    if (current == null) return;
    error = null;
    sosRaised = true;
    notifyListeners();
    try {
      await trips.raiseSos(current.id, 'Rider pressed the safety button');
    } on Exception catch (e) {
      // Rolled back, not left standing. The banner is driven by the optimistic
      // `notifyListeners()` above, so once this round trip is in flight the
      // screen is reading "Help is on the way", and a rider told help is coming
      // when no row reached `sos_events` is the outcome this whole path exists
      // to prevent. Back to false, so the button is live again and the rider can
      // press it a second time.
      sosRaised = false;
      _report(e);
    }
    notifyListeners();
  }

  void _report(Exception e) {
    error = e is TripRequestFailure ? e.message : _unreachable;
  }
}
