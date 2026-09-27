import { corsHeaders } from '../_shared/cors.ts';
// `isTripStateName` and `readFareGhs` are read from the modules that own them
// rather than restated: the six trip states are `cancel-trip/policy.ts`'s to
// define, and the fare a demo charge writes has to be the fare the
// `complete-trip` settlement charges, so both functions read it through one
// function. A relative import out of the function's own directory is not a new
// deployment shape: every function here already reaches `../_shared/cors.ts`.
import { isTripStateName } from '../cancel-trip/policy.ts';
import { readFareGhs } from '../complete-trip/ledger.ts';
import type { PaymentRow, TripRow } from '../complete-trip/handler.ts';

// The HTTP surface of `demo-pay`, and nothing that talks to a client. Split out
// of `index.ts` for the reason `complete-trip/handler.ts` gives in full: a
// `serve()` at module scope makes a file unimportable, so a test that imports
// it starts a server, and the three behaviours below -- reusing an open
// payment, refusing a finished trip, refusing an unknown method -- had no test
// at all.

const json = (status: number, payload: Record<string, unknown>) =>
  new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

/**
 * The three values of the `pay_method` enum (`init.sql:9`), restated as a set
 * because the request body carries a string and PostgREST would answer anything
 * outside the enum with a 400 from deep inside the insert. The check is here so
 * the refusal names the field.
 */
const METHODS = new Set(['momo', 'cash', 'card']);

export interface PaymentInput {
  tripId: string;
  payerId: string;
  amountGhs: number;
  method: string;
}

export interface DemoPayDeps {
  // Resolves a bearer token to a user id, the same port `complete-trip` has and
  // for the same reason: `index.ts` authenticates with `getUser(token)` and a
  // port is the only way to do that without the handler importing supabase-js.
  // `error` and `userId` are both checked by the caller, because `getUser`
  // answers a revoked token with a null user *and* an error.
  authenticate(token: string): Promise<{ userId: string | null; error: string | null }>;
  // The same two answers as `complete-trip`'s read ports: a database error and
  // an absent row are different statuses, so the port carries both.
  findTrip(tripId: string): Promise<{ row: TripRow | null; error: string | null }>;
  /**
   * The rider's newest `pending` payment for this trip, or null.
   *
   * Unlike `complete-trip`'s port of the same name this one **is** filtered on
   * `state = 'pending'`, and the filter is the point: `demo-pay` reuses an open
   * charge instead of inserting a second one, and an open charge is by
   * definition a pending one.
   */
  findOpenPayment(
    tripId: string,
    payerId: string,
  ): Promise<{ row: PaymentRow | null; error: string | null }>;
  createPayment(input: PaymentInput): Promise<{ row: PaymentRow | null; error: string | null }>;
}

export async function handleDemoPay(input: {
  deps: DemoPayDeps;
  // Null for a request with no `Bearer ` token and for a token the auth server
  // refused; both are the same 401, and it is answered here so that it is
  // reachable from a test rather than sitting in `index.ts` beside `serve()`.
  callerId: string | null;
  tripId: string;
  method: string;
}): Promise<Response> {
  const { deps, tripId } = input;
  const callerId = input.callerId;
  if (!callerId) return json(401, { error: 'unauthenticated' });

  if (typeof input.method !== 'string' || !METHODS.has(input.method)) {
    return json(400, { error: 'unsupported method' });
  }
  const method = input.method;

  const { row: trip, error: tripError } = await deps.findTrip(tripId);
  if (tripError) return json(500, { error: 'trip lookup failed' });

  // 404 and not 403, and the draft's 404 is kept. A caller who is not the rider
  // learns nothing about whether the trip exists, and a caller who is asking
  // about a trip that is not theirs has no receipt to be shown.
  if (!trip || trip.rider_id !== callerId) {
    return json(404, { error: 'not your trip' });
  }

  if (!isTripStateName(trip.state)) {
    return json(500, { error: 'trip row carries a state this build does not know' });
  }

  // A completed trip is already settled and a cancelled one is already voided,
  // so a charge against either is money moving after the fact. Both carry the
  // `error` key `describeFunctionFailure` reads
  // (`apps/rider/lib/src/data/function_failure.dart:29-38`).
  if (trip.state === 'completed' || trip.state === 'cancelled') {
    return json(409, { error: 'trip is not payable' });
  }

  const fareGhs = readFareGhs(trip);
  if (fareGhs === null) {
    return json(500, { error: 'trip row carries no finite fare' });
  }

  const { row: open, error: openError } = await deps.findOpenPayment(trip.id, callerId);
  if (openError) return json(500, { error: 'payment lookup failed' });

  // The reuse. `complete-trip` reads the **newest** payment for the trip, so a
  // second row would orphan the first one forever: nothing ever reads it, nothing
  // ever voids it, and it sits in `payments` as a pending charge against a trip
  // that was paid. A double tap on a pay button is not a rare event, it is the
  // reason this branch exists.
  if (open) {
    return json(200, { payment: open, state: open.state });
  }

  // Demo only. A real provider drops in behind this branch later; the row shape
  // and the `is_demo` flag stay identical.
  const { row: created, error: createError } = await deps.createPayment({
    tripId: trip.id,
    payerId: callerId,
    amountGhs: fareGhs,
    method,
  });
  if (createError) return json(500, { error: createError });
  if (!created) return json(500, { error: 'payment was not written' });

  return json(200, { payment: created, state: created.state });
}
