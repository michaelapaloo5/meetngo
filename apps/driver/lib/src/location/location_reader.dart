import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:mng_core/mng_core.dart';

/// The four questions this app asks the operating system about a position.
///
/// Behind an interface so a screen is drivable by a fake: `Geolocator` is a
/// plugin, so every call goes over a platform channel and returns whatever the
/// test binding's missing plugin reports. `LocationController` is where the
/// interesting decisions live -- which of the four answers becomes which
/// sentence for the driver -- and those decisions are only testable if the four
/// answers can be supplied.
abstract class LocationReader {
  /// Is location switched on for the whole device?
  ///
  /// Asked first, and separately from the permission, because the two are
  /// independent: a driver can grant the permission and still have location
  /// off, and asking for a permission in that state returns a permission the
  /// driver never really granted.
  Future<bool> isServiceEnabled();

  /// The permission already held, without prompting.
  Future<LocationPermission> checkPermission();

  /// Shows the system prompt.
  Future<LocationPermission> requestPermission();

  /// One fix, or a throw. Throwing rather than returning null is deliberate:
  /// "no fix arrived" and "the plugin could not be reached" are different
  /// faults with different sentences, and a null cannot tell them apart.
  Future<GeoPoint> currentPoint();

  /// Live positions, for as long as the caller listens.
  ///
  /// [currentPoint] is a single reading, and one reading is not a location: a
  /// driver who opened the app at a junction and then drove to a pickup would
  /// have spent the whole trip watching their own dot sit at the junction. The
  /// map panel was already written to follow a moving dot -- it compares
  /// `driverPoint` on every rebuild precisely because it expected this stream to
  /// exist -- so the gap was never in the map.
  ///
  /// Errors are delivered as stream errors rather than thrown here, so that a
  /// permission revoked mid-trip surfaces as a sentence instead of an unhandled
  /// async error. The caller decides what a denial means; this method only says
  /// that it happened.
  Stream<GeoFix> positionStream();

  /// Which way the device is facing, degrees clockwise from north, or null.
  ///
  /// A separate method rather than a second return from [currentPoint], because
  /// geolocator reports the two independently and one is routinely missing: a
  /// position fix is available in a car park, a compass reading often is not.
  /// Bundling them would make a missing compass indistinguishable from a
  /// missing fix, and a driver unable to go online because their phone has no
  /// magnetometer is a real and very bad outcome.
  Future<double?> currentHeading();
}

/// One position update and the heading that arrived with it.
///
/// Bundled because a stream event carries both and splitting them would mean
/// holding a heading that belonged to a different fix -- a driver turning left at
/// a junction would briefly be drawn facing along the street they just left.
class GeoFix {
  const GeoFix(this.point, this.heading);

  final GeoPoint point;

  /// Null when the device has no compass reading to offer, which is ordinary:
  /// a phone flat on a seat, a tablet indoors.
  final double? heading;
}

/// The real one, over `geolocator`.
///
/// `geolocator: ^13.0.1` is already a dependency of this app and nothing before
/// this file called it from anywhere except `DriverRepository.currentLocation`,
/// which answered null for every outcome. The distinctions below are the ones
/// that method threw away.
class GeolocatorLocationReader implements LocationReader {
  GeolocatorLocationReader();

  /// The heading off the last fix, kept so the compass is not asked twice.
  ///
  /// `getCurrentPosition` already returns a heading, so re-reading it would be
  /// a second platform call for a number that was in hand a moment ago -- and a
  /// driver standing still can turn on the spot between the two.
  ///
  /// Mutable, which is why the constructor is not `const`. The alternative
  /// would be a fresh reader per fix and a plugin call per heading.
  Position? _last;

  /// How long to wait for a fix before saying so.
  ///
  /// Without it `getCurrentPosition` waits forever, and a driver standing
  /// indoors with a cold GPS is left on a spinner that never resolves -- the
  /// same blank outcome as a denial, reached by a different road.
  static const fixTimeLimit = Duration(seconds: 20);

  @override
  Future<bool> isServiceEnabled() => Geolocator.isLocationServiceEnabled();

  @override
  Future<LocationPermission> checkPermission() => Geolocator.checkPermission();

  @override
  Future<LocationPermission> requestPermission() =>
      Geolocator.requestPermission();

  @override
  Future<GeoPoint> currentPoint() async {
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: fixTimeLimit,
      ),
    );
    _last = position;
    return GeoPoint(position.latitude, position.longitude);
  }

  @override
  Future<double?> currentHeading() async {
    final heading = _last?.heading;
    if (heading == null) return null;
    // The plugin reports -1 for "no compass" and can hand back a NaN. Both are
    // turned into null here rather than at the consumer, so there is exactly one
    // place where a heading becomes a number.
    return normaliseBearing(heading);
  }

  @override
  Stream<GeoFix> positionStream() =>
      Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          // `high` rather than `best`, because `best` asks the GPS chip for raw
          // satellite fixes: minutes to converge, and unusable for the first fix
          // in a cold start. `high` is network-assisted and lands in a second or
          // two, which is what a map that has to look live actually needs.
          accuracy: LocationAccuracy.high,
          // 5 m rather than geolocator's default of 0, so a phone sitting on a
          // dashboard does not wake Dart every second to report that it has not
          // moved. Publishing is throttled separately; this is about not doing
          // work at all.
          distanceFilter: 5,
        ),
      ).map(
        (p) => GeoFix(
          GeoPoint(p.latitude, p.longitude),
          normaliseBearing(p.heading),
        ),
      );
}
