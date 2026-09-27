// The only file that starts anything. `buildCompleteDeps` turns the service key
// into the eight ports `handleComplete` takes, so the settlement, the money
// identity, the ratings write and the status codes stay testable without a
// client and this stays short enough to read. Same shape as
// `cancel-trip/index.ts` and `offers/index.ts`.
import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { corsHeaders } from '../_shared/cors.ts';
import { buildCompleteDeps } from './clients.ts';
import { handleComplete, readCompleteBody } from './handler.ts';

const json = (status: number, payload: Record<string, unknown>) =>
  new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const deps = buildCompleteDeps(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  // A Deno Edge Function has no session to read, so the identity comes from the
  // request's own bearer and the token is passed to `getUser` explicitly:
  // the argumentless `getUser()` resolves against a client-carried session, and
  // this function has none, so it answers `Auth session missing!` and every call
  // 401s. The `Bearer ` scheme itself is **required** rather than stripped
  // leniently, for the reason `offers/handler.ts` sets out in full: PostgREST
  // resolves the role from the scheme word, so a bare token authenticates
  // nowhere, and `authenticate` is the one port that tolerates a bare token
  // because supabase-js adds the scheme itself. A missing or unrecognised
  // scheme arrives at the handler as a null `callerId`, which is where the 401
  // lives, so it is reachable from a test rather than buried here.
  const match = /^Bearer\s+(\S+)\s*$/i.exec(req.headers.get('Authorization') ?? '');
  const authed = match === null
    ? { userId: null, error: null }
    : await deps.authenticate(match[1]);

  // `req.json()` throws on a truncated body. Unguarded that escapes to `serve`'s
  // default onError, which passes no CORS headers of its own (std 0.224.0
  // `http/server.ts:102-106`), so the client could not read the failure at all.
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json(400, { error: 'body must be JSON' });
  }
  const parsed = readCompleteBody(body);
  if (!parsed.ok) return json(400, { error: parsed.error });

  return handleComplete({
    deps,
    callerId: authed.userId,
    tripId: parsed.tripId,
    rating: parsed.rating,
  });
});
