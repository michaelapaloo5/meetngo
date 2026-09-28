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
}

/// The real one, over `geolocator`.
///
/// `geolocator: ^13.0.1` is already a dependency of this app and nothing before
/// this file called it from anywhere except `DriverRepository.currentLocation`,
/// which answered null for every outcome. The distinctions below are the ones
/// that method threw away.
class GeolocatorLocationReader implements LocationReader {
  const GeolocatorLocationReader();

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
    return GeoPoint(position.latitude, position.longitude);
  }
}
