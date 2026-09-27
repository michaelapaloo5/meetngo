// The TypeScript twin of `FareCalculator` in
// `packages/mng_core/lib/src/fare/fare_calculator.dart`. The two must stay
// numerically identical: the rider app quotes a fare locally and the backend
// quotes the same one, and a divergence between them is a rider who is shown
// one price and charged another. Every literal in the Dart test file has a
// counterpart in `functions/_tests/fare.test.ts`.

export const RIDE_CATEGORY_NAMES = ['standard', 'premium', 'van'] as const;

export type RideCategoryName = (typeof RIDE_CATEGORY_NAMES)[number];

export interface FareInput {
  category: RideCategoryName;
  distanceKm: number;
  surge: number;
  discountGhs: number;
}

export interface FareQuote {
  fareGhs: number;
  surge: number;
  discountGhs: number;
  distanceKm: number;
}

export const BASE_GHS = 5.0;
export const BOOKING_FEE_GHS = 1.0;
export const MAX_SURGE = 2.0;
export const PER_KM: Record<RideCategoryName, number> = {
  standard: 1.8,
  premium: 2.8,
  van: 2.2,
};

const round2 = (v: number) => Math.round(v * 100) / 100;

export function computeFare(input: FareInput): FareQuote {
  if (!Number.isFinite(input.distanceKm)) {
    throw new Error('distanceKm must be finite');
  }
  const km = Math.max(0, input.distanceKm);
  const surge = Math.min(MAX_SURGE, Math.max(1, input.surge));
  const raw = (BASE_GHS + PER_KM[input.category] * km) * surge + BOOKING_FEE_GHS - input.discountGhs;
  return {
    fareGhs: round2(Math.max(0, raw)),
    surge,
    discountGhs: Math.max(0, input.discountGhs),
    distanceKm: km,
  };
}

// A promo is a share of the fare actually quoted, so it takes the base fare,
// the booking fee, the surge and the requested category's per-km rate into
// account. `percent_off` of the distance at the standard per-km rate, which is
// what this used to do, under-discounts every category and ignores the base and
// booking fee entirely: on a 10 km standard ride at surge 1.2 it returns 5.40
// against a gross of 28.60.
//
// Call it with the gross quote, that is the quote for the same trip with
// `discountGhs: 0`, and feed the result back into a second `computeFare` call.
// Both calls are pure, which is what makes the two-step pricing testable
// without a database.
//
// All three arguments are clamped to their valid range rather than trusted, so
// the function is total for every finite input and no caller can be talked into
// a discount that is really a surcharge. The sign hole that made this necessary
// is real: `promos.max_discount_ghs` has no CHECK constraint, and a negative
// cap makes `min(gross * percent / 100, cap)` negative, which the second
// `computeFare` call then *adds* to the total — a premium ride quoted at 40.60
// stored at 80.60 while `quote.discountGhs` reports 0. `percent_off` is
// constrained to (0, 100] by the schema, so the cap is the only column that can
// arrive wrong; the percent is clamped anyway so the pure function does not
// depend on a constraint in another file.
//
// A non-finite argument is not clamped here: `Math.max(0, NaN)` is NaN, and
// quietly turning a corrupt row into "no discount" would be the silent-money
// defect this whole function exists to avoid. `index.ts` refuses a non-finite
// promo row with a 500 before it gets here.
export function promoDiscountGhs(
  grossFareGhs: number,
  percentOff: number,
  maxDiscountGhs: number,
): number {
  const gross = Math.max(0, grossFareGhs);
  const percent = Math.min(100, Math.max(0, percentOff));
  const cap = Math.max(0, maxDiscountGhs);
  return round2(Math.min((gross * percent) / 100, cap));
}

