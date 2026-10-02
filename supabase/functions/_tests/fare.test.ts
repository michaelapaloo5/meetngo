import { assert, assertEquals, assertThrows } from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import {
  BASE_GHS,
  BOOKING_FEE_GHS,
  MIN_FARE_GHS,
  PER_KM,
  RIDE_CATEGORY_NAMES,
  computeFare,
  promoDiscountGhs,
  type RideCategoryName,
} from '../request-ride/fare.ts';
import {
  PROMO_COMMISSION_RATE,
  PROMO_MONTHS,
  STANDARD_COMMISSION_RATE,
  commissionRateFor,
  promoMonthsRemaining,
} from '../_shared/promo.ts';

const q = (
  category: RideCategoryName,
  distanceKm: number,
  surge = 1,
  discountGhs = 0,
) => computeFare({ category, distanceKm, surge, discountGhs });

Deno.test('standard 8km fare matches the Dart calculator', () => {
  // 8 * 8 = 64.00, well clear of the 23.00 floor.
  assertEquals(q('standard', 8).fareGhs, 64.0);
});

Deno.test('the backend and the app quote the same fare for every category', () => {
  // The twin of `labels match the launch set and carry per-km rates` in
  // `packages/mng_core/test/fare_calculator_test.dart`. The rider app quotes
  // locally and this function quotes again; a divergence is a rider shown one
  // price and charged another, and neither suite would see it alone. The rates
  // and the floor are literals in both languages on purpose.
  assertEquals(RIDE_CATEGORY_NAMES, ['lite', 'standard', 'premium']);
  assertEquals(PER_KM.lite, 6.0);
  assertEquals(PER_KM.standard, 8.0);
  assertEquals(PER_KM.premium, 10.0);
  assertEquals(BASE_GHS, 0.0);
  assertEquals(BOOKING_FEE_GHS, 0.0);
  // Per tier, and the reason these are a record and not a number: one floor
  // for all three tiers sat above every real fare, so the tiers charged the
  // same and choosing one was choosing between identical prices.
  assertEquals(MIN_FARE_GHS.lite, 17.0);
  assertEquals(MIN_FARE_GHS.standard, 23.0);
  assertEquals(MIN_FARE_GHS.premium, 28.0);
});

Deno.test('there is no base fare and no booking fee left to pay', () => {
  // The old model was 5.00 + 1.00 + per-km, so a short ride was almost entirely
  // fixed charges on a service sold by the kilometre.
  // 0.8 km standard: max(23.00, 6.40) = 23.00, the tier floor.
  assertEquals(q('standard', 0.8).fareGhs, 23.0);
});

Deno.test('lite is the cheapest tier, not the middle one', () => {
  // True of the old rates (1.80/2.20/2.80), false of these (0.28/0.35/0.46).
  assertEquals(q('lite', 10).fareGhs < q('standard', 10).fareGhs, true);
  assertEquals(q('standard', 10).fareGhs < q('premium', 10).fareGhs, true);
});

Deno.test('premium 10km beats standard 10km', () => {
  assertEquals(q('premium', 10).fareGhs > q('standard', 10).fareGhs, true);
});

Deno.test('surge multiplies the distance component and is capped at 2x', () => {
  // (8 * 5) * 1.5 = 60.00
  assertEquals(q('standard', 5, 1.5).fareGhs, 60.0);
  // (8 * 5) * 2.0 = 80.00, surge 5 clamps to 2.0
  assertEquals(q('standard', 5, 5).fareGhs, 80.0);
});

Deno.test('surge below 1 is lifted to 1', () => {
  assertEquals(q('standard', 5, 0.2).fareGhs, 40.0);
});

Deno.test('a ride under the tier rate costs the tier floor', () => {
  // Standard crosses its 23.00 floor at 23 / 8 = 2.875 km. Below that a
  // standard ride is 23.00 whatever the distance, which is what a rider is told
  // for the shortest ride and what a driver earns for moving the car.
  assertEquals(q('standard', 0.2).fareGhs, 23.0);
  assertEquals(q('standard', 2.8).fareGhs, 23.0);
  assertEquals(q('standard', 0).fareGhs, 23.0);
  // And each tier has its own floor, which is the point of them.
  assertEquals(q('lite', 0.2).fareGhs, 17.0);
  assertEquals(q('premium', 0.2).fareGhs, 28.0);
});

Deno.test('a real Accra trip costs a real amount', () => {
  // The bug this file exists for. Tesano to Dansoman, about 6.9 km, was quoted
  // at 1.94 / 2.43 / 3.19 -- less than the fuel and less than the driver's time.
  assertEquals(q('lite', 6.93).fareGhs, 41.58);
  assertEquals(q('standard', 6.93).fareGhs, 55.44);
  assertEquals(q('premium', 6.93).fareGhs, 69.3);
});

Deno.test('a discount argument is ignored, not applied', () => {
  // RIDE30 took 30% off every ride from every rider with no redemption record,
  // capped at GHS 40 here and not at all in the app -- so above GHS 133.33 the
  // rider agreed to a price lower than the one billed. The offer is withdrawn, and
  // a stale caller that still passes one is ignored rather than pricing below the
  // tier floor.
  assertEquals(q('standard', 0.2, 1, 10.0).fareGhs, 23.0);
});
Deno.test('negative distance collapses to the floor, not below it', () => {
  // The tier's floor, not zero and not a negative fare.
  assertEquals(q('standard', -3).fareGhs, 23.0);
});

