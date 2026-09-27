import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';

/// PostgREST serialises a Postgres `numeric` as a JSON **number**, which is
/// what `Trip.fromJson` casts with `as num`. A string would throw at runtime,
/// not at compile time, so nothing else in the tree would catch it. This
/// fixture is written by hand to that shape: **it is not a live PostgREST
/// read**, because there is no PostgREST on this host. The residual risk —
/// that a future PostgREST change emits numeric as a string — is untested and
/// belongs in Task 18's pilot runbook, not here.
final row = <String, dynamic>{
  'id': '11111111-1111-1111-1111-111111111111',
  'rider_id': '22222222-2222-2222-2222-222222222222',
  'driver_id': null,
  'category': 'standard',
  'state': 'requested',
  'pickup': {
    'label': 'Osu',
    'address': 'Oxford Street',
    'point': {'lat': 5.6037, 'lng': -0.1870},
  },
  'dropoff': {
    'label': 'Airport Residential',
    'address': 'Liberation Road',
    'point': {'lat': 5.6200, 'lng': -0.1870},
  },
  'distance_km': 8.0,
  'fare_ghs': 22.0,
  'is_demo': true,
  'eta_minutes': null,
};

void main() {
  test('a PostgREST-shaped row parses into a Trip', () {
    final trip = Trip.fromJson(row);
    expect(trip.id, '11111111-1111-1111-1111-111111111111');
    expect(trip.category, RideCategory.standard);
    expect(trip.state, TripState.requested);
    expect(trip.distanceKm, 8.0);
    expect(trip.fareGhs, 22.0);
    expect(trip.isDemo, isTrue);
    expect(trip.etaMinutes, isNull);
    expect(trip.hasDriver, isFalse);
  });

  test('the nested point key is required, and a flattened pin is not it', () {
    final flattened = <String, dynamic>{
      ...row,
      'pickup': {
        'label': 'Osu',
        'address': 'Oxford Street',
        'lat': 5.6037,
        'lng': -0.1870,
      },
    };
    expect(() => Trip.fromJson(flattened), throwsA(isA<TypeError>()));
  });

  test('a numeric column arriving as a string throws, which is the risk pinned', () {
    final asString = <String, dynamic>{...row, 'fare_ghs': '22.00'};
    expect(() => Trip.fromJson(asString), throwsA(isA<TypeError>()));
  });
}
