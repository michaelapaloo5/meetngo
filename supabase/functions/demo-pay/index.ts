// The only file that starts anything, and the one place in this function that
// knows what a `payments` row is. `complete-trip` keeps that in its own
// `clients.ts`; the brief's Files list gives `demo-pay` a handler and an index
// and no clients file, so the port builder sits here rather than in a third
// file. `request-ride/index.ts` builds its client inline for the same reason.
//
// supabase-js only sets `Authorization` when the request has none
// (`@supabase/supabase-js@2.45.4/dist/module/lib/fetch.js`, `if
// (!headers.has('Authorization'))`), so a service key paired with a forwarded
// bearer leaves the bearer as the effective credential rather than the key. One
// client is built and nothing is forwarded onto it: the token is the explicit
// argument to `getUser`.
import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';
import { corsHeaders } from '../_shared/cors.ts';
// As in `complete-trip/clients.ts`: shared, and apart from the builder so a test
// can pin them without a supabase-js import. `_shared/rows.ts` gives the reason.
import { first, ok } from '../_shared/rows.ts';
import type { PaymentRow, TripRow } from '../complete-trip/handler.ts';
import { handleDemoPay, type DemoPayDeps, type PaymentInput } from './handler.ts';

const json = (status: number, payload: Record<string, unknown>) =>
  new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

export function buildDemoPayDeps(
  supabaseUrl: string,
  serviceKey: string,
): DemoPayDeps {
  const service = createClient(supabaseUrl, serviceKey);
  return {
    authenticate: async (token) => {
      const { data, error } = await service.auth.getUser(token);
      return { userId: data.user?.id ?? null, error: ok(error) };
    },

    // Every read and write below is on the service key. `payments` carries a
    // SELECT policy and no INSERT or UPDATE policy (`own payments` is
    // `for select using (payer_id = auth.uid())`, `init.sql:549-550`), so a
    // rider's own credential cannot write the charge this function makes. The
    // authorisation the key bypasses is replaced in `handler.ts`, which compares
    // the trip's `rider_id` against the validated identity.
    findTrip: async (tripId) => {
      // `limit(1)` and index rather than `single()`: a missing row makes
      // PostgREST answer 406, which supabase-js throws, so the 404 underneath it
      // was unreachable.
      const { data, error } = await service
        .from('trips')
        .select('*')
        .eq('id', tripId)
        .limit(1);
      return { row: first(data) as TripRow | null, error: ok(error) };
    },

    // `payer_id` is filtered as well as `trip_id`: a driver's own charge and a
    // rider's live in the same table, and this function may only ever see the
    // rider's.
    findOpenPayment: async (tripId, payerId) => {
      const { data, error } = await service
        .from('payments')
        .select('*')
        .eq('trip_id', tripId)
        .eq('payer_id', payerId)
        .eq('state', 'pending')
        .order('created_at', { ascending: false })
        .limit(1);
      return { row: first(data) as PaymentRow | null, error: ok(error) };
    },

    createPayment: async (input: PaymentInput) => {
      // `.select('*')` because the 200 body echoes the written row, and the
      // result is indexed rather than fetched with `.single()`, so a zero-row
      // answer is the 500 below instead of a thrown 406 the handler could not
      // catch.
      const { data, error } = await service
        .from('payments')
        .insert({
          trip_id: input.tripId,
          payer_id: input.payerId,
          amount_ghs: input.amountGhs,
          method: input.method,
          state: 'pending',
          // `alter table payments add constraint payments_demo_only check
          // (is_demo)` (`init.sql:176`) refuses the row without it. Every charge
          // this build makes is demo money.
          is_demo: true,
        })
        .select('*');
      return { row: first(data) as PaymentRow | null, error: ok(error) };
    },
  };
}

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const deps = buildDemoPayDeps(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  // A Deno Edge Function has no session to read, so the identity comes from the
  // request's own bearer and the token is passed to `getUser` explicitly: the
  // argumentless `getUser()` resolves against a client-carried session and this
  // function has none, so it answers `Auth session missing!` and every call
  // 401s. The `Bearer ` scheme is required rather than stripped leniently, for
  // the reason `offers/handler.ts` sets out in full: PostgREST resolves the role
  // from the scheme word, so a bare token authenticates nowhere, and a lenient
  // strip here would pass a request that fails later at a PostgREST port. A
  // missing or unrecognised scheme, and a token the auth server refuses, both
  // arrive at the handler as a null `callerId`, which is where the 401 lives.
  const match = /^Bearer\s+(\S+)\s*$/i.exec(req.headers.get('Authorization') ?? '');
  const authed = match === null
    ? { userId: null, error: null }
    : await deps.authenticate(match[1]);

  // `req.json()` throws on a truncated body, and unguarded that escapes to
  // `serve`'s default onError, which passes no CORS headers of its own (std
  // 0.224.0 `http/server.ts:102-106`), so the client could not read the failure.
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json(400, { error: 'body must be JSON' });
  }
  const { tripId, method } = (typeof body === 'object' && body !== null && !Array.isArray(body))
    ? body as Record<string, unknown>
    : {};

  return handleDemoPay({
    deps,
    callerId: authed.userId,
    // A non-string `tripId` is refused as a 404 by the handler's own lookup, the
    // same answer a trip that is not there gets, and a non-string `method` as a
    // 400 by its own guard. Coercing either here would invent a value.
    tripId: typeof tripId === 'string' ? tripId : '',
    method: typeof method === 'string' ? method : '',
  });
});
