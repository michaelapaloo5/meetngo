import { corsHeaders } from '../_shared/cors.ts';
// The six trip states are defined once, in `cancel-trip/policy.ts`, and read
// from there rather than restated. The guard is the one thing standing between
// an unrecognised value and the branch that pays money, and a second copy of
// the six names is a second thing to forget to extend. A relative import out of
// the function's own directory is not a new deployment shape either: every
// function here already reaches `../_shared/cors.ts` and `../offers/clients.ts`.
import { isTripStateName } from '../cancel-trip/policy.ts';
// The launch promo's rule, imported rather than restated. `request-ride` asks
// the same module the same question, and a second copy of a five-month rule is
// how a driver ends up quoted one rate and paid another.
import { commissionRateFor, STANDARD_COMMISSION_RATE, type PromoWindow } from '../_shared/promo.ts';
import { readFareGhs, settleAgainstTripState, settleFare } from './ledger.ts';

// The HTTP surface of `complete-trip`, and nothing that talks to a client.
//
// The brief's draft of this function was one `serve()` callback in `index.ts`,
// which is unimportable -- a test that imports it starts a server -- so the
// settlement, the money identity, the ratings write and all fourteen behaviours
// in the table below had no test at all. Task 10's review raised that exact
// shape as a Critical against `cancel-trip/index.ts`, and the fix there is this
// one: the routing, the status codes and the bodies live here, `clients.ts`
// builds the ports out of one service-role client, and `index.ts` is the
// wiring. Nothing here imports supabase-js.

const json = (status: number, payload: Record<string, unknown>) =>
  new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

/**
 * The `trips` row as the ownership read returns it, snake_case because that is
 * what comes off the wire. `state` is a plain `string` and not the `TripStateName`
 * union on purpose: the whole point of the `isTripStateName` guard below is that
 * this value is unverified, and typing it as the union would let the guard read
 * as redundant. `fare_ghs` is `unknown` for the same reason -- it is checked by
 * `readFareGhs` rather than cast, because a cast would let a row that lost its
 * fare settle as `GHS 0.00`. The index signature is the other half of all of
 * that: the 200 body echoes the row, so the handler has to be able to carry
 * columns it never reads.
 */
export interface TripRow {
  id: string;
  rider_id: string;
  driver_id: string | null;
  state: string;
  fare_ghs: unknown;
  /**
   * The launch promo is dated from this and not from "now", so that a trip
   * settled late, or written up out of order, cannot cross the five-month
   * boundary on the strength of when the function happened to run.
   *
   * Nullable because `ongoing` and `requested` trips have none, and the handler
   * only reads it on a completed trip.
   */
  completed_at?: string | null;
  [column: string]: unknown;
}

export interface PaymentRow {
  id: string;
  trip_id: string;
  payer_id: string;
  amount_ghs: unknown;
  method: string;
  state: string;
  [column: string]: unknown;
}

/**
 * One row of `ledger_entries` as this function writes it.
 *
 * `kind` is a string and not a union of the five the CHECK allows
 * (`init.sql:126`) because the handler chooses it and the client binds it; the
 * values it can produce are those five and the test pins them. `amountGhs` is
 * signed, and the `commission` row is negative: that is what makes the fare and
 * the commission sum to the payout.
 */
export interface LedgerEntryInput {
  kind: string;
  amountGhs: number;
  note: string;
}

export interface RatingInput {
  tripId: string;
  raterId: string;
  rateeId: string;
  fromRole: 'rider' | 'driver';
  stars: number;
  comment: string;
}

