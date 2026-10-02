import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:meetngo_rider/main.dart';
import 'package:meetngo_rider/src/app/app_config.dart';
import 'package:meetngo_rider/src/app/rider_flow.dart';
import 'package:meetngo_rider/src/app/rider_shell.dart';
import 'package:meetngo_rider/src/booking/route_confirm_page.dart';
import 'package:mng_core/mng_core.dart';
import 'package:meetngo_rider/src/data/trip_functions.dart';
import 'package:meetngo_rider/src/data/booked_trip.dart';
import 'package:meetngo_rider/src/data/location_service.dart';
import 'package:meetngo_rider/src/data/profile_repository.dart';
import 'package:meetngo_rider/src/data/trip_repository.dart';
import 'package:meetngo_rider/src/profile/profile_controller.dart';
import 'package:meetngo_rider/src/trip/trip_controller.dart';

/// A profile that answers with a name, so the greeting is not "there".
class _StubProfiles implements ProfileRepository {
  @override
  Future<RiderProfile?> me() async => const RiderProfile(
    id: 'r1',
    fullName: 'Alex',
    phone: '',
    rating: 5.0,
    tripCount: 5,
    kyc: KycStatus.approved,
  );

  @override
  Future<RiderProfile?> save({
    required String fullName,
    required String phone,
  }) async => me();
}

class _StubTrips implements TripRepository {
  @override
  Future<DriverContact> driverContact(String tripId) async =>
      const DriverContact.unavailable();

  _StubTrips({this.pastTrips = const []});

  /// What [history] answers with. Named for the field rather than `history`,
  /// which is the method it backs.
  final List<BookedTrip> pastTrips;

  /// How many times the history was read. The cold-start test asserts on this
  /// rather than on what is drawn, because what is drawn is the shell's
  /// business and this is the repository's contract.
  int historyCalls = 0;

  @override
  Future<List<BookedTrip>> history({int limit = 50}) async {
    historyCalls++;
    return pastTrips.take(limit).toList();
  }

  @override
  Future<DeviceLocation> locate() async =>
      const DeviceLocation(LocationOutcome.denied);
  @override
  Future<Trip?> activeTrip() async => null;

  @override
  Future<VehicleFix?> assignedDriverLocation(String? driverId) async => null;
  @override
  Future<void> cancelTrip(String tripId) async {}

  @override
  Future<GeoPoint?> currentLocation() async => null;

  @override
  Future<Trip> requestRide({
    required TripStop pickup,
    required TripStop dropoff,
    required RideCategory category,
    String? promoCode,
  }) async => throw UnimplementedError();

  @override
  Future<void> raiseSos(String tripId, String note) async {}

  @override
  Stream<Trip> watchTrip(String tripId) => const Stream<Trip>.empty();
}

class _StubFunctions implements TripFunctions {
  @override
  Future<Map<String, dynamic>> invoke(
    String name,
    Map<String, dynamic> body,
  ) async => throw UnimplementedError();
}

