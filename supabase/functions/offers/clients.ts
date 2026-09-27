// The two clients, and what each one is allowed to do.
//
// Task 6's single service-role client is not the pattern here. This function
// has one user-scoped operation, and the two operations here cannot share a
// client:
//
//   accept  the caller's own bearer token, and nothing else, makes
//           `accept_offer` accept. Its ownership test is the plain expression
//           `v_offer.driver_id is distinct from auth.uid()` (migration:324),
//           evaluated inside a `security definer` function, so it runs for every
//           caller and `bypassrls` is no exemption. `offers.driver_id` is
//           `not null` (migration:80), so a caller with no `sub` claim, whose
//           `auth.uid()` is NULL, fails it. Measured: as `anon` and as
//           `service_role` with no `sub` claim, `accept_offer` answers
//           `false / NULL / NULL` and writes nothing
//           (supabase/tests/verify_offer_authz.sql probes 1 and 2). So the
//           accept must go out on the driver's own token.
//
//   decline `offers` carries two SELECT policies and no UPDATE policy
//           (migration:530 and :532 are the only two), so as `authenticated`
//           the decline UPDATE matches zero rows. Measured: the same driver
//           SELECTs 1 row and UPDATEs 0 as `authenticated`, and the identical
//           UPDATE matches 1 row as `service_role`
//           (supabase/tests/verify_offer_authz.sql probes 6 and 7). So the
//           decline has to go out on the service key.
//
// supabase-js only sets `Authorization` when the request has none
// (`@supabase/supabase-js@2.45.4/dist/module/lib/fetch.js`, `if
// (!headers.has('Authorization'))`), so a service key paired with a forwarded
// bearer leaves the bearer as the effective credential rather than the key.
// Measured by driving the shipped client with a stub fetch: a service key plus
// `Authorization: Bearer DRIVER-JWT` puts `Bearer DRIVER-JWT` on the wire, with
// the service key only in `apikey`. That construction is what this file must
// not ship, and it is the one Task 6's brief shipped and had to be unpicked
// from. It is not a harmless redundancy either way: it would make the decline
// match zero rows, and it would also make the accept go out as the driver while
// looking like a service call.
import { createClient, type SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';
import type { OfferDeps } from './handler.ts';

export interface OfferClients {
  user: SupabaseClient;
  service: SupabaseClient;
}

// The caller's own credential on the user client, and the service key on the
// service client with nothing forwarded onto it. `authenticate` is the one call
// that runs on the service client, and it passes the token explicitly rather
// than relying on a forwarded header, which is why that client needs none.
export function buildClients(req: Request): OfferClients {
  const url = Deno.env.get('SUPABASE_URL')!;
  const authHeader = req.headers.get('Authorization');

  // Built without the header when the caller sent none, rather than with an
  // empty string: an empty value is still a present header as far as
  // supabase-js's `headers.has` is concerned, so it would suppress the anon key
  // that PostgREST needs to resolve the role at all. The handler refuses a
  // request with no bearer before any query runs, so this path never issues a
  // request; it exists so the construction is not quietly wrong if that moves.
  const user = authHeader
    ? createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authHeader } },
    })
    : createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!);

  const service = createClient(
    url,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  return { user, service };
}

const first = <T>(rows: T[] | null): T | null => (Array.isArray(rows) ? rows[0] ?? null : null);