export interface CompleteDeps {
  // Resolves a bearer token to a user id. **Only `userId` is checked**: this
  // handler takes the identity as its `callerId` argument and answers 401 on a
  // null one, and the port's `error` is carried for the house shape -- Task 10's
  // `CancelDeps.authenticate` and Task 6's `OfferDeps.authenticate` both declare
  // it, and both of *their* handlers do check both
  // (`cancel-trip/handler.ts:110-111`, `offers/handler.ts:88-89`). Nothing in
  // this file reads it, so a comment here claiming otherwise is a claim about
  // code that is not there.
  authenticate(token: string): Promise<{ userId: string | null; error: string | null }>;
  findTrip(tripId: string): Promise<{ row: TripRow | null; error: string | null }>;
  /**
   * The trip's newest `payments` row, whatever state it is in.
   *
   * The name says "open" because an open row is what a caller usually wants,
   * but this port must **not** filter on `state = 'pending'`, and the reason is
   * the money. `complete-trip` flips the payment to `succeeded` *before* it
   * writes the ledger, so on the retry that follows a failed ledger write the
   * row is no longer pending: a pending-only read would find nothing, the
   * handler would read an absent payment as a pending one, and it would write
   * the fare and the payout a second time. The brief's draft read the newest row
   * with no state filter, and that is what this port is.
   */
  findOpenPayment(tripId: string): Promise<{ row: PaymentRow | null; error: string | null }>;
  /**
   * The two payment writes, and they have two different failure answers: an
   * error from the database is a 500 and a zero-row match is a 404, so the port
   * carries both rather than the single boolean the brief's Interfaces block had.
   * A zero-row match is a lost race -- the row was deleted or already moved
   * between the read above and this write -- and it is a 404 because the payment
   * the caller asked to charge is not there, not because the database refused.
   */
  markPaymentSucceeded(paymentId: string): Promise<{ row: PaymentRow | null; error: string | null }>;
  markPaymentVoided(paymentId: string): Promise<{ row: PaymentRow | null; error: string | null }>;
  writeLedger(
    tripId: string,
    driverId: string,
    entries: LedgerEntryInput[],
  ): Promise<{ ok: boolean; error: string | null }>;
  writePayout(
    tripId: string,
    driverId: string,
    amountGhs: number,
  ): Promise<{ ok: boolean; error: string | null }>;
  /**
   * The driver's launch-promo window, or null when they have never completed a
   * trip and so have no window yet.
   *
   * This is a read and never a write. `driver_promos` carries no INSERT or
   * UPDATE policy, so a client cannot hand itself five free years, and the
   * window itself is opened by a `security definer` trigger on the driver's
   * first completion. What the window *means* is `_shared/promo.ts`, not this
   * file.
   *
   * `error` is separate from `window` on purpose: a failed lookup must not
   * arrive as `null`, because `null` is a real answer here meaning "no promo",
   * and reading a database error as "this driver has no promo" would quietly
   * take 15% off every trip they drive for five months.
   */
  findPromoWindow(driverId: string): Promise<{ window: PromoWindow | null; error: string | null }>;
  /**
   * Write the rate this trip actually settled at, onto `trips`, once.
   *
   * Stored rather than recomputed on read: a driver who crosses five months
   * would otherwise find their earlier trips repriced, with no row explaining
   * where the commission came from. A driver who worked a trip for 100% should
   * still be able to see that they did, after the promo has ended.
   */
  recordCommissionRate(tripId: string, rate: number): Promise<{ ok: boolean; error: string | null }>;
  /**
   * `duplicate` is the port's own reading of the insert rather than the
   * handler's, because the discriminator is PostgREST's `code` field and
   * `clients.ts` owns that.
   */
  writeRating(input: RatingInput): Promise<{ ok: boolean; duplicate: boolean }>;
}

/**
 * What the response says about the rating, which the settlement is not allowed
 * to depend on. `skipped` is a call with no `rating` in the body at all.
 */
export type RatingState = 'skipped' | 'recorded' | 'duplicate' | 'failed';

/**
 * The body of a `complete-trip` call, read off the request's JSON before
 * anything is looked up.
 *
 * Split out of `index.ts` so it is reachable from a test, which is the point of
 * the split: `tripId` is not optional in the call, and the brief's draft passed
 * whatever `req.json()` produced straight into `.eq('id', tripId)`, where a
 * missing `tripId` became a filter that matched nothing and therefore a 404
 * naming a trip that does not exist.
 *
 * `stars` is deliberately **not** range-checked here. It is checked in
 * `handleComplete`, against `Rating.isValidStars`'s rule, because a rating of 0
 * or 6 is a decision this function makes and reports as its own 400 rather than
 * as a malformed request. A non-number is a different thing and is refused
 * here, where the shape of the body is the question.
 */
