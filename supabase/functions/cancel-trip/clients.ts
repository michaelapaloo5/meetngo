// The two clients, and what each one is allowed to do.
//
// Every port in `CancelDeps` runs on the service key, and none of them runs on
// the caller's own credential. That is not a simplification, it is forced by the
// migration: `trips` carries no INSERT policy, `ledger_entries` carries no
// INSERT policy at all, and `revoke update on trips from anon, authenticated`
// with a grant of `(state, eta_minutes, started_at, completed_at)`
// (`init.sql:614-615`) leaves `cancelled_at` unwritable by a rider. So the
// authorisation that the service key bypasses is replaced here, in the handler:
// the caller must present a token that `authenticate` validates, and the trip's
// `rider_id` is compared against that identity and never read from the body.
//
// supabase-js only sets `Authorization` when the request has none
// (`@supabase/supabase-js@2.45.4/dist/module/lib/fetch.js`, `if
// (!headers.has('Authorization'))`), so a service key paired with a forwarded
// bearer leaves the bearer as the effective credential rather than the key. This
// file therefore builds one client and forwards nothing onto it: the token is
// the explicit argument to `getUser`, which is the same construction
// `request-ride/index.ts` and `offers/clients.ts` use.
import { createClient, type SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';
import type { CancelDeps, TripRow } from './handler.ts';

const first = <T>(rows: T[] | null): T | null =>
  (Array.isArray(rows) ? rows[0] ?? null : null);

export function buildClients(): SupabaseClient {
  return createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );
}

const ok = (error: { message: string } | null) => error?.message ?? null;

// Every port the handler gets, so the handler holds no client and no supabase-js
// import of its own. That split is what lets the handler be tested against fakes
// with no network and no environment.
export function buildDeps(service: SupabaseClient): CancelDeps {
  return {
    authenticate: async (token) => {
      const { data, error } = await service.auth.getUser(token);
      return { userId: data.user?.id ?? null, error: ok(error) };
    },

    // `limit(1)` and index the result rather than `single()`, for the reason
    // `offers/clients.ts` gives in full: a 0-row read is a 200 with `[]` and the
    // client turns that into `data = null` itself, and `limit(1)` never asks the
    // client to interpret a row count at all.
    readTrip: async (tripId) => {
      const { data, error } = await service
        .from('trips')
        .select('*')
        .eq('id', tripId)
        .limit(1);
      return { row: first(data) as TripRow | null, error: ok(error) };
    },

    // `.eq('state', fromState)` makes this the single-winner write: a second
    // cancel, or the driver's own app advancing the state, matches no row and
    // the handler answers a 409 rather than reporting a cancellation that did not
    // happen. `.select('*')` is what makes the outcome readable -- measured, an
    // update with no `select` answers `data = null` and `error = null` whether it
    // wrote a row or matched none -- and it is also what puts the `cancelled_at`
    // this call writes back into the row the handler echoes as the 200 body.
    //
    // `cancelled_at` is written here and nowhere else in the build. It exists on
    // the table (`init.sql:69`) and the verification harness populates it for a
    // cancelled trip (`supabase/tests/verify_migration.sql:244`), so a
    // cancellation that leaves it null makes the column permanently unpopulated
    // and any later "how long was this open" read wrong.
    writeCancel: async (tripId, fromState, cancelledAt) => {
      const { data, error } = await service
        .from('trips')
        .update({ state: 'cancelled', cancelled_at: cancelledAt })
        .eq('id', tripId)
        .eq('state', fromState)
        .select('*');
      return { row: first(data) as TripRow | null, error: ok(error) };
    },

    releaseDriver: async (driverId) => {
      const { error } = await service
        .from('profiles')
        .update({ availability: 'online' })
        .eq('id', driverId);
      return { error: ok(error) };
    },

    releaseOffers: async (tripId) => {
      const { error } = await service
        .from('offers')
        .update({ state: 'released' })
        .eq('trip_id', tripId)
        .eq('state', 'pending');
      return { error: ok(error) };
    },

    recordCompensation: async ({ driverId, tripId, amountGhs }) => {
      const { error } = await service.from('ledger_entries').insert({
        driver_id: driverId,
        trip_id: tripId,
        amount_ghs: amountGhs,
        kind: 'compensation',
        note: 'Rider cancelled after the free window',
        is_demo: true,
      });
      return { error: ok(error) };
    },
  };
}
