import { assertEquals } from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import { computeFare, promoDiscountGhs, type RideCategoryName } from '../request-ride/fare.ts';

Deno.test('standard 8km fare matches the Dart calculator', () => {
  const q = computeFare({ category: 'standard', distanceKm: 8, surge: 1, discountGhs: 0 });
  assertEquals(q.fareGhs, 20.4);
});

Deno.test('premium 10km beats standard 10km', () => {
  const s = computeFare({ category: 'standard', distanceKm: 10, surge: 1, discountGhs: 0 });
  const p = computeFare({ category: 'premium', distanceKm: 10, surge: 1, discountGhs: 0 });
  assertEquals(p.fareGhs > s.fareGhs, true);
});

Deno.test('surge multiplies the whole base-plus-distance and is capped at 2x', () => {
  // (5.00 + 1.80 * 5) * 1.5 + 1.00 = 22.00
  const surged = computeFare({ category: 'standard', distanceKm: 5, surge: 1.5, discountGhs: 0 });
  assertEquals(surged.fareGhs, 22.0);
  // (5.00 + 1.80 * 5) * 2.0 + 1.00 = 29.00, surge 5 clamps to 2.0
  const capped = computeFare({ category: 'standard', distanceKm: 5, surge: 5, discountGhs: 0 });
  assertEquals(capped.fareGhs, 29.0);
});

Deno.test('surge below 1 is lifted to 1', () => {
  const q = computeFare({ category: 'standard', distanceKm: 5, surge: 0.2, discountGhs: 0 });
  assertEquals(q.fareGhs, 15.0);
});

Deno.test('negative distance collapses to the base fare', () => {
  const q = computeFare({ category: 'standard', distanceKm: -3, surge: 1, discountGhs: 0 });
  assertEquals(q.fareGhs, 6.0);
});

Deno.test('NaN distance throws', () => {
  let threw = false;
  try {
    computeFare({ category: 'standard', distanceKm: NaN, surge: 1, discountGhs: 0 });
  } catch {
    threw = true;
  }
  assertEquals(threw, true);
});

Deno.test('over-large discount never yields a negative fare', () => {
  const q = computeFare({ category: 'standard', distanceKm: 0, surge: 1, discountGhs: 999 });
  assertEquals(q.fareGhs, 0);
});

// The seven cases above are all exact in binary once clamping is applied, so a
// round2 that does nothing passes every one of them. Measured on deno 2.9.7:
// the raw total here is 16.158 (the double nearest it is 16.158000000000001),
// and 16.158 === 16.16 is false, so this is the only case in the file that
// discriminates rounding from no rounding. The Dart suite still has no
// equivalent case; see task-6-report.md.
Deno.test('fare is rounded to 2 decimal places, not left at 3', () => {
  // (5.00 + 1.80 * 3.7) * 1.3 + 1.00 = 16.158 raw, so 16.16 rounded.
  const q = computeFare({ category: 'standard', distanceKm: 3.7, surge: 1.3, discountGhs: 0 });
  assertEquals(q.fareGhs, 16.16);
  assertEquals(q.fareGhs === 16.158, false);
});

// The discount is a share of the fare actually quoted, not of a distance
// multiplied by the standard per-km rate, so a premium ride is discounted at the
// premium rate. Same trip, same promo, measured on deno 2.9.7:
//   standard 10 km at surge 1.2 grosses 28.60, premium grosses 40.60,
//   so RIDE30 (30% off, capped at 40.00) takes 8.58 off a standard ride and
//   12.18 off a premium one. The category-blind 1.8-per-km formula the brief
//   used returns 5.40 for both and is caught by the exact literals.
Deno.test('the same promo takes more off a premium ride than a standard one', () => {
  const distanceKm = 10;
  const surge = 1.2;
  const discountFor = (category: RideCategoryName) =>
    promoDiscountGhs(
      computeFare({ category, distanceKm, surge, discountGhs: 0 }).fareGhs,
      30,
      40,
    );
  assertEquals(discountFor('standard'), 8.58);
  assertEquals(discountFor('premium'), 12.18);
  assertEquals(discountFor('premium') > discountFor('standard'), true);
});

// `promos.max_discount_ghs` has no CHECK constraint, and a negative value there
// makes `min(gross * percent_off / 100, cap)` negative, which the second
// `computeFare` call then *adds* to the total: a premium ride quoted at 40.60
// is stored at 80.60 while `quote.discountGhs` reports 0. Measured on this
// host: `insert into promos (code, percent_off, max_discount_ghs) values
// ('NEG1', 30, -40.00, true)` is accepted. A percent outside 0..100 is refused
// by the `percent_off` check constraint, so the sign hole is on the cap, but
// this is the pure function and it is total for every finite input.
Deno.test('a negative promo cap cannot raise the fare above the gross quote', () => {
  const trip = { category: 'premium' as const, distanceKm: 10, surge: 1.2 };
  const gross = computeFare({ ...trip, discountGhs: 0 });

  const discount = promoDiscountGhs(gross.fareGhs, 30, -40);
  const quote = computeFare({ ...trip, discountGhs: discount });

  assertEquals(discount, 0);
  assertEquals(quote.fareGhs, gross.fareGhs);
});

Deno.test('a promo percent outside 0 to 100 is clamped rather than applied', () => {
  const gross = computeFare({ category: 'premium', distanceKm: 10, surge: 1.2, discountGhs: 0 });
  assertEquals(promoDiscountGhs(gross.fareGhs, 250, 1000), 40.6);
  assertEquals(promoDiscountGhs(gross.fareGhs, -30, 1000), 0);
});
