import 'package:flutter_test/flutter_test.dart';

import 'package:meetngo_rider/main.dart';
import 'package:meetngo_rider/src/app/app_config.dart';
import 'package:meetngo_rider/src/app/rider_flow.dart';
import 'package:meetngo_rider/src/booking/route_entry_sheet.dart';
import 'package:mng_core/mng_core.dart';
import 'package:meetngo_rider/src/data/trip_functions.dart';
import 'package:meetngo_rider/src/data/trip_repository.dart';
import 'package:meetngo_rider/src/trip/trip_controller.dart';

class _StubTrips implements TripRepository {
  @override
  Future<Trip?> activeTrip() async => null;

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

  testWidgets('the nearby list covers every category the chips offer', (
    tester,
  ) async {
    final offered = kNearbyVehicles.map((v) => v.rideCategory).toSet();
    expect(offered, RideCategory.values.toSet());
    for (final vehicle in kNearbyVehicles) {
      expect(vehicle.displayName, isNotEmpty);
      expect(vehicle.seats, greaterThan(0));
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
