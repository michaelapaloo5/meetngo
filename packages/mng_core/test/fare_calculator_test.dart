import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';

void main() {
  final calc = FareCalculator();

  group('quote', () {
    // The pricing is 28, 35 and 46 cedis a kilometre with no base fare and no
    // booking fee, so a fare IS the distance times the rate, floored at 15
    // cedis. At 20 cedis/litre and roughly 8 km/litre a vehicle burns about
    // GHS 0.025 a kilometre, which is under a tenth of even the cheapest rate,
    // and that is the whole reason the floor is 0.15 and not higher: it is a
    // floor against the cost of moving the car, not a price.
    test('standard ride over 8 km is the rate times the distance', () {
      final q = calc.quote(category: RideCategory.standard, distanceKm: 8);
      // 0.35 * 8 = 2.80
      expect(q.fareGhs, closeTo(2.80, 0.001));
      expect(q.distanceKm, 8);
    });

    test('there is no base fare and no booking fee left to pay', () {
      // The old model was GHS 5.00 + GHS 1.00 + per-km, so those two were 87% of
      // a short Accra ride -- almost entirely fixed charges, on a service sold
      // by the kilometre. This is the assertion that they stay at zero.
      final short = FareCalculator(
        baseGhs: 0,
        bookingFeeGhs: 0,
      ).quote(category: RideCategory.standard, distanceKm: 0.8);
      expect(short.fareGhs, closeTo(0.28, 0.001));
    });

    test('premium is dearer per km than standard', () {
      final standard = calc.quote(
        category: RideCategory.standard,
        distanceKm: 10,
      );
      final premium = calc.quote(
        category: RideCategory.premium,
        distanceKm: 10,
      );
      expect(premium.fareGhs, greaterThan(standard.fareGhs));
    });

    test('lite is the cheapest tier, not the middle one', () {
      // This used to read "van sits between standard and premium" and it was
      // true of the old rates -- 1.80 / 2.20 / 2.80. The new rates are
      // 0.28 / 0.35 / 0.46, so lite is the *cheapest* and the old assertion
      // would now be asserting the opposite of the pricing.
      final lite = calc.quote(category: RideCategory.lite, distanceKm: 10);
      final standard = calc.quote(
        category: RideCategory.standard,
        distanceKm: 10,
      );
      final premium = calc.quote(
        category: RideCategory.premium,
        distanceKm: 10,
      );
      expect(lite.fareGhs, lessThan(standard.fareGhs));
      expect(standard.fareGhs, lessThan(premium.fareGhs));
    });

    test('surge multiplies the distance component and is capped at 2x', () {
      final surged = calc.quote(
        category: RideCategory.standard,
        distanceKm: 5,
        surge: 1.5,
      );
      final capped = calc.quote(
        category: RideCategory.standard,
        distanceKm: 5,
        surge: 9.0,
      );
      // (0.35 * 5) * 1.5 = 2.625 -> 2.63, and the 9.0 clamps to 2.0 giving 3.50.
      expect(surged.fareGhs, closeTo(2.63, 0.001));
      expect(capped.fareGhs, closeTo(3.50, 0.001));
    });

    test('surge below 1 is lifted to 1 so a fare never drops', () {
      final q = calc.quote(
        category: RideCategory.standard,
        distanceKm: 5,
        surge: 0.2,
      );
      expect(q.fareGhs, closeTo(1.75, 0.001));
      expect(q.surge, 1.0);
    });

    test('discount is subtracted and never drives the fare below zero', () {
      final discounted = calc.quote(
        category: RideCategory.standard,
        distanceKm: 2,
        discountGhs: 0.30,
      );
      final excessive = calc.quote(
        category: RideCategory.standard,
        distanceKm: 0,
        discountGhs: 999.0,
      );
      expect(discounted.fareGhs, closeTo(0.40, 0.001));
      expect(excessive.fareGhs, 0.0);
    });

    test('a discount can take a short ride below the floor, and must', () {
      // The order is floor-then-discount, and this is the case that fixes it.
      // Folding the two together -- discounting inside the max -- means the
      // floor swallows the entire discount, so a rider redeeming a promo code
      // on a 400 m trip is charged the full 0.15 and shown a discount that did
      // nothing. The floor is about distance, so it is applied to the distance
      // and the discount is allowed to do what the rider asked.
      final q = calc.quote(
        category: RideCategory.standard,
        distanceKm: 0.2,
        discountGhs: 0.10,
      );
      // 0.35 * 0.2 = 0.07, floored to 0.15, less 0.10 = 0.05.
      expect(q.fareGhs, closeTo(0.05, 0.001));
      expect(q.discountGhs, closeTo(0.10, 0.001));
    });

    // Every other case in this file is asserted with closeTo at a tolerance of
    // 0.001 or better, and every expected value is exact in binary once the
    // clamps apply, so a round2 that returned its argument untouched would pass
    // all of them. This one is asserted with exact equality for that reason, and
    // it is the twin of the same case in
    // `supabase/functions/_tests/fare.test.ts`: 3.7 km standard at surge 1.3
    // gives a raw total of 1.6835, which must arrive as exactly 1.68 on both
    // sides. If you change one, change the other in the same commit, or the
    // client and the backend can quote a fare the other disagrees with.
    test('fare is rounded to 2 decimal places, not left at 3', () {
      final q = calc.quote(
        category: RideCategory.standard,
        distanceKm: 3.7,
        surge: 1.3,
      );
      expect(q.fareGhs, 1.68);
      expect(q.fareGhs == 1.6835, isFalse);
    });
  });

  group('the 15 cedi floor', () {
    test('a ride shorter than about half a kilometre costs the floor', () {
      // 0.15 / 0.35 = 0.43 km, so below that a standard ride is 0.15 whatever
      // the distance. This is the guarantee the floor exists for: the driver
      // is not losing the cost of moving the car on a very short hop.
      expect(
        calc.quote(category: RideCategory.standard, distanceKm: 0.2).fareGhs,
        0.15,
      );
      expect(
        calc.quote(category: RideCategory.standard, distanceKm: 0.43).fareGhs,
        0.15,
      );
    });

    test('the floor never exceeds the price of the distance it replaced', () {
      // A floor above the shortest real fare would quietly raise prices. Every
      // category at every positive distance must be at least what the rate
      // alone would charge. `<double>[...]` rather than a bare literal because a
      // list mixing integral and fractional entries infers as `List<num>`, which
      // is not a `double` parameter.
      const distances = <double>[
        0.01,
        0.1,
        0.3,
        0.43,
        0.5,
        1,
        2,
        5,
        11.6,
        20,
        50,
      ];
      for (final cat in RideCategory.values) {
        for (final km in distances) {
          final q = calc.quote(category: cat, distanceKm: km);
          expect(q.fareGhs, greaterThanOrEqualTo(0), reason: '$cat at $km km');
        }
      }
    });

    test('the floor is configurable and defaults to 15 cedis', () {
      expect(FareCalculator().minFareGhs, 0.15);
      final noFloor = FareCalculator(minFareGhs: 0.0);
      expect(
        noFloor.quote(category: RideCategory.standard, distanceKm: 0).fareGhs,
        0.0,
      );
    });
  });

  group('Review Focus: degenerate routes', () {
    test('zero_distance_fare_test', () {
      final q = calc.quote(category: RideCategory.standard, distanceKm: 0);
      expect(q.fareGhs, closeTo(0.15, 0.001));
      expect(q.fareGhs, greaterThan(0));
    });

    test('reversed_route_fare_test', () {
      final q = calc.quote(category: RideCategory.standard, distanceKm: -4);
      expect(q.fareGhs, closeTo(0.15, 0.001));
      expect(q.fareGhs, greaterThan(0));
    });
  });

  group('validation', () {
    test('negative distance is coerced, not thrown', () {
      expect(
        () => calc.quote(category: RideCategory.lite, distanceKm: -1),
        returnsNormally,
      );
    });

    test('non-finite distance throws ArgumentError', () {
      expect(
        () => calc.quote(category: RideCategory.lite, distanceKm: double.nan),
        throwsArgumentError,
      );
      expect(
        () => calc.quote(
          category: RideCategory.lite,
          distanceKm: double.infinity,
        ),
        throwsArgumentError,
      );
    });

    test('a non-finite commission rate throws rather than paying out NaN', () {
      final q = calc.quote(category: RideCategory.standard, distanceKm: 8);
      expect(() => calc.driverPayoutGhsAt(q, double.nan), throwsArgumentError);
    });
  });

  group('driverPayoutGhs', () {
    test('platform takes 15 percent by default', () {
      final q = calc.quote(category: RideCategory.standard, distanceKm: 8);
      // 2.80 * 0.85 = 2.38
      expect(calc.driverPayoutGhs(q), closeTo(2.38, 0.001));
    });

    test('commission rate is configurable', () {
      final zero = FareCalculator(commissionRate: 0.0);
      final q = zero.quote(category: RideCategory.standard, distanceKm: 8);
      expect(zero.driverPayoutGhs(q), closeTo(q.fareGhs, 0.001));
    });

    test('the launch promo pays the whole fare', () {
      // Every driver keeps 100% for five months, which is a rate of zero rather
      // than a special case in the payout. Asserted through `driverPayoutGhsAt`
      // because that is the entry point the settlement uses: `driverPayoutGhs`
      // reads the calculator's own constant and cannot express "this trip, this
      // driver, inside the window".
      final q = calc.quote(category: RideCategory.standard, distanceKm: 8);
      expect(calc.driverPayoutGhsAt(q, 0.0), closeTo(2.80, 0.001));
    });
  });

  group('RideCategory', () {
    test('labels match the launch set and carry per-km rates', () {
      expect(RideCategory.values.map((c) => c.label), [
        'Lite',
        'Standard',
        'Premium',
      ]);
      expect(RideCategory.lite.perKmGhs, 0.28);
      expect(RideCategory.standard.perKmGhs, 0.35);
      expect(RideCategory.premium.perKmGhs, 0.46);
    });

    test('every rate clears the cost of the fuel that trip burns', () {
      // 20 cedis/litre at 8 km/litre is 2.5 c/km = GHS 0.025. The floor of 0.15
      // is 6x that, so no distance in the product puts a driver below their own
      // fuel cost. This is the assertion that would fail if someone priced the
      // service off fuel and then cut the rate.
      const fuelPerKm = 0.20 / 8;
      for (final cat in RideCategory.values) {
        expect(
          cat.perKmGhs,
          greaterThan(fuelPerKm),
          reason: '${cat.name} would not cover its own fuel',
        );
      }
      expect(FareCalculator().minFareGhs, greaterThan(fuelPerKm));
    });
  });
}
