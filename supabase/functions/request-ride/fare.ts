// The TypeScript twin of `FareCalculator` in
// `packages/mng_core/lib/src/fare/fare_calculator.dart`. The two must stay
// numerically identical: the rider app quotes a fare locally and the backend
// quotes the same one, and a divergence between them is a rider who is shown
// one price and charged another. Every literal in the Dart test file has a
// counterpart in `functions/_tests/fare.test.ts`.

export const RIDE_CATEGORY_NAMES = ['lite', 'standard', 'premium'] as const;

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

// The base fare and the booking fee are both zero, and that is a decision
// rather than an oversight. At the old scale -- GHS 5.00 + GHS 1.00 + per-km
// -- those two were 87% of a short Accra ride, so a rider moving 800 m paid
// almost entirely in fixed charges, which is the opposite of what a per-km
// service is for. They are kept as named constants rather than deleted so the
// structure survives for a future base-fare promotion, and so this file and
// its Dart twin keep the same shape.
export const BASE_GHS = 0.0;
export const BOOKING_FEE_GHS = 0.0;
export const MAX_SURGE = 2.0;

// The floor. At 20 cedis/litre and roughly 8 km/litre a vehicle burns about
// GHS 0.025 per km, so the cheapest per-km rate (lite, GHS 0.28) has fuel at
// about 9% of the fare and the dearest (premium, GHS 0.46) at about 5% -- the
// floor is below the fuel line at every distance, and it is here so that the
// thinnest possible margin still covers the driver on a very short hop rather
// than to set a price. GH¢0.15 is 15 cedis.
export const MIN_FARE_GHS = 0.15;

// GH¢0.28, GH¢0.35 and GH¢0.46 per km -- 28, 35 and 46 cedis. `lite` replaces
// the old `van` slot: it is the small-vehicle tier, renamed. Nothing in the
// product reads `van` as a ride category any more, and the name was a poor one
// for a tier that is about size and price rather than about a body style.
export const PER_KM: Record<RideCategoryName, number> = {
  lite: 0.28,
  standard: 0.35,
  premium: 0.46,
};

const round2 = (v: number) => Math.round(v * 100) / 100;

export function computeFare(input: FareInput): FareQuote {
  if (!Number.isFinite(input.distanceKm)) {
    throw new Error('distanceKm must be finite');
  }
  const km = Math.max(0, input.distanceKm);
  const surge = Math.min(MAX_SURGE, Math.max(1, input.surge));
  const discount = Math.max(0, input.discountGhs);

  // The floor is applied to the distance-priced fare and *then* the discount
  // comes off, not the other way round. Folding them together -- discounting
  // first and flooring the result -- makes a promo code unable to reduce any
  // short trip at all, because the floor swallows the whole discount and the
  // rider is told they paid less when they did not. Flooring last would go the
  // other way and let a discount push a fare below the cost of moving the car.
  // The distance is what the floor is about, so it is applied to the distance.
  const distanceFare = Math.max(MIN_FARE_GHS, (BASE_GHS + PER_KM[input.category] * km) * surge);
  const raw = distanceFare + BOOKING_FEE_GHS - discount;

  return {
    fareGhs: round2(Math.max(0, raw)),
    surge,
    discountGhs: discount,
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

// ---------------------------------------------------------------------------
// The launch promo lives in `_shared/promo.ts` and is re-exported here because
// callers of this file already import everything they need from one place. The
// definition is NOT here: `complete-trip` has to ask the same question when it
// settles a fare, and two copies of a five-month rule is one too many.
export {
  PROMO_MONTHS,
  PROMO_COMMISSION_RATE,
  STANDARD_COMMISSION_RATE,
  commissionRateFor,
  promoMonthsRemaining,
  type PromoWindow,
} from '../_shared/promo.ts';

