// The rules for a driver withdrawing from a trip, against ports rather than a
// client.
//
// Split out of `index.ts` for the reason every other function in this project is
// split: the rules are the thing that has to be read carefully, and they are worth
// reading without a Supabase client in the way.

import type { LeaveDeps, LeaveTripRow } from './clients.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const json = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

/// The only state a withdrawal is allowed from.
///
/// `arriving` is driving towards a pickup. `ongoing` is the rider in the car.
/// `requested` and `matched` are before the trip is this driver's, where
/// `offers/decline` applies instead.
export const WITHDRAWABLE_STATE = 'arriving';

/// The trip states this build knows about, checked rather than cast.
///
/// A state this file has never heard of must not fall through to "allowed", and
/// it must not fall through to a cast that makes `row.state as never` compare
/// equal to something. `cancel-trip/policy.ts` learned that the hard way.
const TRIP_STATES = [
  'requested',
  'matched',
  'arriving',
  'ongoing',
  'completed',
  'cancelled',
] as const;

export function isTripStateName(value: unknown): value is (typeof TRIP_STATES)[number] {
  return typeof value === 'string' && (TRIP_STATES as readonly string[]).includes(value);
}

/// Why [state] cannot be withdrawn from, in the driver's own words.
///
/// Null means it can. Returning the sentence rather than a boolean is what lets
/// the app show the driver something actionable instead of a disabled button with
/// no explanation -- and the `ongoing` case is the one where the driver most needs
/// to be told why.
export function refusalFor(state: string): string | null {
  if (state === WITHDRAWABLE_STATE) return null;
  if (state === 'ongoing') {
    return 'The rider is in the car. Finish the trip, or call them if something is wrong.';
  }
  if (state === 'requested' || state === 'matched') {
    return 'You do not have this trip yet. Decline the offer instead.';
  }
  if (state === 'completed') return 'This trip has already finished.';
  if (state === 'cancelled') return 'This trip was already cancelled.';
  return 'This trip cannot be left right now.';
}

async function readBody(req: Request): Promise<{
  ok: boolean;
  error?: string;
  tripId?: string;
  reason: string;
}> {
  let raw: unknown;
  try {
    raw = await req.json();
  } catch {
    return { ok: false, error: 'body must be json', reason: '' };
  }
  if (typeof raw !== 'object' || raw === null) {
    return { ok: false, error: 'body must be an object', reason: '' };
  }
  const body = raw as Record<string, unknown>;

  // A uuid, checked rather than trusted. This goes into a URL and into an `.eq()`,
  // and Postgres answers a malformed uuid with a 22P02 that says less about what
  // went wrong than this does.
  const tripId = body.tripId;
  if (typeof tripId !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(tripId)) {
    return { ok: false, error: 'tripId must be a uuid', reason: '' };
  }

  // Optional, and truncated rather than refused. A driver writing more than 300
  // characters about a pickup is telling staff something useful, and refusing it
  // because of the character count is pedantry on a field whose only purpose is
  // to help whoever reads these later.
  const rawReason = typeof body.reason === 'string' ? body.reason.trim() : '';
  return { ok: true, tripId, reason: rawReason.slice(0, 300) };
}

