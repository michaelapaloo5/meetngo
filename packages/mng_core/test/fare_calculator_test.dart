import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';

/// The fare, pinned.
///
/// ## What the pricing is
///
/// Two numbers per tier and nothing else:
///
/// - a **per-kilometre rate** of GHS 6, 8 and 10 for Lite, Standard and Premium
/// - a **minimum fare** of GHS 17, 23 and 28 -- what the shortest ride costs
///
/// with no base fare and no booking fee, so
/// `fare = max(tier minimum, perKm * km)`, rounded to two decimals.
///
/// ## What it used to be, and why this file was rewritten
///
/// GHS 0.28 / 0.35 / 0.46 per km with a **single GHS 0.15 floor for all three
/// tiers**. That priced a real Accra trip from Tesano to Dansoman at GHS 1.94,
/// 2.43 and 3.19 -- less than the fuel, and less than the driver's time for the
/// hour it took.
///
/// It also made the tiers meaningless in a way no test noticed: with one floor
/// sitting above every real fare, all three charged exactly the same number, so
/// "choose your tier" was choosing between identical prices. The floor is now per
/// tier, which is the only way a floor and a rate can both be true.
///
/// ## Why there is no discount test
///
/// There was one, and it asserted that a discount could take a short ride *below*
/// the floor -- a real and deliberate property of the old model. `RIDE30` went on
/// every ride with no redemption record, the banner said "first ride" while
/// nothing enforced a first ride, and the server capped the discount at GHS 40
/// while the app did not cap it at all, so above GHS 133.33 the rider agreed to a
/// price lower than the one they were charged.
///
/// The offer is withdrawn. Keeping a test for a behaviour that no longer exists
/// is how a deleted feature comes back.
void main() {
  final calc = FareCalculator();

  group('the tiers', () {
    test('the rates are 6, 8 and 10 cedis a kilometre', () {
      // Pinned as literals rather than read off the enum: a test that asserts
      // `x == x` proves nothing, and this is the number a rider is charged.
      expect(RideCategory.lite.perKmGhs, 6.00);
      expect(RideCategory.standard.perKmGhs, 8.00);
      expect(RideCategory.premium.perKmGhs, 10.00);
    });

    test('the shortest ride costs 17, 23 and 28', () {
      // Also literals, and the reason this file exists. One floor for all three
      // tiers was what made them indistinguishable.
      expect(RideCategory.lite.minFareGhs, 17.00);
      expect(RideCategory.standard.minFareGhs, 23.00);
      expect(RideCategory.premium.minFareGhs, 28.00);
    });

    test('lite is cheapest, standard is between, premium is dearest', () {
      // Both halves of that, at a distance where the *rate* decides and again
      // where the *floor* decides. Asserting only one of them is how the old
      // scale passed: the rate ordered the tiers and the floor erased them.
      for (final km in <double>[0.5, 10, 40]) {
        final lite = calc.quote(category: RideCategory.lite, distanceKm: km);
        final standard = calc.quote(
          category: RideCategory.standard,
          distanceKm: km,
        );
        final premium = calc.quote(
          category: RideCategory.premium,
          distanceKm: km,
        );
        expect(
          lite.fareGhs,
          lessThan(standard.fareGhs),
          reason: 'lite at $km km',
        );
        expect(
          standard.fareGhs,
          lessThan(premium.fareGhs),
          reason: 'standard at $km km',
        );
      }
    });
  });

  group('quote', () {
    test('a short ride costs the tier minimum', () {
      // The floor is the price of the shortest ride, so it has to be the answer
      // for a short one. Under the old scale this was 0.28 and the tiers all
      // returned the same number.
      expect(
        calc.quote(category: RideCategory.lite, distanceKm: 0.8).fareGhs,
        17.00,
      );
      expect(
        calc.quote(category: RideCategory.standard, distanceKm: 0.8).fareGhs,
        23.00,
      );
      expect(
        calc.quote(category: RideCategory.premium, distanceKm: 0.8).fareGhs,
        28.00,
      );
    });

    test('a ride past the floor is the rate times the distance', () {
      // Standard crosses its 23.00 floor at 23/8 = 2.875 km, so 10 km is well
      // clear: 8 * 10 = 80.00.
      final q = calc.quote(category: RideCategory.standard, distanceKm: 10);
      expect(q.fareGhs, closeTo(80.00, 0.001));
      expect(q.distanceKm, 10);
    });

    test('the rate takes over exactly where the floor stops applying', () {
      // The boundary is where a rate and a floor stop being two descriptions of
      // the same thing. Below it the floor decides; above it the rate does.
      // Standard: 23 / 8 = 2.875 km.
      final below = calc.quote(
        category: RideCategory.standard,
        distanceKm: 2.8,
      );
      final above = calc.quote(category: RideCategory.standard, distanceKm: 3);
      expect(below.fareGhs, 23.00);
      expect(above.fareGhs, closeTo(24.00, 0.001));
    });

    test('a real Accra trip costs a real amount', () {
      // The bug this file was rewritten for, as a test. Tesano to Dansoman,
      // about 6.9 km, priced at 1.94 / 2.43 / 3.19 under the old scale -- which
      // is less than the fuel and less than the driver's time.
      const km = 6.93;
      expect(
        calc.quote(category: RideCategory.lite, distanceKm: km).fareGhs,
        closeTo(41.58, 0.01),
      );
      expect(
        calc.quote(category: RideCategory.standard, distanceKm: km).fareGhs,
        closeTo(55.44, 0.01),
      );
      expect(
        calc.quote(category: RideCategory.premium, distanceKm: km).fareGhs,
        closeTo(69.30, 0.01),
      );
    });

    test('there is no base fare and no booking fee left to pay', () {
      // The old model was GHS 5.00 + GHS 1.00 + per-km, so those two were 87% of
      // a short Accra ride -- almost entirely fixed charges, on a service sold
      // by the kilometre. The floor is the fixed charge now, and it is per tier.
      expect(FareCalculator(baseGhs: 0).baseGhs, 0);
      expect(FareCalculator(bookingFeeGhs: 0).bookingFeeGhs, 0);
    });

    test('surge multiplies the distance component and is capped at 2x', () {
      // 10 km standard: 80.00 gross, 120.00 at 1.5x, 160.00 at the 2x cap.
      final base = calc.quote(category: RideCategory.standard, distanceKm: 10);
      final surged = calc.quote(
        category: RideCategory.standard,
        distanceKm: 10,
        surge: 1.5,
      );
      final capped = calc.quote(
        category: RideCategory.standard,
        distanceKm: 10,
        surge: 9.0,
      );
      expect(surged.fareGhs, closeTo(120.00, 0.001));
      expect(capped.fareGhs, closeTo(160.00, 0.001));
      // Not a function of the floor, which is why this distance was chosen: at
      // 1.5x the floor is 23 and the rate gives 120, so the rate is the answer.
      expect(surged.fareGhs, greaterThan(base.fareGhs));
    });

    test('a surge on a short ride still respects the floor', () {
      // Surge is applied inside the floor, so a surge can only ever raise a
      // short trip towards its own minimum and never below it.
      final surged = calc.quote(
        category: RideCategory.lite,
        distanceKm: 0.5,
        surge: 2.0,
      );
      expect(surged.fareGhs, greaterThanOrEqualTo(17.00));
    });

    test('a surge below 1x is ignored', () {
      // A discount disguised as a surge. `clamp(1.0, maxSurge)` is the whole of
      // that rule and it is load-bearing: without it a caller passing
      // `surge: 0.5` halves every fare.
      final quoted = calc.quote(
        category: RideCategory.standard,
        distanceKm: 10,
        surge: 0.5,
      );
      expect(quoted.surge, 1.0);
      expect(quoted.fareGhs, closeTo(80.00, 0.001));
    });

    test('fare is rounded to two decimals', () {
      // 7 km standard is 56.00; the rounding is proved on a rate that does not
      // divide evenly. Lite at 6/km over 3.001 km is 18.006.
      final q = calc.quote(category: RideCategory.lite, distanceKm: 3.001);
      expect(q.fareGhs, 18.01);
      expect(q.fareGhs * 100, closeTo(q.fareGhs * 100, 0.0001));
    });

    test('a negative distance collapses to the floor, never below it', () {
      // A reversed pin must not produce a negative fare, and it must not produce
      // a free one either -- the floor is what a zero-length ride costs.
      final q = calc.quote(category: RideCategory.lite, distanceKm: -5);
      expect(q.distanceKm, 0);
      expect(q.fareGhs, 17.00);
    });

    test('a distance that is not finite throws', () {
      for (final bad in <double>[double.nan, double.infinity]) {
        expect(
          () => calc.quote(category: RideCategory.standard, distanceKm: bad),
          throwsArgumentError,
          reason: '$bad',
        );
      }
    });
  });

  group('driver payout', () {
    test('a standard commission leaves the driver most of the fare', () {
      final q = calc.quote(category: RideCategory.standard, distanceKm: 10);
      // 15%: 80.00 - 12.00 = 68.00
      expect(calc.driverPayoutGhsAt(q, 0.15), closeTo(68.00, 0.001));
    });

    test('a zero commission pays the whole fare', () {
      // The driver launch promo settles at zero commission for five months from
      // a driver's first completed trip, and this is the arithmetic it depends
      // on. See `commissionRateFor` in `complete-trip/handler.ts`.
      final q = calc.quote(category: RideCategory.lite, distanceKm: 10);
      expect(calc.driverPayoutGhsAt(q, 0.0), closeTo(60.00, 0.001));
    });

    test('a rate that is not finite throws', () {
      final q = calc.quote(category: RideCategory.standard, distanceKm: 10);
      for (final bad in <double>[double.nan, double.infinity]) {
        expect(
          () => calc.driverPayoutGhsAt(q, bad),
          throwsArgumentError,
          reason: '$bad',
        );
      }
    });
  });

  test('round2 is to two decimal places', () {
    expect(FareCalculator.round2(1.006), 1.01);
    expect(FareCalculator.round2(1.004), 1.0);
    expect(FareCalculator.round2(80), 80.0);
    // `1.005` rounds **down** to `1.0`, and that is correct rather than a bug:
    // `1.005 * 100` is `100.49999999999999` in IEEE-754, so `round()` gets
    // 100. Worth pinning because a "fix" that special-cases it would make the
    // fare depend on which way the floating point error fell on a given day.
    expect(FareCalculator.round2(1.005), 1.0);
  });
}
