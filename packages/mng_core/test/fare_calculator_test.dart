import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';

void main() {
  final calc = FareCalculator();

  group('quote', () {
    test('standard ride over 8 km costs base + per-km + booking fee', () {
      final q = calc.quote(category: RideCategory.standard, distanceKm: 8);
      expect(q.fareGhs, closeTo(20.4, 0.001));
      expect(q.distanceKm, 8);
    });

    test('premium is dearer per km than standard', () {
      final standard = calc.quote(category: RideCategory.standard, distanceKm: 10);
      final premium = calc.quote(category: RideCategory.premium, distanceKm: 10);
      expect(premium.fareGhs, greaterThan(standard.fareGhs));
    });

    test('van sits between standard and premium', () {
      final standard = calc.quote(category: RideCategory.standard, distanceKm: 10);
      final van = calc.quote(category: RideCategory.van, distanceKm: 10);
      final premium = calc.quote(category: RideCategory.premium, distanceKm: 10);
      expect(van.fareGhs, greaterThan(standard.fareGhs));
      expect(van.fareGhs, lessThan(premium.fareGhs));
    });

    test('surge multiplies the distance component and is capped at 2x', () {
      final surged = calc.quote(category: RideCategory.standard, distanceKm: 5, surge: 1.5);
      final capped = calc.quote(category: RideCategory.standard, distanceKm: 5, surge: 9.0);
      // fare = (base + perKm * km) * surge + bookingFee, so
      // (5 + 1.80 * 5) * 1.5 + 1 = 22.0 and the 9.0 surge clamps to 2.0 giving 29.0.
      expect(surged.fareGhs, closeTo(22.0, 0.001));
      expect(capped.fareGhs, closeTo(29.0, 0.001));
    });

    test('surge below 1 is lifted to 1 so fares never drop below base', () {
      final q = calc.quote(category: RideCategory.standard, distanceKm: 5, surge: 0.2);
      expect(q.fareGhs, closeTo(15.0, 0.001));
      expect(q.surge, 1.0);
    });

    test('discount is subtracted and never drives the fare below zero', () {
      final discounted =
          calc.quote(category: RideCategory.standard, distanceKm: 2, discountGhs: 3.0);
      final excessive =
          calc.quote(category: RideCategory.standard, distanceKm: 0, discountGhs: 999.0);
      expect(discounted.fareGhs, closeTo(6.6, 0.001));
      expect(excessive.fareGhs, 0.0);
    });

    // Every other case in this file is asserted with closeTo at a tolerance of
    // 0.001 or better, and every expected value is exact in binary once the
    // clamps apply, so a round2 that returned its argument untouched would pass
    // all of them. This one is asserted with exact equality for that reason, and
    // it is the twin of the same case in
    // `supabase/functions/_tests/fare.test.ts`: 3.7 km standard at surge 1.3
    // gives a raw total of 16.158, which must arrive as exactly 16.16 on both
    // sides. If you change one, change the other in the same commit, or the
    // client and the backend can quote a fare the other disagrees with.
    test('fare is rounded to 2 decimal places, not left at 3', () {
      final q =
          calc.quote(category: RideCategory.standard, distanceKm: 3.7, surge: 1.3);
      expect(q.fareGhs, 16.16);
      expect(q.fareGhs == 16.158, isFalse);
    });
  });

  group('Review Focus: degenerate routes', () {
    test('zero_distance_fare_test', () {
      final q = calc.quote(category: RideCategory.standard, distanceKm: 0);
      expect(q.fareGhs, closeTo(6.0, 0.001));
      expect(q.fareGhs, greaterThan(0));
    });

    test('reversed_route_fare_test', () {
      final q = calc.quote(category: RideCategory.standard, distanceKm: -4);
      expect(q.fareGhs, closeTo(6.0, 0.001));
      expect(q.fareGhs, greaterThan(0));
    });
  });

  group('validation', () {
    test('negative distance is coerced, not thrown', () {
      expect(
        () => calc.quote(category: RideCategory.van, distanceKm: -1),
        returnsNormally,
      );
    });

    test('non-finite distance throws ArgumentError', () {
      expect(
        () => calc.quote(category: RideCategory.van, distanceKm: double.nan),
        throwsArgumentError,
      );
      expect(
        () => calc.quote(category: RideCategory.van, distanceKm: double.infinity),
        throwsArgumentError,
      );
    });
  });

  group('driverPayoutGhs', () {
    test('platform takes 15 percent by default', () {
      final q = calc.quote(category: RideCategory.standard, distanceKm: 8);
      expect(calc.driverPayoutGhs(q), closeTo(17.34, 0.01));
    });

    test('commission rate is configurable', () {
      final zero = FareCalculator(commissionRate: 0.0);
      final q = zero.quote(category: RideCategory.standard, distanceKm: 8);
      expect(zero.driverPayoutGhs(q), closeTo(q.fareGhs, 0.001));
    });
  });

  group('RideCategory', () {
    test('labels match the launch set and carry per-km rates', () {
      expect(RideCategory.values.map((c) => c.label),
          ['Standard', 'Premium', 'Van']);
      expect(RideCategory.standard.perKmGhs, 1.80);
      expect(RideCategory.premium.perKmGhs, 2.80);
      expect(RideCategory.van.perKmGhs, 2.20);
    });
  });
}
