// The admin KYC page, and the function that serves it.
//
// One function rather than a function and a website, because the service role
// key can never reach a browser. Anything that flips `kyc_status` to `approved`
// is, by definition, running with RLS switched off, so it has to live behind a
// server that holds the key. Serving the page from the same function keeps the
// privileged code in one file and means there is nothing to deploy, host or
// keep alive alongside it.
//
// The page is a string rather than a file for two reasons: there is no build
// step, and there is no second artefact that can drift out of step with the
// function it talks to.
//
// auth.admin.ts and the page are the two halves of the admin surface and the
// security of both is stated where it is implemented -- see
// `requireAdmin` in `handler.ts` and the note on the page's sign-in below.
import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';
import { corsHeaders } from '../_shared/cors.ts';
import { first, ok } from '../_shared/rows.ts';
import {
  handleDecide,
  handleList,
  type AdminDeps,
  type PendingDriver,
} from './handler.ts';
import { adminPage } from './page.ts';

const json = (status: number, payload: Record<string, unknown>) =>
  new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

export function buildAdminDeps(
  supabaseUrl: string,
  serviceKey: string,
): AdminDeps {
  const service = createClient(supabaseUrl, serviceKey);

  return {
    // supabase-js only sets `Authorization` when the request carries none
    // (`fetch.js`: `if (!headers.has('Authorization'))`), so a service key paired
    // with a forwarded bearer leaves the bearer as the effective credential
    // rather than the key. One client, nothing forwarded onto it, and the
    // caller's token is the explicit argument to `getUser`.
    authenticate: async (token) => {
      const { data, error } = await service.auth.getUser(token);
      if (ok(error) !== null) return null;
      return data.user?.id ?? null;
    },

    roleOf: async (userId) => {
      const { data, error } = await service
        .from('profiles')
        .select('role')
        .eq('id', userId)
        .limit(1);
      if (ok(error) !== null) return null;
      return (first(data) as { role?: string } | null)?.role ?? null;
    },

    listPending: async () => {
      // The driver's own email is not in `profiles` -- it is in `auth.users` --
      // so the two are joined by hand. An admin has to be able to tell two
      // drivers called "Kwame Mensah" apart, and a name is not enough.
      const { data, error } = await service
        .from('profiles')
        .select('id, full_name, phone, ghana_card_last4, ghana_card_expiry, ' +
          'selfie_url, vehicle_id, created_at')
        .eq('role', 'driver')
        .eq('kyc_status', 'pending')
        .order('created_at', { ascending: false });
      if (ok(error) !== null) return [];

      const ids = (data ?? []) as unknown as Record<string, unknown>[];
      // The bridge cast is at the boundary and nowhere else. supabase-js types
      // its query builder against a schema generic this function deliberately
      // does not declare, so the concrete client is not structurally
      // assignable to [ServiceClient] even though every call made through it
      // is one [ServiceClient] describes. Casting once here keeps that mismatch
      // from spreading into a cast on every call site.
      const typed = service as unknown as ServiceClient;
      const emails = await emailsFor(typed, ids.map((r) => r['id'] as string));
      const vehicles = await vehiclesFor(
        typed,
        ids
          .map((r) => r['vehicle_id'])
          .filter((v): v is string => typeof v === 'string'),
      );

      return ids.map((r): PendingDriver => {
        const id = r['id'] as string;
        const vehicleId = r['vehicle_id'];
        const vehicle = typeof vehicleId === 'string'
          ? vehicles.get(vehicleId) ?? null
          : null;
        return {
          id,
          email: emails.get(id) ?? '(no email on the account)',
          fullName: str(r['full_name']),
          phone: str(r['phone']),
          // `ghana_card_last4` is named for the last four digits and the app
          // writes the *first* four (`digits.substring(0, 4)` in
          // `supabase_driver_repository.dart`), so this is the leading four.
          // The column is reported as stored rather than quietly corrected: an
          // admin approving a driver should see what is actually in the row,
          // and the mismatch is worth seeing.
          cardLast4: str(r['ghana_card_last4']),
          cardExpiry: str(r['ghana_card_expiry']),
          selfieUrl: str(r['selfie_url']),
          vehicle: vehicle === null ? null : {
            make: vehicle.make,
            model: vehicle.model,
            plate: vehicle.plate,
            seats: vehicle.seats,
          },
          submittedAt: str(r['created_at']),
        };
      });
    },

    decide: async (driverId, status, decidedBy) => {      // `approved_by` and `approved_at` are added by the migration beside this
      // function. They are the difference between an approval and an anonymous
      // change of state: without them, "why is this driver online" has no answer
      // after the fact. The write is conditional on the row still being
      // `pending`, so two admins clicking at once cannot approve a driver one
      // of them has already rejected.
      const { data, error } = await service
        .from('profiles')
        .update({
          kyc_status: status,
          approved_by: decidedBy,
          approved_at: new Date().toISOString(),
          // A driver who restarts onboarding has not been approved by this
          // click, so the previous decision's author is cleared rather than
          // left pointing at whoever decided last time.
          ...(status === 'approved' ? {} : { availability: 'offline' }),
        })
        .eq('id', driverId)
        .eq('kyc_status', 'pending')
        .select('id, full_name, phone, ghana_card_last4, ghana_card_expiry')
        .limit(1);
      if (ok(error) !== null) return null;
      const row = first(data) as unknown as Record<string, unknown> | null;
      if (row === null) return null;
      return {
        id: str(row['id']),
        email: '',
        fullName: str(row['full_name']),
        phone: str(row['phone']),
        cardLast4: str(row['ghana_card_last4']),
        cardExpiry: str(row['ghana_card_expiry']),
        selfieUrl: '',
        vehicle: null,
        submittedAt: '',
      };
    },

    approveVehicle: async (driverId) => {
      const { data, error } = await service
        .from('vehicles')
        .update({ approved: true })
        .eq('owner_id', driverId)
        .select('id')
        .limit(1);
      if (ok(error) !== null) return false;
      // A zero-row update is a 200 with an empty body, not an error, so the
      // caller would otherwise be told a driver with no vehicle was approved.
      return (data ?? []).length > 0;
    },
  };
}

