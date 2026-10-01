import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mng_core/mng_core.dart';

import '../data/driver_repository.dart';
import 'location_reader.dart';

/// Where the driver's own position stands.
///
/// Six named outcomes, because the four answers [LocationReader] can give do
/// not collapse into "got it" and "did not". A driver whose location is off, a
/// driver who refused the prompt, a driver who refused it permanently, a driver
/// whose phone is still looking for a satellite, and a driver with no idea why
/// all need a different sentence, and picking one of them wrongly tells the
/// driver to do something that cannot help.
enum DriverLocationStatus {
  /// Nothing has been asked yet.
  idle,

  /// The chain of checks is running.
  asking,

  /// A fix is in hand.
  ready,

  /// Location is switched off for the device.
  serviceOff,

  /// The prompt was shown this session and refused.
  denied,

  /// The prompt was refused permanently; the OS will not show it again.
  deniedForever,

  /// Permitted, but no fix has arrived.
  noFix,

  /// Something failed that is none of the above.
  failed,
}

/// The driver's position, as state a screen can read and a test can drive.
///
/// A position is asked for once per [refresh] and nowhere else, and every
/// outcome is a named [status] with a [message] the driver can act on. The
/// screen never has to interpret an exception, and there is no path where
/// [status] is [DriverLocationStatus.asking] and nothing else is happening: the
/// four checks are in a fixed order and each one ends the chain.
///
/// A fix that arrives is published to `driver_locations` as well as kept here,
/// because `match_offers_for_trip` requires
/// `exists (select 1 from driver_locations l where l.driver_id = d.id)`. A
/// driver the map can draw is not automatically a driver the matcher can see,
/// and the two are written from the same reading so they cannot disagree.
class LocationController extends ChangeNotifier {
  LocationController(this._reader, this._drivers);

  final LocationReader _reader;
  final DriverRepository _drivers;

  DriverLocationStatus _status = DriverLocationStatus.idle;
  DriverLocationStatus get status => _status;

  GeoPoint? _point;
  GeoPoint? get point => _point;

  /// Which way the driver's device is facing, degrees clockwise from north.
  ///
  /// Null whenever the device has no compass to offer: a phone flat on a seat,
  /// a tablet indoors, a simulator. Never defaulted to a number, because the
  /// rider's map rotates their car by it and a fabricated heading puts a car
  /// confidently driving the wrong way down the road.
  double? _heading;
  double? get heading => _heading;

  LocationPermission _permission = LocationPermission.unableToDetermine;
  LocationPermission get permission => _permission;

  String? _failure;
  String? get failure => _failure;

  bool _busy = false;
  bool get busy => _busy;

  /// Whether the last refresh put a position on the map.
  bool get hasFix => _status == DriverLocationStatus.ready && _point != null;

  /// The sentence for [status], or null when there is nothing to explain.
  ///
  /// A getter rather than a stored string so the wording lives in one place and
  /// a test asserting on a message cannot pass against a stale copy of it.
  String? get message => switch (_status) {
    DriverLocationStatus.idle => null,
    DriverLocationStatus.asking => 'Finding your location',
    DriverLocationStatus.ready => null,
    DriverLocationStatus.serviceOff =>
      'Location is switched off on this phone. Turn it on to be shown on '
          'the map and to receive ride requests.',
    DriverLocationStatus.denied =>
      'Meet \'N Go Driver was not allowed to use your location. Allow it in '
          'Settings to be shown on the map and to receive ride requests.',
    DriverLocationStatus.deniedForever =>
      'Location permission is blocked for Meet \'N Go Driver. Turn it on in '
          'Settings, Apps, Meet \'N Go Driver, Permissions.',
    DriverLocationStatus.noFix =>
      'Still looking for your location. Step outside or turn location on, '
          'then try again.',
    DriverLocationStatus.failed => _failure ?? 'Your location is not available',
  };

