import 'package:geolocator/geolocator.dart';
import 'package:mng_core/mng_core.dart';

/// What the OS said about location, kept as an answer rather than a `bool`.
///
/// `geolocator` distinguishes four states and the rider can act differently on
/// each, so collapsing them to "no location" is what makes a denied-permission
/// screen indistinguishable from a screen that has not finished loading. The
/// states are the ones the platform actually reports: the service can be off
/// with permission granted, permission can be refused once, or refused
/// permanently, in which case `requestPermission` no longer shows a dialog and
/// only a trip to the system Settings screen helps.
enum LocationOutcome {
  granted,
  serviceDisabled,
  denied,
  deniedForever,
}

/// One reading of the device's position, and the sentence to show about it.
class DeviceLocation {
  const DeviceLocation(this.outcome, [this.point]);

  final LocationOutcome outcome;

  /// Null for every outcome except [LocationOutcome.granted], and null there
  /// too if the fix itself could not be read.
  final GeoPoint? point;

  bool get hasFix => outcome == LocationOutcome.granted && point != null;

  /// What the rider is told, and what they can do about it.
  ///
  /// Empty for a granted fix, so a caller can render it unconditionally without
  /// a blank line appearing above the map.
  String get riderMessage => switch (outcome) {
        LocationOutcome.granted => '',
        LocationOutcome.serviceDisabled =>
          'Location is switched off on this phone, so your pickup is the '
              'default rather than where you are standing. Turn location on '
              'to fix it.',
        LocationOutcome.denied =>
          'This app is not allowed to use your location, so your pickup is '
              'the default rather than where you are standing. Allow '
              'location to fix it.',
        LocationOutcome.deniedForever =>
          'Location is blocked for this app and can only be re-enabled in your '
              'phone Settings, so your pickup is the default rather than '
              'where you are standing.',
      };
}

abstract class LocationService {
  Future<DeviceLocation> current();
}

/// The real implementation, over the OS location service.
class GeolocatorLocationService implements LocationService {
  const GeolocatorLocationService();

  /// Ordered the way the platform wants it asked, and each step is a separate
  /// answer rather than a short-circuit.
  ///
  /// `isLocationServiceEnabled` first because `checkPermission` reports
  /// `whileInUse` on a phone whose location toggle is off, and a rider who
  /// then gets a permission dialog is asked about a permission the platform
  /// will not grant until the toggle is on. `denied` is the only state worth
  /// prompting for: `whileInUse` and `always` already have what they need, and
  /// `deniedForever` returns immediately from `requestPermission` without a
  /// dialog, so asking again only burns a call.
  @override
  Future<DeviceLocation> current() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return const DeviceLocation(LocationOutcome.serviceDisabled);
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        return const DeviceLocation(LocationOutcome.denied);
      }
      if (permission == LocationPermission.deniedForever) {
        return const DeviceLocation(LocationOutcome.deniedForever);
      }
      // Every parameter is optional in geolocator 13.0.4, so the platform
      // defaults apply: the OS's own accuracy preference, an unbounded timeout
      // and no cached fix.
      final position = await Geolocator.getCurrentPosition();
      return DeviceLocation(
        LocationOutcome.granted,
        GeoPoint(position.latitude, position.longitude),
      );
    } on Object {
      // Permission granted and the service on, but the fix still failed: no
      // satellite fix indoors, the platform channel is missing in a test
      // harness, or the device threw. That is `granted` with no point rather
      // than a new outcome, because the rider has done everything asked of
      // them and the advice is the same as for a denial.
      return const DeviceLocation(LocationOutcome.granted);
    }
  }
}
