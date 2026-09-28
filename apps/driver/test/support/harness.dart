import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';
import 'package:meetngo_driver/src/data/driver_trip.dart';
import 'package:meetngo_driver/src/earnings/earnings_repository.dart';
import 'package:meetngo_driver/src/map/driver_map_panel.dart';

/// Puts a widget test on the device this app is designed for.
///
/// The default `flutter test` surface is 800x600. `ScreenUtil` scales `.w`
/// against `designSize.width`, so 800 against 390 is 2.05x, and `.h` scales
/// against 844, so 600 against 844 is 0.525x: at 800x600 a row of buttons is
/// twice as wide as the design and half as tall, and the test font is far wider
/// than Roboto. A row that fits 390 does not fit 800 at these ratios, so a
/// `tap` lands on empty space and throws, and a `find` misses text that has
/// wrapped off the widget. Every test that renders a screen calls this first.
///
/// 1170x2532 at 3.0 is 390x844 logical, the design size in `main.dart`.
///
/// Also points the map at [StubTileProvider]. The home tab and the live trip both
/// render a `DriverMapPanel`, and without this every test that reaches either
/// one fails for a reason that has nothing to do with what it is testing:
/// `flutter_test` answers every HTTP request with an empty 400, `NetworkImage`
/// turns that into a load exception, and an `Image` with no `errorBuilder`
/// reports it to `FlutterError.onError`.
void useDesignSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  DriverMapPanel.tileProviderOverride = () => StubTileProvider();
  addTearDown(tester.view.reset);
  addTearDown(() => DriverMapPanel.tileProviderOverride = null);
}

/// [ScreenUtilInit] around [child] with the app's theme and no chrome.
///
/// The theme is not decoration. `MngTheme.light` is what paints the filled
/// buttons amber, and a bare `MaterialApp` leaves them on the Material default,
/// so any colour assertion made without it is vacuous. Not `const`: the
/// builder is not constant, and `MngTheme.light` is a `static final` getter
/// rather than a constant anyway.
Widget appHarness(Widget child, {Key? key}) => ScreenUtilInit(
      designSize: const Size(390, 844),
      minTextAdapt: true,
      builder: (_, _) => MaterialApp(theme: MngTheme.light, home: child),
      key: key,
    );

/// A profile the tests can vary one field of at a time.
DriverProfile driverProfile({
  String id = 'd1',
  String fullName = 'Jane Cooper',
  KycStatus kyc = KycStatus.approved,
  DriverAvailability availability = DriverAvailability.offline,
  String? vehicleId = 'v1',
}) =>
    DriverProfile(
      id: id,
      fullName: fullName,
      phone: '+233200000000',
      rating: 4.9,
      tripCount: 12,
      kyc: kyc,
      availability: availability,
      vehicleId: vehicleId,
    );

/// A trip with a label and an address on each stop, and the two set to
/// different strings.
///
/// The plan's fixture put `'P'` in `label` and `'Osu, Accra'` in `address`, and
/// only asserted on the address. A pair of swapped fixture fields cannot tell a
/// screen that renders the label as its title from one that renders the address
/// as it, because both end up on screen either way. Every field a screen can
/// read is a different string here and every one of them is asserted.
Trip tripIn(
  TripState state, {
  String id = 't1',
  String pickupLabel = 'Osu Junction',
  String pickupAddress = 'Oxford Street, Osu, Accra',
  String dropoffLabel = 'Airport Residential',
  String dropoffAddress = 'Airport Residential, Accra',
  double fareGhs = 12.50,
}) =>
    Trip(
      id: id,
      riderId: 'r1',
      driverId: 'd1',
      category: RideCategory.standard,
      state: state,
      pickup: TripStop(pickupLabel, const GeoPoint(5.6037, -0.1870), pickupAddress),
      dropoff: TripStop(
        dropoffLabel,
        const GeoPoint(5.6200, -0.1870),
        dropoffAddress,
      ),
      distanceKm: 2.02,
      fareGhs: fareGhs,
      isDemo: true,
    );

Offer offer(
  String id, {
  Duration ttl = const Duration(seconds: 20),
  OfferState state = OfferState.pending,
  String tripId = 't1',
  double fareGhs = 12.50,
  double pickupDistanceKm = 0.8,
}) =>
    Offer(
      id: id,
      tripId: tripId,
      driverId: 'd1',
      fareGhs: fareGhs,
      pickupDistanceKm: pickupDistanceKm,
      expiresAt: DateTime.now().add(ttl),
      state: state,
    );

LedgerEntry ledgerEntry(
  String id,
  String kind,
  double amount, {
  DateTime? createdAt,
}) =>
    LedgerEntry(
      id: id,
      kind: kind,
      amountGhs: amount,
      note: '',
      createdAt: createdAt ?? DateTime(2026, 9, 27),
    );

/// A trip history row with both timestamps filled in.
///
/// The trips tab is the only place `created_at`, `started_at` and
/// `completed_at` are read, and `TripStop` has no value equality -- so a test
/// that wanted to compare two `Trip`s would compare identities and pass or fail
/// for the wrong reason. Assert on `.address` and `.point`.
DriverTrip driverTrip({
  String id = 't1',
  TripState state = TripState.completed,
  double fareGhs = 12.50,
  DateTime? createdAt,
  DateTime? completedAt,
  String pickupLabel = 'Osu Junction',
  String dropoffLabel = 'Airport Residential',
}) {
  final created = createdAt ?? DateTime(2026, 9, 27, 9, 5);
  return DriverTrip(
    trip: tripIn(
      state,
      id: id,
      pickupLabel: pickupLabel,
      dropoffLabel: dropoffLabel,
      fareGhs: fareGhs,
    ),
    createdAt: created,
    startedAt: created,
    completedAt: completedAt ?? created.add(const Duration(minutes: 24)),
  );
}

/// The vehicle a driver owns in the Profile test.
Vehicle driverVehicle({
  String make = 'Toyota',
  String model = 'Corolla',
  String plate = 'GR-1234-25',
  int seats = 4,
}) =>
    Vehicle(
      id: 'v1',
      ownerId: 'd1',
      category: VehicleCategory.sedan,
      make: make,
      model: model,
      plate: plate,
      seats: seats,
      photoUrl: '',
      rideCategory: RideCategory.standard,
    );

/// Tiles that never touch the network.
///
/// `TileLayer` otherwise builds a `NetworkTileProvider`, and a widget test has
/// no network: the build host has ~40 MB free and the test binding's HTTP
/// override answers 400 for everything, so every tile would be a failed request
/// logged during a test whose subject is something else. A transparent 1x1 PNG
/// is a real `ImageProvider`, so `TileLayer` takes its normal code path.
class StubTileProvider extends TileProvider {
  StubTileProvider();

  @override
  ImageProvider<Object> getImage(
    TileCoordinates coordinates,
    TileLayer options,
  ) =>
      MemoryImage(TileProvider.transparentImage);
}

