import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';
import { corsHeaders } from '../_shared/cors.ts';
import { cancellationCompensationGhs, isTripStateName } from './policy.ts';

const json = (status: number, payload: Record<string, unknown>) =>
  new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  // One service-role client, and nothing on it that belongs to the caller. The
  // trip read, the state write, the driver's availability, the offer release and
  // the compensation all run on this client, because none of them has a
  // client-side RLS path: `trips` carries no INSERT policy and `ledger_entries`
  // carries no INSERT policy at all, and `revoke update on trips from anon,
  // authenticated` with a grant of `(state, eta_minutes, started_at,
  // completed_at)` leaves `cancelled_at` unwritable by a rider
  // (`init.sql:614-615`). So the authorisation this function removes is replaced
  // here instead: the rider is whatever `getUser` says the token is, and the
  // trip's `rider_id` is compared against that, never read from the body.
  const service = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  const header = req.headers.get('Authorization') ?? '';
  const token = header.replace(/^Bearer\s+/i, '');
  if (!token) return json(401, { error: 'unauthenticated' });

  const { data: userData, error: userError } = await service.auth.getUser(token);
  if (userError || !userData.user) return json(401, { error: 'unauthenticated' });
  const riderId = userData.user.id;

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json(400, { error: 'body must be JSON' });
  }
  const tripId = (body as { tripId?: unknown } | null)?.tripId;
  if (typeof tripId !== 'string' || tripId.length === 0) {
    return json(400, { error: 'tripId is required' });
  }

  const { data: trip, error } = await service
    .from('trips')
    .select('*')
    .eq('id', tripId)
    .limit(1);
  const row = Array.isArray(trip) ? trip[0] ?? null : null;
  if (error) return json(500, { error: error.message });
  if (!row) return json(404, { error: 'trip not found' });
  if (row.rider_id !== riderId) return json(403, { error: 'not your trip' });

  // Checked rather than cast, and this is the check `state as never` did not
  // make: the policy function branches on this value, and an unrecognised one
  // used to reach the compensation branch with nothing having verified it.
  if (!isTripStateName(row.state)) {
    return json(500, { error: 'trip row carries a state this build does not know' });
  }

  // The free window runs from the moment the driver committed, not from the
  // moment the trip was created, so `matched_at` is the reference once it
  // exists and `created_at` is only the fallback for a `requested` trip — which
  // is always free anyway, so the fallback never reaches the fee.
  //
  // The `Number.isFinite` guard is what keeps an unparseable reference out of
  // the fee branch, and the comparison is why it is needed: `new Date('junk')
  // .getTime()` is NaN, `Date.now() - NaN` is NaN, and `NaN <= FREE_CANCEL_
  // WINDOW_MS` is **false**, so a bad timestamp does not read as "free" — it
  // reads as "past the window" and pays the driver. Measured on Deno 2.9.7.
  // `new Date(null).getTime()` is 0 rather than NaN, so a null would look like a
  // trip open since 1970 and reach the same branch; `created_at` is `not null`
  // (`init.sql:65`), so that is defence in depth rather than a reachable case.
  const reference = new Date(row.matched_at ?? row.created_at).getTime();
  const elapsedMs = Number.isFinite(reference) ? Date.now() - reference : 0;
  const compensatedGhs = cancellationCompensationGhs({
    state: row.state,
    elapsedMs,
  });

  // One refusal body for both ways a cancel can be too late, and it carries the
  // `error` key that `describeFunctionFailure` reads
  // (`apps/rider/lib/src/data/function_failure.dart:17-26`). The brief's 409 had
  // no `error`, so a rider who cancelled after the trip went `ongoing` — a
  // reachable path, since the driver's app moves the state under them — read
  // `Something went wrong (409)`.
  const refuse = (reason: number) =>
    json(409, {
      error: 'This trip can no longer be cancelled',
      cancelled: false,
      trip: row,
      compensatedGhs: reason,
    });

  if (compensatedGhs < 0) return refuse(compensatedGhs);

  // `.eq('state', row.state)` makes this the single-winner write, and
  // `.select('id,state')` is what makes its outcome readable: measured, a
  // postgrest update with no `select` answers `data = null` and `error = null`
  // whether it wrote a row or matched none, which is the silent no-op
  // `offers/clients.ts` measures and works around in `writeDecline`. Without
  // the row count the brief answered `cancelled: true` for a write that failed
  // and for a race it lost to a second cancel or to the driver's own advance,
  // and `SupabaseTripRepository.cancelTrip` reads no field of the body, so the
  // rider's controller believed it either way.
  const { data: updated, error: updateError } = await service
    .from('trips')
    // `cancelled_at` is written here and nowhere else in the build. It exists
    // on the table (`init.sql:69`) and the verification harness populates it
    // for a cancelled trip (`supabase/tests/verify_migration.sql:244`), so a
    // cancellation that leaves it null makes the column permanently
    // unpopulated and any later "how long was this open" read wrong.
    .update({ state: 'cancelled', cancelled_at: new Date().toISOString() })
    .eq('id', row.id)
    .eq('state', row.state)
    .select('id,state');

  if (updateError) return json(500, { error: updateError.message });
  if (!Array.isArray(updated) || updated.length !== 1) {
    return refuse(-1);
  }

  if (row.driver_id) {
    // Every write below is checked. The trip is already cancelled at this point,
    // so a dropped error here cannot be undone by reporting failure: it leaves a
    // driver stuck on `onTrip` and unable to accept an offer, or a driver owed
    // GHS 5.00 with no row in `ledger_entries` to answer with. A 500 that names
    // the step is the honest report. The rider's `cancelTrip` turns it into a
    // `TripRequestFailure` carrying this string, which is why the message is
    // written for them rather than for a log.
    const { error: driverError } = await service
      .from('profiles')
      .update({ availability: 'online' })
      .eq('id', row.driver_id);
    if (driverError) {
      return json(500, { error: `the trip was cancelled but the driver was not released: ${driverError.message}` });
    }

    const { error: offerError } = await service
      .from('offers')
      .update({ state: 'released' })
      .eq('trip_id', row.id)
      .eq('state', 'pending');
    if (offerError) {
      return json(500, { error: `the trip was cancelled but its pending offers were not released: ${offerError.message}` });
    }

    if (compensatedGhs > 0) {
      const { error: ledgerError } = await service.from('ledger_entries').insert({
        driver_id: row.driver_id,
        trip_id: row.id,
        amount_ghs: compensatedGhs,
        kind: 'compensation',
        note: 'Rider cancelled after the free window',
        is_demo: true,
      });
      if (ledgerError) {
        return json(500, { error: `the trip was cancelled but the driver's compensation was not recorded: ${ledgerError.message}` });
      }
    }
  }

  return json(200, {
    cancelled: true,
    // `driver_id` is left as the row holds it. Releasing the driver and
    // releasing the offers do not unassign them: `trips_driver_idx` is the
    // driver's trip history and `ledger_entries.trip_id` points back here, and
    // nulling the column would take the row out of the driver's reach under
    // `driver reads assigned trips` (`init.sql:520-521`). The rider's own view
    // is the controller's, which clears it locally.
    trip: { ...row, state: 'cancelled' },
    compensatedGhs,
  });
});