Deno.test('NaN distance throws', () => {
  assertThrows(() => q('standard', NaN));
});

  Deno.test('fare is rounded to 2 decimal places, not left at 3', () => {
  // (8 * 3.7) * 1.3 = 38.48 exactly, so this pins the rate. Lite at 3.001 km
  // is 18.006 raw and 18.01 rounded, which is where the two-decimal rule
  // actually shows.
  const quote = q('standard', 3.7, 1.3);
  assertEquals(quote.fareGhs, 38.48);
  assertEquals(q('lite', 3.001).fareGhs, 18.01);
});


// --------------------------------------------------------------- the launch promo

const PROMO_START = '2026-09-30T10:00:00.000Z';
// Five calendar months on, as the database trigger writes it.
const PROMO_END = '2027-02-28T10:00:00.000Z';

Deno.test('the promo is five months at no commission, then the standard rate', () => {
  assertEquals(PROMO_MONTHS, 5);
  assertEquals(PROMO_COMMISSION_RATE, 0.0);
  assertEquals(STANDARD_COMMISSION_RATE, 0.15);
});

Deno.test('a trip inside the window settles at zero commission', () => {
  const rate = commissionRateFor({ endsAt: PROMO_END }, PROMO_START);
  assertEquals(rate, 0);
  // The whole point: at 0% the driver is paid the fare and not a cedi less.
  assertEquals(Number((2.8 * (1 - rate)).toFixed(2)), 2.8);
});

Deno.test('a trip after the window settles at the standard rate', () => {
  assertEquals(commissionRateFor({ endsAt: PROMO_END }, '2027-03-01T10:00:00.000Z'), 0.15);
});

Deno.test('a driver with no window pays the standard rate', () => {
  // No window means they have never completed a trip, so there is no trip of
  // theirs to price. The caller is expected not to have one either.
  assertEquals(commissionRateFor(null, PROMO_START), 0.15);
});

Deno.test('the boundary belongs to the standard rate, not the promo', () => {
  // `<` and not `<=`. A trip landing on the final millisecond of the window is
  // outside it, which is the reading that cannot quietly hand out a sixth month.
  // These two cases are one millisecond apart, so a comparison flipped to `<=`
  // fails here rather than only failing in production a month from now.
  assertEquals(commissionRateFor({ endsAt: PROMO_END }, PROMO_END), 0.15);
  assertEquals(commissionRateFor({ endsAt: PROMO_END }, '2027-02-28T09:59:59.999Z'), 0);
});

Deno.test('an unparseable date throws rather than guessing', () => {
  // Falling back to the standard rate would charge the driver 15% on every ride
  // for five months over a bad string in a column nobody looks at, and it would
  // look entirely normal. Throwing is what makes it visible.
  assertThrows(() => commissionRateFor({ endsAt: 'not-a-date' }, PROMO_START));
  assertThrows(() => commissionRateFor({ endsAt: PROMO_END }, 'not-a-date'));
});

Deno.test('a non-finite standard rate throws rather than paying out NaN', () => {
  assertThrows(() => commissionRateFor(null, PROMO_START, NaN));
});

Deno.test('months remaining rounds up, so a live promo never reads as over', () => {
  // A driver with four days left is told "1 month left". Rounding down tells
  // them the promo is finished while it is still running, and a driver who
  // believes that stops taking trips near the end of their window.
  assertEquals(promoMonthsRemaining({ endsAt: PROMO_END }, PROMO_START), 5);
  assertEquals(promoMonthsRemaining({ endsAt: PROMO_END }, '2027-02-27T10:00:00.000Z'), 1);
  assertEquals(promoMonthsRemaining({ endsAt: PROMO_END }, PROMO_END), 0);
  assertEquals(promoMonthsRemaining({ endsAt: '2020-01-01T00:00:00.000Z' }, PROMO_START), 0);
  assertEquals(promoMonthsRemaining(null, PROMO_START), 0);
  assertEquals(promoMonthsRemaining({ endsAt: 'garbage' }, PROMO_START), 0);
});

Deno.test('the settlement writes no commission entry when the promo takes none', async () => {
  // A `commission` row of 0.00 is not a neutral no-op: it is a line on the
  // driver's own statement reading "commission GH¢0.00" beside a fare they kept
  // in full, which reads as an account that was meant to be charged and escaped.
  const { settleAgainstTripState, settleFare } = await import('../complete-trip/ledger.ts');
  const duringPromo = settleFare(2.8, PROMO_COMMISSION_RATE);
  assertEquals(duringPromo.commissionGhs, 0);
  assertEquals(duringPromo.driverPayoutGhs, 2.8);
  assertEquals(
    settleAgainstTripState({ tripState: 'completed', paymentState: 'pending', settlement: duringPromo }).ledgerKinds,
    ['fare'],
  );

  const afterPromo = settleFare(2.8, STANDARD_COMMISSION_RATE);
  assertEquals(afterPromo.commissionGhs, 0.42);
  assertEquals(afterPromo.driverPayoutGhs, 2.38);
  assertEquals(
    settleAgainstTripState({ tripState: 'completed', paymentState: 'pending', settlement: afterPromo }).ledgerKinds,
    ['fare', 'commission'],
  );
  // The identity that must hold either way: fare less commission is the payout.
  for (const s of [duringPromo, afterPromo]) {
    assert(Math.abs((s.fareGhs - s.commissionGhs) - s.driverPayoutGhs) < 0.005);
  }
});
