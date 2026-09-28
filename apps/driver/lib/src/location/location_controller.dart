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
      // Only prompt when the answer was "not asked yet". A driver who already
      // said no is not asked again on every refresh; they are told where to
      // undo it, which is the only thing that can actually change the answer.
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
      _set(DriverLocationStatus.ready);
      await _publish(point);
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

  /// Publishes the fix so the matcher can see this driver at all.
  ///
  /// A failure here does not un-ready the position. The driver genuinely is
  /// where the map says, and the write is the only thing lost; reporting a
  /// location failure would send them to fix something that is not broken.
  Future<void> _publish(GeoPoint point) async {
    try {
      await _drivers.updateLocation(point);
    } on DriverAuthFailure catch (e) {
      _failure = 'Your location could not be published, so ride requests cannot '
          'reach you: ${e.message}';
    }
  }

  void _set(DriverLocationStatus next) {
    _status = next;
    notifyListeners();
  }
}
