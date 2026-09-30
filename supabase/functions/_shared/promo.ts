// The launch promo, and the only place the rule is written down.
//
// Meet 'N Go gives every driver 100% of the fare for five months from their
// first completed trip. That decision is consulted from two directions -- the
// rider app, which wants to tell the driver how long is left, and
// `complete-trip`, which has to decide what a trip actually settles at -- and
// those two must never disagree about a driver's money. So the rule lives here,
// once, and both import it rather than each doing their own month arithmetic.
//
// `driver_promos` holds the window and a trigger writes it on the driver's
// first completion; nothing in this file writes it. That is deliberate. A
// client with an INSERT policy on that table could set its own `ends_at` to
// 2099 and hold a 0% commission forever, so the table has no INSERT or UPDATE
// policy at all and the only writer is a `security definer` trigger.

export const PROMO_MONTHS = 5;

/** Inside the window the platform takes nothing. */
export const PROMO_COMMISSION_RATE = 0.0;

/** After it, this. The rate that was already in the code before the promo. */
export const STANDARD_COMMISSION_RATE = 0.15;

export interface PromoWindow {
  /** ISO 8601, the end of the window. `driver_promos.ends_at`. */
  endsAt: string;
}

/**
 * The commission rate that applies to a trip completed at `completedAt` for a
 * driver with the given window.
 *
 * A driver with no window has never completed a trip, so there is no trip of
 * theirs to price; this returns the standard rate and the caller should not
 * have a fare to settle in that situation either.
 *
 * `completedAt < endsAt`, not `<=`: a trip landing on the final millisecond of
 * the window is outside it, which is the reading that cannot quietly hand out a
 * sixth month.
 *
 * The trip's own `completed_at` decides, not the moment settlement runs. They
 * are normally the same instant, but if a settlement is ever retried or a trip
 * is written up out of order, dating the promo by "now" would move a trip
 * across the boundary depending on when the machine processed it.
 */
export function commissionRateFor(
  promo: PromoWindow | null,
  completedAt: string,
  standardRate: number = STANDARD_COMMISSION_RATE,
): number {
  if (!Number.isFinite(standardRate)) {
    throw new TypeError(`standardRate must be finite, got ${standardRate}`);
  }
  if (!promo) return standardRate;

  const completed = Date.parse(completedAt);
  const ends = Date.parse(promo.endsAt);
  // A window with an unparseable date is NOT read as "no promo". Falling back
  // to the standard rate here would charge the driver 15% on every ride for
  // five months over a bad string in a column nobody looks at, and it would
  // look entirely normal. Throwing is what makes it visible.
  if (!Number.isFinite(completed) || !Number.isFinite(ends)) {
    throw new TypeError(
      `completedAt and promo.endsAt must be parseable dates, got ${completedAt} and ${promo.endsAt}`,
    );
  }
  return completed < ends ? PROMO_COMMISSION_RATE : standardRate;
}

/** Whole months left, for the driver's own "promo" line. Zero when it is over. */
export function promoMonthsRemaining(promo: PromoWindow | null, now: string): number {
  if (!promo) return 0;
  const ends = Date.parse(promo.endsAt);
  const reference = Date.parse(now);
  if (!Number.isFinite(ends) || !Number.isFinite(reference)) return 0;
  if (ends <= reference) return 0;
  // Rounded up, against 30.44 days: a driver with four days left is told "1
  // month left" rather than "0 months left", because rounding down tells them
  // the promo is over while it is still running.
  return Math.max(0, Math.ceil((ends - reference) / (30.44 * 24 * 60 * 60 * 1000)));
}
