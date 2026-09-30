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
  // 0.35 * 8 = 2.80
  assertEquals(q('standard', 8).fareGhs, 2.8);
});

Deno.test('the backend and the app quote the same fare for every category', () => {
  // The twin of `labels match the launch set and carry per-km rates` in
  // `packages/mng_core/test/fare_calculator_test.dart`. The rider app quotes
  // locally and this function quotes again; a divergence is a rider shown one
  // price and charged another, and neither suite would see it alone. The rates
  // and the floor are literals in both languages on purpose.
  assertEquals(RIDE_CATEGORY_NAMES, ['lite', 'standard', 'premium']);
  assertEquals(PER_KM.lite, 0.28);
  assertEquals(PER_KM.standard, 0.35);
  assertEquals(PER_KM.premium, 0.46);
  assertEquals(BASE_GHS, 0.0);
  assertEquals(BOOKING_FEE_GHS, 0.0);
  assertEquals(MIN_FARE_GHS, 0.15);
});

Deno.test('there is no base fare and no booking fee left to pay', () => {
  // The old model was 5.00 + 1.00 + per-km, so a short ride was almost entirely
  // fixed charges on a service sold by the kilometre.
  assertEquals(q('standard', 0.8).fareGhs, 0.28);
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
  // (0.35 * 5) * 1.5 = 2.625 -> 2.63
  assertEquals(q('standard', 5, 1.5).fareGhs, 2.63);
  // (0.35 * 5) * 2.0 = 3.50, surge 5 clamps to 2.0
  assertEquals(q('standard', 5, 5).fareGhs, 3.5);
});

Deno.test('surge below 1 is lifted to 1', () => {
  assertEquals(q('standard', 5, 0.2).fareGhs, 1.75);
});

Deno.test('a ride under about half a kilometre costs the 15 cedi floor', () => {
  // 0.15 / 0.35 = 0.43 km. Below that a standard ride is 0.15 whatever the
  // distance, which is the guarantee that a driver does not lose the cost of
  // moving the car on a tiny hop.
  assertEquals(q('standard', 0.2).fareGhs, 0.15);
  assertEquals(q('standard', 0.43).fareGhs, 0.15);
  assertEquals(q('standard', 0).fareGhs, 0.15);
});

Deno.test('a discount can take a short ride below the floor, and must', () => {
  // The floor is applied to the distance-priced fare and the discount comes off
  // afterwards. Folding them together makes the floor swallow the whole
  // discount, so a rider redeeming a promo code on a 200 m trip is charged the
  // full 0.15 and shown a discount that did nothing.
  assertEquals(q('standard', 0.2, 1, 0.10).fareGhs, 0.05);
});

Deno.test('negative distance collapses to the floor, not below it', () => {
  assertEquals(q('standard', -3).fareGhs, 0.15);
});

Deno.test('NaN distance throws', () => {
  assertThrows(() => q('standard', NaN));
});

Deno.test('over-large discount never yields a negative fare', () => {
  assertEquals(q('standard', 0, 1, 999).fareGhs, 0);
});

// The cases above are all exact in binary once clamping is applied, so a round2
// that does nothing passes every one of them. Measured on this host the raw
// total here is 1.6835 and `1.6835 === 1.68` is false, so this is the only
// case in the file that discriminates rounding from no rounding.
//
// The twin is `fare is rounded to 2 decimal places, not left at 3` in
// `packages/mng_core/test/fare_calculator_test.dart`, with the same
// 3.7 km / surge 1.3 / 1.68. Both literals change together, in one commit: a
// client quoting 1.6835 and a backend storing 1.68 disagree by half a cedi and
// neither suite would notice on its own.
Deno.test('fare is rounded to 2 decimal places, not left at 3', () => {
  // (0.35 * 3.7) * 1.3 = 1.6835 raw, so 1.68 rounded.
  const quote = q('standard', 3.7, 1.3);
  assertEquals(quote.fareGhs, 1.68);
  assertEquals(quote.fareGhs === 1.6835, false);
});

Deno.test('the same promo takes more off a premium ride than a standard one', () => {
  // The discount is a share of the fare actually quoted, so a premium ride is
  // discounted at the premium rate. 10 km at surge 1.2 grosses 4.20 for
  // standard and 5.52 for premium, so 30% off takes 1.26 and 1.66.
  const distanceKm = 10;
  const surge = 1.2;
  const discountFor = (category: RideCategoryName) =>
    promoDiscountGhs(q(category, distanceKm, surge).fareGhs, 30, 40);
  assertEquals(discountFor('standard'), 1.26);
  assertEquals(discountFor('premium'), 1.66);
  assertEquals(discountFor('premium') > discountFor('standard'), true);
});

Deno.test('a negative promo cap cannot raise the fare above the gross quote', () => {
  // `promos.max_discount_ghs` has no CHECK constraint, and a negative value
  // there makes `min(gross * percent_off / 100, cap)` negative, which the
  // second `computeFare` call then *adds* to the total.
  const trip = { category: 'premium' as const, distanceKm: 10, surge: 1.2 };
  const gross = computeFare({ ...trip, discountGhs: 0 });
  const discount = promoDiscountGhs(gross.fareGhs, 30, -40);
  assertEquals(discount, 0);
  assertEquals(computeFare({ ...trip, discountGhs: discount }).fareGhs, gross.fareGhs);
});

Deno.test('a promo percent outside 0 to 100 is clamped rather than applied', () => {
  const gross = q('premium', 10, 1.2).fareGhs;
  assertEquals(promoDiscountGhs(gross, 250, 1000), 5.52);
  assertEquals(promoDiscountGhs(gross, -30, 1000), 0);
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
