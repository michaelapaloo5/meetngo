import { corsHeaders } from '../_shared/cors.ts';
import { cancellationCompensationGhs, isTripStateName } from './policy.ts';

// The HTTP surface of `cancel-trip`, and nothing that talks to a client.
//
// This file used to be `index.ts` in full, with `serve()` at module scope. That
// makes it unimportable: a test that imports it starts a server, and the six
// behaviours below -- the row-count refusal, the checked `trips` write, the
// `error` key on the 409, the three checked writes behind it, the `cancelled_at`
// it writes and the state guard -- had no test at all, because there was no way
// to reach them. They are all reachable now, through `CancelDeps`, and each has
// a case in `_tests/cancel_handler.test.ts`.
//
// The split is `offers/handler.ts`'s: the routing, the status codes and the
// response bodies live here, `clients.ts` builds the ports out of two
// supabase-js clients, and `index.ts` is the three lines that wire one to the
// other. Nothing here imports supabase-js.

const json = (status: number, payload: Record<string, unknown>) =>
  new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

/**
 * The `trips` row as it comes off the wire, snake_case because that is what
 * comes off the wire. `state` is a plain `string` and not the `TripStateName`
 * union on purpose: the whole point of the `isTripStateName` guard below is that
 * this value is unverified, and typing it as the union would let the guard read
 * as redundant. The index signature is the other half of that -- the 200 body
 * echoes the row, so the handler has to be able to carry columns it never reads.
 */
export interface TripRow {
  id: string;
  rider_id: string;
  driver_id: string | null;
  state: string;
  created_at: string;
  matched_at: string | null;
  [column: string]: unknown;
}

export interface CancelDeps {
  // Resolves a bearer token to a user id. `error` and `userId` are both checked:
  // `getUser` answers a revoked or malformed token with a null user *and* an
  // error, and either alone is enough to refuse.
  authenticate(token: string): Promise<{ userId: string | null; error: string | null }>;
  readTrip(tripId: string): Promise<{ row: TripRow | null; error: string | null }>;
  // The single-winner write. `row` is the row *as the database now holds it*, so
  // the 200 body can echo `cancelled_at` rather than the pre-update null. A null
  // `row` with a null `error` is a zero-row match, which is a lost race and not
  // a failure, and the two are answered differently.
  writeCancel(
    tripId: string,
    fromState: string,
    cancelledAt: string,
  ): Promise<{ row: TripRow | null; error: string | null }>;
  releaseDriver(driverId: string): Promise<{ error: string | null }>;
  releaseOffers(tripId: string): Promise<{ error: string | null }>;
  recordCompensation(input: {
    driverId: string;
    tripId: string;
    amountGhs: number;
  }): Promise<{ error: string | null }>;
}

// Milliseconds since the driver committed, or 0 when the reference cannot be
// read. The guard is load-bearing and the comparison is why: `new Date('junk')
// .getTime()` is NaN, `Date.now() - NaN` is NaN, and `NaN <= FREE_CANCEL_WINDOW_MS`
// is **false**, so an unparseable timestamp does not read as "free" -- it reads
// as "past the window" and pays the driver. Measured on Deno 2.9.7.
// `new Date(null).getTime()` is 0 rather than NaN, so a null would look like a
// trip open since 1970 and reach the same branch; `created_at` is `not null`
// (`init.sql:65`), so that is defence in depth rather than a reachable case.
export function elapsedSinceCommit(matchedAt: string | null, createdAt: string): number {
  const reference = new Date(matchedAt ?? createdAt).getTime();
  return Number.isFinite(reference) ? Date.now() - reference : 0;
}

// Two ways the body can be unusable, kept apart because they are two different
// messages: a body that does not parse is a malformed request, and a body that
// parses without a `tripId` is a request for something that does not exist.
const readTripId = async (req: Request): Promise<
  { ok: true; tripId: string } | { ok: false; error: string }
> => {
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return { ok: false, error: 'body must be JSON' };
  }
  const tripId = (body as { tripId?: unknown } | null)?.tripId;
  if (typeof tripId !== 'string' || tripId.length === 0) {
    return { ok: false, error: 'tripId is required' };
  }
  return { ok: true, tripId };
};