  /// What the held permission means, for the driver's own benefit.
  ///
  /// `whileInUse` and `always` are both permitted, so neither produces a
  /// refusal, and without this the one case where the app is deliberately
  /// holding a position in the background without saying so is invisible.
  String? get permissionNote => switch (_permission) {
    LocationPermission.whileInUse =>
      'Your location is shared only while Meet \'N Go Driver is open.',
    LocationPermission.always =>
      'Your location is shared with Meet \'N Go Driver at all times.',
    _ => null,
  };

  /// Runs the four checks, in order, and ends at the first refusal.
  Future<void> refresh() async {
    if (_busy) return;
    _busy = true;
    _failure = null;
    _set(DriverLocationStatus.asking);

    try {
      if (!await _reader.isServiceEnabled()) {
        // Checked before the permission, and asked for separately: a driver
        // with location switched off can be prompted for a permission they will
        // never actually use, and the prompt's answer would then be the only
        // thing on screen explaining a map that is empty for a different
        // reason.
        _set(DriverLocationStatus.serviceOff);
        return;
      }

      var permission = await _reader.checkPermission();
      // Re-asked only when the platform still allows it. `denied` means the
      // prompt was refused but the OS will still show it, and
      // `deniedForever` means it will not -- and the OS itself throttles a
      // dialog dismissed a moment ago, so re-asking on a pull-to-refresh
      // cannot make a driver be nagged in a way the platform has not already
      // decided. What the app guarantees is the sentence: a driver who has said
      // no is told where to undo it, which is the only thing that can change
      // the answer.
      if (permission == LocationPermission.denied) {
        permission = await _reader.requestPermission();
      }
      _permission = permission;

      if (permission == LocationPermission.deniedForever) {
        _set(DriverLocationStatus.deniedForever);
        return;
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.unableToDetermine) {
        // `unableToDetermine` is grouped with `denied` rather than treated as
        // permission: it is the answer on a platform that will not say, and
        // there is no fix to be had without it, so the message is the one that
        // tells the driver what to check.
        _set(DriverLocationStatus.denied);
        return;
      }

      final point = await _read();
      if (point == null) {
        _set(DriverLocationStatus.noFix);
        return;
      }
      _point = point;
      // Read separately from the point and never allowed to fail the read: a
      // device with no compass is a perfectly ordinary device, and turning a
      // location refresh into an error because the heading was unavailable
      // would stop a driver from going online at all. A *thrown* read is
      // caught here for the same reason -- a plugin that cannot answer the
      // compass question is not a reason to withhold the position.
      try {
        _heading = normaliseBearing(await _reader.currentHeading());
      } on Object {
        _heading = null;
      }
      _set(DriverLocationStatus.ready);
      await _publish(point);
      // Counted as a publish, so the first fix off the stream does not write the
      // same position again a second later.
      _lastPublishedAt = _clock();
    } on Object catch (e) {
      _failure = 'Your location is not available: $e';
      _set(DriverLocationStatus.failed);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// One fix, or null when none arrived.
  ///
  /// A timeout and an outright failure are separated because they are different
  /// advice: a timeout means the phone is still looking and the driver should
  /// wait or move, and a failure means the plugin could not be asked at all.
  Future<GeoPoint?> _read() async {
    try {
      return await _reader.currentPoint();
    } on TimeoutException {
      return null;
    } on Object {
      return null;
    }
  }

  /// Publishes the fix so the matcher can see this driver at all, with the
  /// heading the device reported alongside it.
  ///
  /// The heading is what the rider's map rotates their car by, so publishing it
  /// is what makes their car visibly turn at each junction rather than sit
  /// pointing north. It goes out even when the position has not changed: a
  /// driver stopped at a set of lights turns on the spot, and a publish
  /// gated on a position change would keep the old heading until they moved.
  ///
  /// A failure here does not un-ready the position. The driver genuinely is
  /// where the map says, and the write is the only thing lost; reporting a
  /// location failure would send them to fix something that is not broken.
  Future<void> _publish(GeoPoint point) async {
    try {
      await _drivers.updateLocation(point, bearing: _heading);
    } on DriverAuthFailure catch (e) {
      _failure =
          'Your location could not be published, so ride requests cannot '
          'reach you: ${e.message}';
    }
  }

  void _set(DriverLocationStatus next) {
    _status = next;
    notifyListeners();
  }

  // ---------------------------------------------------------------- live fixes

  StreamSubscription<GeoFix>? _watching;

  /// Whether [watch] is running.
  bool get watching => _watching != null;

  /// Follow the driver's position from here on.
  ///
  /// Idempotent, because the shell calls it on boot and again whenever it moves
  /// between stages, and two subscriptions would deliver every fix twice.
  ///
  /// This is what makes the dot on the driver's own map *their* location rather
  /// than the location they happened to be at when the app opened. [refresh]
  /// takes a single reading, which is the right answer to "where am I" and the
  /// wrong answer to a question a driver asks continuously for the length of a
  /// trip.
  void watch() {
    if (_watching != null) return;
    _watching = _reader.positionStream().listen(
      _onFix,
      onError: _onWatchError,
      // The plugin closes the stream when location is switched off at the OS
      // level. Dropping the handle means a later [watch] can start again;
      // holding a subscription to a closed stream would leave `watching` true and
      // silently refuse every future attempt.
      onDone: () => _watching = null,
      cancelOnError: false,
    );
  }

  /// Stop following, and release the platform subscription.
  Future<void> unwatch() async {
    final sub = _watching;
    _watching = null;
    await sub?.cancel();
  }

  void _onFix(GeoFix fix) {
    // A permission revoked while the app was open arrives here as an error, and
    // the last position we hold is now a lie the driver is looking at. Held
    // until the next successful fix would keep drawing them somewhere they have
    // left.
    _point = fix.point;
    _heading = fix.heading;
    if (_status != DriverLocationStatus.ready) {
      _status = DriverLocationStatus.ready;
    }
    notifyListeners();
    unawaited(_publishThrottled(fix.point));
  }

  void _onWatchError(Object error) {
    // The stream itself carries no distinction between "permission withdrawn",
    // "location switched off" and "the plugin died", so this reports the same
    // failure the one-shot read does rather than inventing a diagnosis. What it
    // does do is stop claiming to be ready: the driver must not be told their
    // position is good while it is minutes old.
    _failure = 'Your location is not available: $error';
    _set(DriverLocationStatus.failed);
  }

  DateTime? _lastPublishedAt;

  /// How stale a published position may get before another one is sent.
  ///
  /// Fifteen seconds. The matcher needs to know roughly where a driver is to
  /// decide whether to offer them a trip, and a car in Accra covers a lot of
  /// ground in fifteen seconds; publishing every fix instead would mean a write
  /// every second or two for the whole shift, against a free tier, to keep a
  /// number that does not change the answer.
  static const publishInterval = Duration(seconds: 15);

  Future<void> _publishThrottled(GeoPoint point) async {
    final last = _lastPublishedAt;
    final now = _clock();
    if (last != null && now.difference(last) < publishInterval) return;
    _lastPublishedAt = now;
    await _publish(point);
  }

  /// The clock, injected so the throttle is a unit test rather than a wait.
  ///
  /// Defaults to the wall clock; the tests pass their own so "fifteen seconds"
  /// can be crossed by advancing a variable.
  DateTime Function() _clock = DateTime.now;

  /// Overrides the clock used by the publish throttle.
  void useClock(DateTime Function() clock) => _clock = clock;

  @override
  void dispose() {
    // The subscription outlives the widget otherwise, and Dart's stream would
    // keep calling `notifyListeners` on a disposed controller.
    unawaited(_watching?.cancel());
    _watching = null;
    super.dispose();
  }
}