const str = (value: unknown): string => (typeof value === 'string' ? value : '');

/**
 * The service client, as this file needs it.
 *
 * Not `ReturnType<typeof createClient>`: that resolves to a schema-generic
 * `SupabaseClient<unknown, never, ...>`, which the `any`-parameterised client
 * `createClient(url, key)` actually returns is not assignable to -- a variance
 * complaint with no meaning here. And not a hand-rolled chain of exact shapes,
 * because a PostgREST builder is fluent in a way a fixed interface gets wrong:
 * `.in()` hangs off `.select()`, not off `.eq()`, and the terminal call
 * differs per query. So the builder is one recursive type, and the terminal
 * calls are the ones that are awaitable.
 */
type ServiceResult = PromiseLike<{
  data: unknown;
  error: { message: string } | null;
}>;

interface ServiceQuery {
  select: (columns: string) => ServiceQuery;
  update: (values: Record<string, unknown>) => ServiceQuery;
  eq: (column: string, value: unknown) => ServiceQuery;
  order: (column: string, opts: { ascending: boolean }) => ServiceResult;
  in: (column: string, values: readonly unknown[]) => ServiceResult;
  limit: (n: number) => ServiceResult;
}

interface ServiceClient {
  from: (table: string) => ServiceQuery;
  auth: {
    admin: {
      listUsers: (opts: {
        page: number;
        perPage: number;
      }) => PromiseLike<{
        data: { users: { id: string; email?: string }[] | null } | null;
        error: { message: string } | null;
      }>;
    };
  };
}

async function emailsFor(
  service: ServiceClient,
  ids: string[],
): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  if (ids.length === 0) return out;
  // `listUsers` is paginated and supabase-js has no per-id filter, so this asks
  // for a generous page rather than assuming every driver fits. A pilot has far
  // fewer; the reason for the large page is that going past the default would
  // otherwise be a driver silently missing from the list rather than a slower
  // page.
  const { data, error } = await service.auth.admin.listUsers({
    page: 1,
    perPage: 1000,
  });
  if (ok(error) !== null) return out;
  const wanted = new Set(ids);
  for (const user of data?.users ?? []) {
    if (wanted.has(user.id) && user.email) out.set(user.id, user.email);
  }
  return out;
}