export function readCompleteBody(body: unknown):
  | { ok: true; tripId: string; rating?: { stars: number; comment: string } }
  | { ok: false; error: string } {
  const record = typeof body === 'object' && body !== null && !Array.isArray(body)
    ? body as Record<string, unknown>
    : null;
  if (!record) return { ok: false, error: 'body must be a JSON object' };

  const tripId = record['tripId'];
  if (typeof tripId !== 'string' || tripId.length === 0) {
    return { ok: false, error: 'tripId is required' };
  }

  const rawRating = record['rating'];
  if (rawRating === undefined || rawRating === null) return { ok: true, tripId };
  if (typeof rawRating !== 'object' || Array.isArray(rawRating)) {
    return { ok: false, error: 'rating must be an object' };
  }
  const { stars, comment } = rawRating as Record<string, unknown>;
  if (typeof stars !== 'number') {
    return { ok: false, error: 'rating.stars must be a number' };
  }
  return {
    ok: true,
    tripId,
    rating: { stars, comment: typeof comment === 'string' ? comment : '' },
  };
}

export async function handleComplete(input: {
  deps: CompleteDeps;
  // Null when the request carried no `Bearer ` token, or when the auth server
  // refused the one it did. Both are the same 401, and the handler is where the
  // 401 lives, so the refusal is reachable from a test rather than sitting in
  // `index.ts` beside `serve()`.
  callerId: string | null;
  tripId: string;
  rating?: { stars: number; comment: string };
}): Promise<Response> {
  const { deps, tripId } = input;
  const callerId = input.callerId;
  if (!callerId) return json(401, { error: 'unauthenticated' });

  // The range check is here, before the first lookup and before any write, and
  // it is a refusal of the whole call rather than a note in the body. The two
  // rules it could have lived under want different answers: a rating of 0 or 6
  // is a malformed request, and `ratings.stars` carries `check (stars between 1
  // and 5)` (`init.sql:138`) so the value would otherwise arrive as a 500 from
  // the CHECK; but a rating whose *write* fails must not unsettle a completed
  // trip, so that failure is reported in the body of a 200 instead. Nothing has
  // been settled yet when this runs, so a 400 here costs the rider nothing.
  //
  // `Rating.isValidStars` is `stars >= 1 && stars <= 5`
  // (`packages/mng_core/lib/src/models/rating.dart:24`), reimplemented because
  // this is TypeScript and that is Dart: the rule is those two comparisons, and
  // `Number.isInteger` is what keeps a `2.5` or a `NaN` from passing them.
  if (input.rating !== undefined &&
    (!Number.isInteger(input.rating.stars) || input.rating.stars < 1 || input.rating.stars > 5)) {
    return json(400, { error: 'stars must be 1 to 5' });
  }

  const { row: trip, error: tripError } = await deps.findTrip(tripId);
  if (tripError) return json(500, { error: 'trip lookup failed' });
  if (!trip) return json(404, { error: 'trip not found' });

  // Either party may settle: the rider is who pays and the driver is who is
  // paid, and a demo trip's settlement is a function of the fare rather than of
  // which of the two pressed the button. The comparison is against the validated
  // identity and never against a field of the body, which is the authorisation
  // the service key bypasses: `trips` carries no INSERT policy, and `revoke
  // update on trips from anon, authenticated` with a grant of `(state,
  // eta_minutes, started_at, completed_at)` (`init.sql:614-615`) leaves this
  // function unable to move the trip on the caller's own credential either.
  if (trip.rider_id !== callerId && trip.driver_id !== callerId) {
    return json(403, { error: 'not your trip' });
  }

  // Checked rather than cast, and the check is load-bearing:
  // `settleAgainstTripState` branches on this string, and an unrecognised value
  // used to reach the charge branch as though it were `completed`. This is the
  // same guard, and the same 500, as `cancel-trip`'s
  // (`cancel-trip/handler.ts:124-126`).
  if (!isTripStateName(trip.state)) {
    return json(500, { error: 'trip row carries a state this build does not know' });
  }

  // A trip that is neither finished nor cancelled has nothing to settle, and the
  // brief's draft answered it with a 200 carrying a `settlement` and a
  // `paymentState` nobody had written: a receipt for a ride still in progress,
  // which is what the rider's screen renders as a total. Worse, that draft ran
  // its void branch on *every* `!shouldCharge` outcome, so calling this on an
  // `arriving` trip voided the pending demo charge. This is the refusal, and it
  // is answered from the trip row alone, before the payment is even read. The
  // body carries the `error` key `describeFunctionFailure` reads
  // (`apps/rider/lib/src/data/function_failure.dart:29-38`).
  if (trip.state !== 'completed' && trip.state !== 'cancelled') {
    return json(409, { error: 'This trip is not complete yet', trip });
  }

  const fareGhs = readFareGhs(trip);
  if (fareGhs === null) {
    return json(500, { error: 'trip row carries no finite fare' });
  }

  // The launch promo, and the order matters: the rate is resolved from the
  // driver's window and the trip's own `completed_at` BEFORE the fare is
  // settled, so there is exactly one rate in this function and no window where
  // a fare was computed and a different rate recorded.
  //
  // A trip with no driver cannot be inside a promo -- a promo is opened by
  // completing a trip as a driver -- and a driver-less trip writes no ledger
  // and no payout below, so it settles at the standard rate and is not
  // recorded. Recording it would put a number on a trip that earned nothing.
  //
  // ## The second caller does not pay twice
  //
  // Every finished ride has two callers of this function: the driver, and then
  // the rider's own app the moment the trip reads as completed. Measured against
  // the live database -- `toolchain/verify-complete-trip-twice.mjs` -- the second
  // call answered 200 with an *identical* settlement and wrote a second fare, a
  // second commission and a second payout. Ledger 2 rows became 4, payouts 1
  // became 2.
  //
  // That is why it survived. Both calls compute the same 51.20 and the same
  // 43.52, so the rider's receipt was correct and nothing anywhere disagreed --
  // the driver was simply credited twice, which no screen shows anybody. The
  // rider app's own workaround for a missing receipt was covering for it.
  //
  // `trips.commission_rate` is the marker, and it is the right one because of
  // the order it is written in below: last, on the charge path, and only there.
  // A settlement that failed half way leaves it null, so a genuine retry still
  // writes the money. A settlement that finished leaves it set, so a repeat does
  // not.
  const alreadySettled =
    trip.commission_rate !== null && trip.commission_rate !== undefined;
  let commissionRate = STANDARD_COMMISSION_RATE;
  if (trip.driver_id && alreadySettled) {
    // Honour the rate that was decided rather than resolving a fresh one.
    //
    // The recorded number is the one in the ledger, and a retry that recomputed
    // the rate from today's promo window would report a settlement that does not
    // match what the driver was actually paid -- a correct-looking answer to the
    // wrong question. So the recorded value wins, always.
    const recorded = Number(trip.commission_rate);
    if (!Number.isFinite(recorded)) {
      // Settled, but the rate on the row is not a number. Something wrote money
      // without recording why, and guessing here would silently change a payout
      // that has already been made. Worth a 500.
      return json(500, { error: 'trip is settled but its recorded commission rate is unreadable' });
    }
    commissionRate = recorded;
  } else if (trip.driver_id) {
    const { window, error: promoError } = await deps.findPromoWindow(trip.driver_id);
    if (promoError) return json(500, { error: 'promo lookup failed' });
    // Dated from the trip's `completed_at`, falling back to now() only for a
    // completed trip that somehow carries no timestamp. The fallback is
    // deliberate and cannot silently favour the platform: a missing
    // `completed_at` on a settled trip is itself a data fault worth a 500, and
    // `now()` is the closest honest reading of when it was completed.
    const completedAt = trip.completed_at ?? new Date().toISOString();
    try {
      commissionRate = commissionRateFor(window, completedAt);
    } catch (err) {
      // `commissionRateFor` throws on an unparseable date rather than guessing.
      // Guessing would mean either charging a driver who should pay nothing, or
      // giving the service away, and neither is something to decide on a
      // malformed string.
      return json(500, { error: `promo window is unreadable: ${(err as Error).message}` });
    }
  }

  const settlement = settleFare(fareGhs, commissionRate);

  const { row: payment, error: paymentError } = await deps.findOpenPayment(trip.id);
  if (paymentError) return json(500, { error: 'payment lookup failed' });

  const decision = settleAgainstTripState({
    tripState: trip.state,
    paymentState: payment?.state ?? 'pending',
    settlement,
  });

  if (!decision.shouldCharge) {
    if (decision.paymentState === 'voided' && payment && payment.state !== 'voided') {
      const { row: voided, error: voidError } = await deps.markPaymentVoided(payment.id);
      if (voidError) return json(500, { error: 'void write failed' });
      if (!voided) return json(404, { error: 'payment not found' });
      // One entry, of the kind the decision asked for -- `['void']` for every
      // state that reaches here. `ledger_entries.driver_id` is `not null`
      // (`init.sql:123`), which is why this is written only when the trip has a
      // driver at all; the amount, a zero rather than a negative, is
      // `ledgerEntriesFor`'s.
      if (trip.driver_id) {
        const entries = ledgerEntriesFor(decision.ledgerKinds, settlement);
        if (entries === null) {
          return json(500, { error: 'settlement asked for a ledger entry this build does not know' });
        }
        const written = await deps.writeLedger(trip.id, trip.driver_id, entries);
        if (!written.ok) {
          return json(500, { error: 'void ledger write failed' });
        }
      }
    }
    // A rating is written on this path too, and for the same reason: a rider who
    // rates a cancelled trip is answering a question the rider was asked.
    return json(200, { trip, settlement, paymentState: decision.paymentState, ...await rateTrip(input, trip, deps) });
  }

  // The charge. The payment first, then the two money writes, each checked. The
  // payment is already `succeeded` by the time a failed ledger write answers
  // 500, so that 500 is not a refusal that rolled anything back -- it is the
  // report. The retry is what `settleAgainstTripState`'s already-succeeded guard
  // keeps from paying twice.
  if (payment) {
    const { row: paid, error: paidError } = await deps.markPaymentSucceeded(payment.id);
    if (paidError) return json(500, { error: 'payment write failed' });
    if (!paid) return json(404, { error: 'payment not found' });
  }
  // `!alreadySettled` is the whole point of this branch being guarded.
    //
    // The comment above it says the retry path "is already idempotent on the
    // payment so it will not pay twice", and that was true of the payment and
    // nothing else. These three writes are plain inserts: the ledger took a second
    // fare and commission and the payout a second row, and because the settlement
    // recomputes identically both times, the response looked correct while the
    // money did not. Verified live before and after this guard.
    if (trip.driver_id && !alreadySettled) {
    // The money identity, and the kinds come from `decision.ledgerKinds` rather
    // than from a second hand-written list. The decision is what worked out what
    // this trip owes, so a copy of the two kinds written out here could disagree
    // with it: `ledgerKinds: ['fare']` on a completed trip was a mutation no test
    // could see, because the handler wrote its own pair whatever the decision
    // said. It cannot now -- fewer kinds, fewer rows -- and the identity is
    // asserted over what the fakes were asked to write, not over an expression in
    // the test.
    //
    // The two amounts must sum to `Settlement.driverPayoutGhs` and to
    // `payouts.amount_ghs`, and they do by construction rather than by
    // coincidence: the `fare` entry is the **gross** `settlement.fareGhs`, and
    // the `commission` entry is `-(fareGhs - driverPayoutGhs)`, derived and not
    // `settlement.commissionGhs`. The draft had the fare entry carrying the
    // **net** payout *and* a negative commission against the same `driver_id`,
    // which is `not null` (`init.sql:123`); that netted 14.28 against a 17.34
    // payout, and `ledger_entries` is the driver's only per-trip record of what
    // they are owed, so the error would have been permanent. Deriving the
    // commission from the payout keeps the pair summing correctly even if
    // `settleFare`'s rounding ever moves: the sum is an identity in the code, not
    // a coincidence of two independently rounded numbers.
    const entries = ledgerEntriesFor(decision.ledgerKinds, settlement);
    if (entries === null) {
      return json(500, { error: 'settlement asked for a ledger entry this build does not know' });
    }
    const { ok: ledgerOk } = await deps.writeLedger(trip.id, trip.driver_id, entries);
    if (!ledgerOk) return json(500, { error: 'ledger write failed' });

    const { ok: payoutOk } = await deps.writePayout(
      trip.id,
      trip.driver_id,
      settlement.driverPayoutGhs,
    );
    if (!payoutOk) return json(500, { error: 'payout write failed' });

    // Last, and only on the path that actually charged. Writing it earlier --
    // before the payment, or on a cancelled trip -- would record a rate for a
    // settlement that never happened, and a later retry would then read that
    // stale number as though it had been decided.
    //
    // A failure here is reported but does not undo the payment or the ledger:
    // those are the money, and they are already written. Returning 500 tells
    // the driver the receipt is not trustworthy, which is the truth, and the
    // retry path is already idempotent on the payment so it will not pay twice.
    const { ok: rateOk } = await deps.recordCommissionRate(trip.id, commissionRate);
    if (!rateOk) return json(500, { error: 'trip settled but its commission rate was not recorded' });
  }

  return json(200, { trip, settlement, paymentState: decision.paymentState, ...await rateTrip(input, trip, deps) });
}