void main() {
  testWidgets('with no credentials the app says which two are missing', (
    tester,
  ) async {
    // The build under test has no `--dart-define`, which is the state a first
    // run is in. Without this the app would reach `Supabase.instance` and throw
    // on the first frame, which tells a first-time runner nothing.
    expect(AppConfig.isConfigured, isFalse);

    await tester.pumpWidget(const RideNGoApp());
    await tester.pump();

    expect(
      find.textContaining('No Supabase project is connected'),
      findsOneWidget,
    );
    expect(find.textContaining('SUPABASE_URL'), findsOneWidget);
  });

  testWidgets('the flow calculator carries the shared fares', (tester) async {
    final flow = RiderFlow(trips: _StubTrips(), functions: _StubFunctions());
    addTearDown(flow.dispose);

    final quote = flow.calc.quote(
      category: RideCategory.standard,
      distanceKm: 5,
      surge: 1.5,
    );
    // The same arithmetic as `packages/mng_core/test/fare_calculator_test.dart`.
    // Asserted here because this is the first code path that is not a test
    // reaching the calculator, so a wiring mistake in the injected instance
    // would otherwise only show up on a phone.
    //
    // (8 * 5) * 1.5 = 60.00. The previous value was 2.63, from the old
    // 0.35/km scale, and 22.00 before that, from a GHS 5 base fare plus a GHS 1
    // booking fee.
    expect(quote.fareGhs, 60.0);
    expect(flow.controller, isA<TripController>());
    expect(flow.requesting, isFalse);
    expect(flow.requestError, isNull);
  });

  // This used to assert that `kNearbyVehicles` covered every category the
  // chips offer. That constant was four invented cars with invented
  // registration plates -- not rows in `vehicles`, owned by nobody -- and the
  // rider was choosing between them as if they were real. It is gone, and the
  // guarantee now worth pinning is the one the server actually matches on: the
  // three launch categories, which is what `request-ride` filters drivers by.
  test(
    'the chips offer exactly the launch categories the server matches on',
    () {
      // The order is the enum's declaration order, which is the order the chips
      // render in, so it is asserted rather than sorted. `lite` is the cheapest
      // tier (28c/km against standard's 35c) and a rider's first tap lands on
      // whatever is first, so a reorder changes what a rider is quoted by
      // default. Cheapest first is the intent.
      expect(RideCategory.values.map((c) => c.label), [
        'Lite',
        'Standard',
        'Premium',
      ]);
      // Ascending by price, stated rather than implied by the labels above: a
      // dearer tier listed above a cheaper one is a pricing bug nothing else in
      // this file would notice.
      final rates = RideCategory.values.map((c) => c.perKmGhs).toList();
      for (var i = 1; i < rates.length; i++) {
        expect(
          rates[i],
          greaterThan(rates[i - 1]),
          reason: 'the categories are listed cheapest-first',
        );
      }
      for (final c in RideCategory.values) {
        expect(c.perKmGhs, greaterThan(0), reason: c.name);
      }
    },
  );

  testWidgets('the home screen shows history on a cold start, not only after '
      'a booking', (tester) async {
    // Found on a device: the rider opened the app, looked at the home screen,
    // and saw no "Recent rides" at all despite having five trips on file. The
    // read only happened on the way past from a booking, so the section the
    // home screen is built around was empty for the first thing every
    // returning rider does.
    final trips = _StubTrips(
      pastTrips: [
        BookedTrip(
          trip: const Trip(
            id: 't1',
            riderId: 'r1',
            driverId: 'd1',
            category: RideCategory.standard,
            state: TripState.completed,
            pickup: TripStop('Pickup', GeoPoint(5.6037, -0.1870), 'Osu, Accra'),
            dropoff: TripStop(
              'Dropoff',
              GeoPoint(5.6052, -0.1660),
              'Airport Residential, Accra',
            ),
            distanceKm: 2.0,
            fareGhs: 12.5,
          ),
          createdAt: DateTime(2026, 9, 27),
        ),
      ],
    );
    final flow = RiderFlow(trips: trips, functions: _StubFunctions());
    addTearDown(flow.dispose);
    final profile = RiderProfileController(_StubProfiles());
    addTearDown(profile.dispose);

    // A phone-shaped surface. The default test surface is 800x600 logical, and
    // the bottom navigation bar does not fit in 600 of them -- which is a
    // property of that surface rather than of the app, and would make this
    // test fail for a reason that has nothing to do with the history read.
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    // The shell reads its collaborators from `Provider` rather than taking them
    // as arguments, so they are supplied here. Only what the home path reaches
    // is provided: the rest are used by screens this test does not open, and a
    // test that has to build a whole dependency graph to check one thing is a
    // test that breaks when an unrelated thing changes.
    //
    // `TripRepository` has to be here as well as the flow, because the shell
    // reads it directly. Leaving it out is instructive: `_loadRecentRides`
    // catches everything, so a missing provider is swallowed and the test sees
    // a silent zero rather than a failure.
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(390, 844),
        builder: (_, _) => MultiProvider(
          providers: [
            Provider<TripRepository>.value(value: trips),
            ChangeNotifierProvider<RiderFlow>.value(value: flow),
            ChangeNotifierProvider<RiderProfileController>.value(
              value: profile,
            ),
          ],
          child: MaterialApp(theme: MngTheme.light, home: const RiderShell()),
        ),
      ),
    );
    // The read is async, and `pump()` alone does not advance it. Pumping with a
    // duration flushes the microtask the repository's `async` body completes on
    // and then the frame the shell rebuilds in.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(
      trips.historyCalls,
      greaterThan(0),
      reason: 'the history has to be read on arrival, not only after booking',
    );
    expect(find.byKey(const Key('recentRides')), findsOneWidget);
  });

  test(
    'a request that throws reports the reason instead of throwing',
    () async {
      final flow = RiderFlow(trips: _StubTrips(), functions: _StubFunctions());
      addTearDown(flow.dispose);

      final trip = await flow.requestRide(
        const RouteDraft(
          pickup: TripStop('Pickup', GeoPoint(5.6037, -0.1870), 'Osu, Accra'),
          dropoff: TripStop(
            'Dropoff',
            GeoPoint(5.6052, -0.1660),
            'Airport Residential, Accra',
          ),
          category: RideCategory.standard,
        ),
      );

      expect(trip, isNull);
      expect(flow.requesting, isFalse);
      expect(flow.requestError, isNotNull);
    },
  );
}