async function vehiclesFor(
  service: ServiceClient,
  vehicleIds: string[],
): Promise<Map<string, { make: string; model: string; plate: string; seats: number }>> {
  const out = new Map<string, { make: string; model: string; plate: string; seats: number }>();
  if (vehicleIds.length === 0) return out;
  const { data, error } = await service
    .from('vehicles')
    .select('id, make, model, plate, seats')
    .in('id', vehicleIds);
  if (ok(error) !== null) return out;
  const rows = (data ?? []) as Record<string, unknown>[];
  for (const r of rows) {
    out.set(str(r['id']), {
      make: str(r['make']),
      model: str(r['model']),
      plate: str(r['plate']),
      seats: typeof r['seats'] === 'number' ? r['seats'] : 0,
    });
  }
  return out;
}

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const url = Deno.env.get('SUPABASE_URL') ?? '';
  // The anon key, used for exactly one thing: verifying a sign-in. It is not a
  // secret in the sense the service key is -- it ships inside both apps -- but
  // keeping it server-side means the admin page holds no credential at all.
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
  const deps = buildAdminDeps(
    url,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
  );

  // The page itself, and deliberately unauthenticated: it contains no data and
  // no credential, only a sign-in form. Everything it displays arrives from the
  // authenticated calls below, and a 401 renders as "sign in" rather than as
  // an empty page that looks like there are no drivers.
  if (req.method === 'GET' && !req.headers.get('Authorization')) {
    return new Response(adminPage(url), {
      headers: { ...corsHeaders, 'Content-Type': 'text/html; charset=utf-8' },
    });
  }

  // A Deno Edge Function has no session to read, so the identity comes from
  // the request's own bearer and is passed to `getUser` explicitly: the
  // argumentless form resolves against a client-carried session this function
  // does not have, and every call would 401. The `Bearer ` scheme is required
  // rather than stripped leniently, because PostgREST resolves the role from
  // the scheme word -- a bare token authenticates nowhere.
  const match = /^Bearer\s+(\S+)\s*$/i.exec(req.headers.get('Authorization') ?? '');
  const callerId = match === null
    ? null
    : await deps.authenticate(match[1]);

  let body: unknown = {};
  if (req.method === 'POST') {
    try {
      body = await req.json();
    } catch {
      return json(400, { error: 'body must be JSON' });
    }
  }
  const record = (typeof body === 'object' && body !== null && !Array.isArray(body))
    ? body as Record<string, unknown>
    : {};

  // Sign-in, handled here rather than in the page, so the browser holds no
  // credential at all -- not even the anon key, which is the same one that
  // ships in both apps. The password is verified by the auth server through the
  // anon client and only a short-lived user JWT comes back. Everything after
  // this is a decision about a driver, and every one of those re-checks
  // `role = 'admin'` server-side.
  if (record['action'] === 'signin') {
    const email = typeof record['email'] === 'string' ? record['email'] : '';
    const password = typeof record['password'] === 'string' ? record['password'] : '';
    if (email === '' || password === '') {
      return json(400, { error: 'email and password are required' });
    }
    const { data, error } = await createClient(url, anonKey).auth.signInWithPassword({
      email,
      password,
    });
    if (ok(error) !== null) {
      // The auth server's own message, deliberately not swallowed. "Invalid
      // login credentials" tells an admin their password is wrong; a generic
      // failure would have them retrying a password that was always right.
      return json(401, { error: error?.message ?? 'sign in failed' });
    }
    const accessToken = data.session?.access_token;
    if (typeof accessToken !== 'string' || accessToken === '') {
      return json(500, { error: 'no session was returned' });
    }
    return json(200, { token: accessToken });
  }

  if (req.method === 'POST' && record['action'] === 'decide') {
    const result = await handleDecide(deps, callerId, {
      driverId: typeof record['driverId'] === 'string' ? record['driverId'] : '',
      action: record['decision'] === 'reject' ? 'reject' : 'approve',
    });
    return json(result.status, result.body);
  }

  const result = await handleList(deps, callerId);
  return json(result.status, result.body);
});