/**
 * The `ledger_entries` rows a decision asks for, or null for a kind this build
 * does not have an amount for.
 *
 * `settleAgainstTripState` decides which kinds a trip owes and this turns that
 * list into rows, so the two cannot drift: the list the decision reports is the
 * list that is written, and a test can read both off the same call. The three
 * kinds are the three `settleAgainstTripState` can return, and each is one of
 * the five `ledger_entries.kind`'s CHECK allows (`init.sql:126`).
 *
 * The commission's amount is **derived** from the payout,
 * `-(fareGhs - driverPayoutGhs)`, and not read off `commissionGhs`, so the pair
 * sums to the payout by construction. It is the arithmetic `settleFare` already
 * did, restated here only because the row is written by a different function in
 * a different file.
 */
export function ledgerEntriesFor(
  kinds: string[],
  settlement: { fareGhs: number; driverPayoutGhs: number },
): LedgerEntryInput[] | null {
  const entries: LedgerEntryInput[] = [];
  for (const kind of kinds) {
    switch (kind) {
      case 'fare':
        entries.push({ kind, amountGhs: settlement.fareGhs, note: 'Trip fare' });
        break;
      case 'commission':
        entries.push({
          kind,
          amountGhs: -(settlement.fareGhs - settlement.driverPayoutGhs),
          note: 'Platform commission 15%',
        });
        break;
      case 'void':
        // Zero, not a negative: the charge being voided never became a credit,
        // so the driver's record of this trip is nothing rather than a debit.
        entries.push({ kind, amountGhs: 0, note: 'Trip was not completed, charge voided' });
        break;
      default:
        return null;
    }
  }
  return entries;
}