// Every port the handler gets, so the handler holds no client and no
// supabase-js import of its own. That split is what lets the handler be tested
// against fakes with no network and no environment, and it is why this is the
// only file that has to be believed rather than executed.
export function buildDeps(clients: OfferClients): OfferDeps {
  const { user, service } = clients;
  return {
    // `getUser(token)` rather than `getUser()`. Passing the token makes the
    // explicit argument the credential, and it is the same on every client.
    // Measured with a stub fetch: on a client with no forwarded header,
    // `getUser('DRIVER-JWT')` puts `Authorization: Bearer DRIVER-JWT` on the
    // wire. Task 6 does the same at request-ride/index.ts:64, and `cancel-trip`
    // at `cancel-trip/clients.ts` follows both.
    //
    // Why not the argumentless form. It is not that it always fails, because it
    // does not: on an anon client carrying `Authorization: Bearer RIDER-JWT`,
    // `auth.getUser()` resolves the user and puts that bearer on the wire, which
    // is the header `buildClients` forwards whenever the caller sent one. It
    // fails only on a client with *no* header, and then it answers
    // `Auth session missing!` having issued **zero** requests, so nothing was
    // validated either. So the argumentless form is header-dependent rather than
    // broken, and it has a worse failure than that: a client built by forwarding
    // `req.headers.get('Authorization')` directly, with nothing guarding the
    // null, sends the literal string `null` as the `Authorization` value and the
    // auth server has to reject it before this function can answer 401.
    // Measured on the same stub. `buildClients` above is the guarded form; the
    // explicit argument is identical whatever the client is, which is the reason
    // to prefer it over relying on the header being there.
    authenticate: async (token) => {
      const { data, error } = await service.auth.getUser(token);
      return { userId: data.user?.id ?? null, error: error?.message ?? null };
    },

    // The ownership read, on the caller's own bearer. `driver reads own offers`
    // (migration:530) is what makes the row trustworthy as the caller's, and it
    // is *not* sufficient on its own: `rider reads offers on own trip`
    // (migration:532) also lets the trip's rider read every offer on it, which
    // is measured in probe 5. A row coming back from this read therefore proves
    // the caller may see the offer, not that the offer is theirs, and the
    // handler compares `driver_id` itself.
    //
    // `limit(1)` and index the result rather than `maybeSingle()`. The two are
    // behaviourally equivalent for a zero-row read on this version, and it is
    // worth being precise about why, because the reason usually given for this
    // line is wrong. Measured with the shipped client: `maybeSingle()` on a GET
    // sends `Accept: application/json`, not
    // `application/vnd.pgrst.object+json`
    // (`@supabase/postgrest-js@1.16.1/src/PostgrestTransformBuilder.ts:209-210`),
    // so a zero-row read is a 200 with `[]` and the client turns that into
    // `data = null` with no error itself
    // (`@supabase/postgrest-js@1.16.1/src/PostgrestBuilder.ts:118-134`). The
    // `error.details.includes('0 rows')` comparison at `:162` is a *different*
    // branch, reached only when the server answers with an error, and a GET that
    // asked for `application/json` is not answered with one.
    //
    // So the reason to write `limit(1)` is not that `maybeSingle()` is broken
    // here. It is that `limit(1)` never asks the client to interpret a row count
    // at all: the answer is `data` and we index it, so the shape of a zero-row
    // read cannot change under us if that client-side coercion is ever revised.
    // Every read in this function is then the same shape, which is worth more
    // than the one line it saves.
    readOffer: async (offerId) => {
      const { data, error } = await user
        .from('offers')
        .select('driver_id,state,trip_id,expires_at')
        .eq('id', offerId)
        .limit(1);
      return { row: first(data), error: error?.message ?? null };
    },

    // On the user client, so `auth.uid()` is the driver. `accept_offer` is
    // declared `returns table` (migration:292), so PostgREST answers with an
    // array and the handler reads the first row.
    acceptOffer: async (offerId) => {
      const { data, error } = await user.rpc('accept_offer', { p_offer: offerId });
      return { rows: data, error: error?.message ?? null };
    },

    // On the service client, filtered by id, driver_id and state together. All
    // three reach the wire: measured, the request is
    // `/rest/v1/offers?id=eq.<id>&driver_id=eq.<id>&state=eq.pending&select=...`.
    // Probe 8 measures each of the three refusing on its own, so an offer id
    // that does not exist, an offer belonging to another driver and an offer
    // that is not pending all match zero rows.
    //
    // `.select()` is what makes the outcome readable. Measured: with
    // `.select('id,state')` the updated rows come back in `data`, so a 0-row
    // match is `[]`; without `.select()` the same write returns
    // `data = null` and `count = null` with `error = null` whatever happened,
    // which is a silent no-op the handler would have to report as a decline.
    writeDecline: async (offerId, driverId) => {
      const { data, error } = await service
        .from('offers')
        .update({ state: 'declined' })
        .eq('id', offerId)
        .eq('driver_id', driverId)
        .eq('state', 'pending')
        .select('id,state');
      return { updated: Array.isArray(data) ? data.length : 0, error: error?.message ?? null };
    },
  };
}
