import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';
import 'package:meetngo_driver/src/earnings/earnings_repository.dart';

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
void useDesignSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
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
