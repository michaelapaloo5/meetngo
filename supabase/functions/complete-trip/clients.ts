// The one client, and what it is allowed to do.
//
// Every port in `CompleteDeps` runs on the service key, and none of them runs
// on the caller's own credential. That is not a simplification, it is forced by
// the migration: `ledger_entries` and `payouts` carry no INSERT policy at all
// (`init.sql:551-554` are their only policies, both SELECT), and `ratings`
// likewise carries SELECT only (`own ratings`, `init.sql:555-556`), so RLS
// default-denies every one of this function's three writes to a rider or a
// driver holding their own token. The authorisation the service key bypasses
// is replaced in `handler.ts`: the caller must present a token that
// `authenticate` validates, and the trip's `rider_id`/`driver_id` are compared
// against that identity and never read from the body.
//
// supabase-js only sets `Authorization` when the request has none
// (`@supabase/supabase-js@2.45.4/dist/module/lib/fetch.js`, `if
// (!headers.has('Authorization'))`), so a service key paired with a forwarded
// bearer leaves the bearer as the effective credential rather than the key. This
// file therefore builds one client and forwards nothing onto it: the token is
// the explicit argument to `getUser`, which is the construction
// `request-ride/index.ts`, `offers/clients.ts` and `cancel-trip/clients.ts` all
// use.
import { createClient, type SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';
// `first` and `ok` are shared with `demo-pay` and live apart from both builders
// so a test can reach them without importing supabase-js; `_shared/rows.ts` gives
// the measurement, and `_tests/rows.test.ts` pins them.
import { first, ok } from '../_shared/rows.ts';
import type {
  CompleteDeps,
  LedgerEntryInput,
  PaymentRow,
  RatingInput,
  TripRow,
} from './handler.ts';

/**
 * PostgreSQL's SQLSTATE for `unique_violation`, which is what
 * `unique (trip_id, from_role)` (`init.sql:141`) raises when a rider rates the
 * same trip twice.
 *
 * Matched on the `code` field and not on the message, because the message
 * carries the generated constraint name and a detail line and neither is a
 * contract. `code` is PostgREST's own field and is passed through untouched: the
 * Dart client reads the same key off the same error body
 * (`postgrest-2.9.1/lib/src/types.dart:22-33`), and the fallback for a
 * non-JSON error body is the HTTP status, so it is a string either way.
 *
 * Not measured on this host, which has no Postgres: `23505` is the documented
 * SQLSTATE and what the unit test pins is the *routing* of that code to a
 * duplicate. Task 18's runbook owns the live round trip.
 */
const UNIQUE_VIOLATION = '23505';

const ledgerRow = (driverId: string, tripId: string, entry: LedgerEntryInput) => ({
  driver_id: driverId,
  trip_id: tripId,
  amount_ghs: entry.amountGhs,
  kind: entry.kind,
  note: entry.note,
  // Not a convention. `alter table ledger_entries add constraint
  // ledger_demo_only check (is_demo)` (`init.sql:178`) refuses the row without it.
  is_demo: true,
});

// Every port the handler gets, so the handler holds no client and no
// supabase-js import of its own. That split is what lets the handler be tested
// against fakes with no network and no environment.
export function buildCompleteDeps(
  supabaseUrl: string,
  serviceKey: string,
): CompleteDeps {
  const service: SupabaseClient = createClient(supabaseUrl, serviceKey);
  return {
    authenticate: async (token) => {
      const { data, error } = await service.auth.getUser(token);
      return { userId: data.user?.id ?? null, error: ok(error) };
    },

    // `limit(1)` and index the result rather than `single()`, for the reason
    // `cancel-trip/clients.ts` gives: a missing row makes PostgREST answer 406,
    // which supabase-js throws, so the 404 underneath it was unreachable and a
    // missing trip became a bare 500. `limit(1)` never asks the client to
    // interpret a row count at all.
    findTrip: async (tripId) => {
      const { data, error } = await service
        .from('trips')
        .select('*')
        .eq('id', tripId)
        .limit(1);
      return { row: first(data) as TripRow | null, error: ok(error) };
    },

    // The newest row with **no** state filter, which is what makes this port safe
    // to read on a retry: see `CompleteDeps.findOpenPayment`. The ordering is
    // load-bearing for the same reason it is in the brief's draft -- this is the
    // row the settlement acts on, and "the newest" has to mean newest rather
    // than whatever PostgREST returns first.
    findOpenPayment: async (tripId) => {
      const { data, error } = await service
        .from('payments')
        .select('*')
        .eq('trip_id', tripId)
        .order('created_at', { ascending: false })
        .limit(1);
      return { row: first(data) as PaymentRow | null, error: ok(error) };
    },

    // `.select('*')` is what makes the outcome readable: measured, an update with
    // no `select` answers `data = null` and `error = null` whether it wrote a row
    // or matched none, so a lost race and a write are indistinguishable. The
    // handler answers them differently -- 500 for a database error, 404 for a
    // zero-row match.
    markPaymentSucceeded: async (paymentId) => {
      const { data, error } = await service
        .from('payments')
        .update({ state: 'succeeded' })
        .eq('id', paymentId)
        .select('*');
      return { row: first(data) as PaymentRow | null, error: ok(error) };
    },

    markPaymentVoided: async (paymentId) => {
      const { data, error } = await service
        .from('payments')
        .update({ state: 'voided' })
        .eq('id', paymentId)
        .select('*');
      return { row: first(data) as PaymentRow | null, error: ok(error) };
    },

    // One insert for both entries rather than two. Two inserts would let the fare
    // land without the commission, which is the half-written ledger the money
    // identity exists to prevent, and Postgres takes the pair as one statement.
    writeLedger: async (tripId, driverId, entries) => {
      const { error } = await service
        .from('ledger_entries')
        .insert(entries.map((entry) => ledgerRow(driverId, tripId, entry)));
      return { ok: !error, error: ok(error) };
    },

    writePayout: async (tripId, driverId, amountGhs) => {
      const { error } = await service
        .from('payouts')
        .insert({
          driver_id: driverId,
          trip_id: tripId,
          amount_ghs: amountGhs,
          // `alter table payouts add constraint payouts_demo_only check (is_demo)`
          // (`init.sql:177`) refuses the row without it.
          is_demo: true,
        });
      return { ok: !error, error: ok(error) };
    },

    // A read, on the service key, of a table the driver can also read for
    // themselves. `ends_at` alone is selected: the window's start is the
    // trigger's business and nothing here has an opinion about it.
    //
    // Zero rows is the ordinary answer for a driver who has never completed a
    // trip, and it is deliberately NOT folded into an error. `first()` returns
    // null and the handler reads that as "no promo", which for a driver with no
    // completed trip is the truth.
    findPromoWindow: async (driverId) => {
      const { data, error } = await service
        .from('driver_promos')
        .select('ends_at')
        .eq('driver_id', driverId)
        .limit(1);
      if (error) return { window: null, error: ok(error) };
      const row = first(data) as { ends_at?: unknown } | null;
      // A row whose `ends_at` is missing is not treated as "no promo": that
      // would quietly start charging a driver who is inside their promo, and
      // `commissionRateFor` exists precisely to make a bad date loud.
      if (row && typeof row.ends_at !== 'string') {
        return { window: null, error: 'driver_promos row carries no ends_at' };
      }
      return { window: row ? { endsAt: row.ends_at as string } : null, error: null };
    },

    // `commission_rate` is written once, and only on a trip that actually
    // charged. Deliberately NOT an upsert: a retry that reached the payment
    // first is answered by `settleAgainstTripState`'s already-succeeded guard
    // and never comes here, so a second write would mean two settlements
    // happened and the first one did not record its rate. Overwriting would
    // hide that.
    recordCommissionRate: async (tripId, rate) => {
      const { data, error } = await service
        .from('trips')
        .update({ commission_rate: rate })
        .eq('id', tripId)
        .select('*');
      if (error) return { ok: false, error: ok(error) };
      // Measured the same way `markPaymentSucceeded` is: an update with no
      // `select` answers `data = null, error = null` whether it wrote a row or
      // matched none, and the handler has to tell those apart.
      const wrote = first(data) !== null;
      return { ok: wrote, error: wrote ? null : 'trip not found' };
    },

    // A service-role insert because there is no INSERT policy on `ratings`.
    // `rater_id` and `ratee_id` are passed in rather than read here, and
    // `from_role` is written as the handler supplied it -- which is the handler's
    // own `fromRole: 'rider'`, not a field of the request body, so this function
    // cannot be talked into writing the driver's half of the two-way rating.
    writeRating: async (input: RatingInput) => {
      const { error } = await service.from('ratings').insert({
        trip_id: input.tripId,
        rater_id: input.raterId,
        ratee_id: input.rateeId,
        from_role: input.fromRole,
        stars: input.stars,
        comment: input.comment,
      });
      return { ok: !error, duplicate: error?.code === UNIQUE_VIOLATION };
    },
  };
}