export async function handleLeave(req: Request, deps: LeaveDeps): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json(405, { error: 'method not allowed' });

  // The driver is whatever `getUser` says the token is, and the trip's
  // `driver_id` is compared against that. No field of the body can decide who the
  // trip belongs to -- the same rule `cancel-trip` applies on the rider's side.
  const header = req.headers.get('Authorization') ?? '';
  const token = header.replace(/^Bearer\s+/i, '');
  if (!token) return json(401, { error: 'unauthenticated' });

  const { userId, error: authError } = await deps.authenticate(token);
  if (authError || !userId) return json(401, { error: 'unauthenticated' });

  const parsed = await readBody(req);
  if (!parsed.ok) return json(400, { error: parsed.error });
  const tripId = parsed.tripId!;

  const { row, error: readError } = await deps.readTrip(tripId);
  if (readError) return json(500, { error: readError });
  if (!row) return json(404, { error: 'trip not found' });

  // Not the rider's trip either. This function exists for the driver; a rider who
  // wants out cancels, with different rules and different money attached.
  if (row.driver_id !== userId) {
    // ...unless this driver is the one who just released it.
    //
    // A successful withdrawal clears `driver_id`, so a second press from the same
    // button finds a trip that is no longer theirs. Answering 403 would put "not
    // your trip" on a screen the driver is looking at precisely because it *was*
    // their trip -- and the app shows this sentence verbatim. The end state they
    // asked for is already the state the row is in, so this is a success with
    // `alreadyLeft` set, and the app can close the sheet without an apology.
    //
    // Both conditions are required together. The withdrawal is recorded before the
    // state moves, so a row here with the trip still assigned means a previous
    // attempt half-finished; that driver is still driving towards the pickup and
    // must be told so, not handed a success for a trip they are still on.
    const prior = await deps.hasWithdrawn(tripId, userId);
    if (!prior.error && prior.row) {
      return json(200, {
        ok: true,
        tripId,
        alreadyLeft: true,
        availability: 'online',
      });
    }
    return json(403, { error: 'not your trip' });
  }

  if (!isTripStateName(row.state)) {
    return json(500, { error: 'trip row carries a state this build does not know' });
  }
  const refusal = refusalFor(row.state);
  if (refusal !== null) {
    // 409, not 403: the request was well-formed and the caller is who they claim,
    // but the trip is not in a state that can be left. That is a conflict with the
    // current state, and the body carries the sentence for the app to show.
    return json(409, { error: refusal });
  }

  // The withdrawal is recorded *before* the state changes, and this ordering is
  // deliberate.
  //
  // If the state change fails, the driver is still on a trip they have said they
  // are leaving, and the matcher will refuse them any new trip -- but they are on
  // this one, so the app can offer them a second try. If the order were reversed and
  // the recording failed, the trip would be back in the pool with a driver who has
  // no memory of declining it, and the next match would offer it to them again
  // with nothing in the way.
  const withdrawal = await deps.recordWithdrawal(tripId, userId, parsed.reason);
  if (withdrawal.error) {
    return json(500, { error: 'could not record the withdrawal' });
  }

  const released = await deps.returnToRequested(tripId, row.state);
  if (released.error) {
    return json(500, { error: released.error });
  }
  // The conditional update matched no row. Something changed this trip between the
  // read and here -- the rider cancelled, or a second request from this same
  // button won the race. Reported as a conflict, not as a success, because
  // reporting success here would tell a driver they are free while the row says
  // otherwise.
  if (!released.row) {
    return json(409, { error: 'this trip changed while you were leaving it' });
  }

  // Both of these are after the state change and neither can undo it.
  //
  // A driver left on the trip who is not marked `online` is a driver who is
  // waiting for offers while believing they have left, which is the worst of both
  // worlds and is why a failure here is logged rather than returned as an error:
  // the withdrawal itself succeeded, and telling the driver it failed would make
  // them press the button again against a trip they have already left.
  const driver = await deps.releaseDriver(userId);
  const offers = await deps.releaseOffers(tripId);
  for (const [what, result] of [
    ['releaseDriver', driver],
    ['releaseOffers', offers],
  ] as const) {
    if (result.error) {
      console.error(`leave-trip: ${what} failed for trip ${tripId}: ${result.error}`);
    }
  }

  return json(200, {
    ok: true,
    tripId,
    // Echoed so the app can put the driver back on the offer queue without
    // re-reading their own profile, which is one round trip for something it
    // already knows.
    availability: 'online',
  });
}

// Re-exported so a test can reach the port shape from this module rather than
// importing `clients.ts`, which would drag `jsr:@supabase/supabase-js` into a
// unit test that should open no socket. `cancel-trip/handler.ts` does the same
// for `CancelDeps`, and without it `deno test` fails to type-check with
// TS2459: "declares 'LeaveDeps' locally, but it is not exported".
export type { LeaveDeps, LeaveTripRow };