export async function handleCancel(req: Request, deps: CancelDeps): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  // The rider is whatever `getUser` says the token is, and the trip's `rider_id`
  // is compared against that. No field of the body can decide who the trip
  // belongs to. See `clients.ts` for why every one of these ports is on the
  // service key rather than the caller's own credential.
  const header = req.headers.get('Authorization') ?? '';
  const token = header.replace(/^Bearer\s+/i, '');
  if (!token) return json(401, { error: 'unauthenticated' });

  const { userId, error: authError } = await deps.authenticate(token);
  if (authError || !userId) return json(401, { error: 'unauthenticated' });

  const parsed = await readTripId(req);
  if (!parsed.ok) return json(400, { error: parsed.error });

  const { row, error: readError } = await deps.readTrip(parsed.tripId);
  if (readError) return json(500, { error: readError });
  if (!row) return json(404, { error: 'trip not found' });
  if (row.rider_id !== userId) return json(403, { error: 'not your trip' });

  // Checked rather than cast, and this is the check `state as never` did not
  // make: the policy function branches on this value, and an unrecognised one
  // used to reach the compensation branch with nothing having verified it.
  if (!isTripStateName(row.state)) {
    return json(500, { error: 'trip row carries a state this build does not know' });
  }

  // The free window runs from the moment the driver committed, not from the
  // moment the trip was created, so `matched_at` is the reference once it
  // exists and `created_at` is only the fallback for a `requested` trip -- which
  // is always free anyway, so the fallback never reaches the fee.
  const compensatedGhs = cancellationCompensationGhs({
    state: row.state,
    elapsedMs: elapsedSinceCommit(row.matched_at, row.created_at),
  });

  // One refusal body for both ways a cancel can be too late, and it carries the
  // `error` key that `describeFunctionFailure` reads
  // (`apps/rider/lib/src/data/function_failure.dart:17-26`). The brief's 409 had
  // no `error`, so a rider who cancelled after the trip went `ongoing` -- a
  // reachable path, since the driver's app moves the state under them -- read
  // `Something went wrong (409)`.
  const refuse = (reason: number) =>
    json(409, {
      error: 'This trip can no longer be cancelled',
      cancelled: false,
      trip: row,
      compensatedGhs: reason,
    });

  if (compensatedGhs < 0) return refuse(compensatedGhs);

  const cancelledAt = new Date().toISOString();
  const { row: written, error: cancelError } = await deps.writeCancel(
    row.id,
    row.state,
    cancelledAt,
  );
  if (cancelError) return json(500, { error: cancelError });
  if (!written) return refuse(-1);

  // Releasing the offers happens whether or not a driver was ever assigned.
  //
  // It used to sit inside `if (row.driver_id)`, which meant a rider cancelling a
  // trip that no driver had taken yet -- the common case, and the only case where
  // offers are still pending -- left every one of those offers pending forever.
  // They point at a cancelled trip, so a driver browsing offers is shown ride
  // requests for rides that do not exist, and nothing will ever release them
  // because the only code that releases them runs after the trip is already
  // cancelled. Seventeen of exactly these were sitting in the database.
  //
  // Checked, and checked before the driver, because a stale offer is visible to
  // every driver immediately whereas a driver held on a trip is visible to one.
  const { error: offerError } = await deps.releaseOffers(row.id);
  if (offerError) {
    return json(500, { error: `the trip was cancelled but its pending offers were not released: ${offerError}` });
  }

  if (row.driver_id) {
    // Every write below is checked. The trip is already cancelled at this point,
    // so a dropped error here cannot be undone by reporting failure: it leaves a
    // driver stuck on `onTrip` and unable to accept an offer, or a driver owed
    // GHS 5.00 with no row in `ledger_entries` to answer with. A 500 that names
    // the step is the honest report. The rider's `cancelTrip` turns it into a
    // `TripRequestFailure` carrying this string, which is why the message is
    // written for them rather than for a log.
    const { error: driverError } = await deps.releaseDriver(row.driver_id);
    if (driverError) {
      return json(500, { error: `the trip was cancelled but the driver was not released: ${driverError}` });
    }

    if (compensatedGhs > 0) {
      const { error: ledgerError } = await deps.recordCompensation({
        driverId: row.driver_id,
        tripId: row.id,
        amountGhs: compensatedGhs,
      });
      if (ledgerError) {
        return json(500, { error: `the trip was cancelled but the driver's compensation was not recorded: ${ledgerError}` });
      }
    }
  }

  // `written` is the row the database holds now, so the body carries the
  // `cancelled_at` that was just written. The brief answered `{...row, state:
  // 'cancelled'}` from the *pre-update* row, so its `cancelled_at` was null
  // while the row it claimed to describe had one.
  //
  // `driver_id` is left as the row holds it. Releasing the driver and releasing
  // the offers do not unassign them: `trips_driver_idx` is the driver's trip
  // history and `ledger_entries.trip_id` points back here, and nulling the column
  // would take the row out of the driver's reach under `driver reads assigned
  // trips` (`init.sql:520-521`). The rider's own view is the controller's, which
  // clears it locally.
  return json(200, { cancelled: true, trip: written, compensatedGhs });
}
