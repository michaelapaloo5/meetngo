import 'package:flutter_test/flutter_test.dart';

import 'package:meetngo_rider/main.dart';
import 'package:meetngo_rider/src/app/app_config.dart';
import 'package:meetngo_rider/src/app/rider_flow.dart';
import 'package:meetngo_rider/src/booking/route_entry_sheet.dart';
import 'package:mng_core/mng_core.dart';
import 'package:meetngo_rider/src/data/trip_functions.dart';
import 'package:meetngo_rider/src/data/booked_trip.dart';
import 'package:meetngo_rider/src/data/location_service.dart';
import 'package:meetngo_rider/src/data/trip_repository.dart';
import 'package:meetngo_rider/src/trip/trip_controller.dart';

class _StubTrips implements TripRepository {

  @override
  Future<List<BookedTrip>> history({int limit = 50}) async => const [];

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
  }) async =>
      throw UnimplementedError();

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
  ) async =>
      throw UnimplementedError();
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

    expect(find.textContaining('No Supabase project is connected'), findsOneWidget);
    expect(find.textContaining('SUPABASE_URL'), findsOneWidget);
  });

  testWidgets('the flow calculator carries the shared fares', (tester) async {
    final flow = RiderFlow(
      trips: _StubTrips(),
      functions: _StubFunctions(),
    );
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
    expect(quote.fareGhs, 22.00);
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
  test('the chips offer exactly the launch categories the server matches on', () {
    expect(RideCategory.values.map((c) => c.label), [
      'Standard',
      'Premium',
      'Van',
    ]);
    for (final c in RideCategory.values) {
      expect(c.perKmGhs, greaterThan(0), reason: c.name);
    }
  });

  test('a request that throws reports the reason instead of throwing', () async {
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
  });
}
