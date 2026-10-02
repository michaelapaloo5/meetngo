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

// The floor, per tier: **GHS 17, 23 and 28** -- what the shortest ride costs.
//
// This was a single GHS 0.15 for every tier, which is why the whole price scale
// was wrong: a per-km rate of 0.28 with a 15-cedi floor means a real Accra trip
// costs exactly what the distance says, which priced Tesano to Dansoman at
// GHS 1.94 / 2.43 / 3.19. One floor for all three tiers also made the tiers
// indistinguishable, because the floor sat above every real fare and all three
// charged the same number.
//
// Mirrors `RideCategory.minFareGhs` in `packages/mng_core`. Both sides must
// agree or the rider is quoted one price and billed another; `_tests/fare.test.ts`
// and `fare_calculator_test.dart` pin the same three numbers.
export const MIN_FARE_GHS: Record<RideCategoryName, number> = {
  lite: 17.0,
  standard: 23.0,
  premium: 28.0,
};

// GHS 6.00, 8.00 and 10.00 per km. `lite` replaces the old `van` slot: it is the
// small-vehicle tier, renamed. Nothing in the product reads `van` as a ride
// category any more, and the name was a poor one for a tier that is about size
// and price rather than about a body style.
//
// Mirrors `RideCategory.perKmGhs` in `packages/mng_core`.
export const PER_KM: Record<RideCategoryName, number> = {
  lite: 6.0,
  standard: 8.0,
  premium: 10.0,
};

const round2 = (v: number) => Math.round(v * 100) / 100;

export function computeFare(input: FareInput): FareQuote {
  if (!Number.isFinite(input.distanceKm)) {
    throw new Error('distanceKm must be finite');
  }
  const km = Math.max(0, input.distanceKm);
  const surge = Math.min(MAX_SURGE, Math.max(1, input.surge));

  // The floor is the tier's own, and it goes on the distance-priced fare. There
  // is no discount term any more.
  //
  // `RIDE30` took 30% off every ride from every rider with no redemption record,
  // capped at GHS 40 here and not at all in the app, so above GHS 133.33 the
  // rider agreed to a price lower than the one they were charged. Removing the
  // offer removes the second calculation, and with it the only place in this
  // product where the number on the screen and the number on the bill could
  // disagree.
  //
  // `input.discountGhs` is still accepted and still floored at zero, so a caller
  // that still passes one is ignored rather than silently pricing below the
  // floor. Nothing does; the field is here so a stale call fails safe.
  const distanceFare = Math.max(
    MIN_FARE_GHS[input.category],
    (BASE_GHS + PER_KM[input.category] * km) * surge,
  );
  const raw = distanceFare + BOOKING_FEE_GHS;

  return {
    fareGhs: round2(Math.max(0, raw)),
    surge,
    discountGhs: 0,
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