/**
 * The rider's half of the two-way rating, and the only half this task writes.
 * The driver's rating of the rider is Task 14's, in the driver's own app;
 * `unique (trip_id, from_role)` (`init.sql:141`) is what makes the two of them
 * one row each rather than a race for one row.
 *
 * The write goes through the service-role port because `ratings` carries a
 * SELECT policy and no INSERT policy (`own ratings`, `init.sql:555-556`), so RLS
 * default-denies a client insert and the rider's own credential cannot write
 * this row. `complete-trip` is the path that can: it has already validated the
 * caller and already established that the caller is one of the trip's two
 * parties.
 *
 * Nothing here can fail the settlement, and that is the point: the money is
 * already written by the time this runs, so a refused settlement over a rating
 * would leave a completed trip unsettled because a rider tapped a star twice.
 * The four outcomes are reported in the body instead, and `TripController`
 * turns the `failed` one into an error the rider can read while keeping the
 * settlement it was handed.
 *
 * `ratingStatus` is the status the outcome *would* have been had it been allowed
 * to be this response's own, and it is carried because the alternative is
 * unreportable: `functions_client` throws on anything outside 200..299
 * (`functions_client-2.7.1/lib/src/functions_client.dart:255-269`), so
 * answering a re-rating with a literal 409 would throw in the client, lose the
 * `paymentState: 'succeeded'` that was just written, and leave the rider looking
 * at a failure for a trip that was paid.
 */
async function rateTrip(
  input: { rating?: { stars: number; comment: string } },
  trip: TripRow,
  deps: CompleteDeps,
): Promise<Record<string, unknown>> {
  const rating = input.rating;
  if (rating === undefined) return { ratingState: 'skipped' as RatingState };

  // `ratee_id` is `not null` (`init.sql:136`), so a completed trip with no driver
  // has nobody to rate. That is reported as a failure rather than skipped: the
  // rider asked for a rating to be saved and it was not.
  if (!trip.driver_id) {
    return {
      ratingState: 'failed' as RatingState,
      ratingStatus: 500,
      ratingError: 'this trip has no driver to rate',
    };
  }

  const { ok, duplicate } = await deps.writeRating({
    tripId: trip.id,
    raterId: trip.rider_id,
    rateeId: trip.driver_id,
    fromRole: 'rider',
    stars: rating.stars,
    comment: rating.comment,
  });
  if (duplicate) return { ratingState: 'duplicate' as RatingState, ratingStatus: 409 };
  if (!ok) {
    return {
      ratingState: 'failed' as RatingState,
      ratingStatus: 500,
      ratingError: 'the rating was not saved',
    };
  }
  return { ratingState: 'recorded' as RatingState };
}
