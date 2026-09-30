// `contact`: hand a trip's other party their phone number.
//
// The only file that starts anything. `contact.ts` holds the rule -- who is
// allowed to have a number, and what comes back -- so it can be tested against
// a stubbed lookup; `clients.ts` holds the one query that reads another user's
// profile, with the membership test in its WHERE clause.
import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';
import { corsHeaders } from '../_shared/cors.ts';
import { buildContactLookup } from './clients.ts';
import { handleContact, type ContactDeps } from './contact.ts';

const json = (status: number, payload: Record<string, unknown>) =>
  new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json(405, { error: 'POST required' });

  // The `Bearer ` scheme is required rather than stripped, for the reason
  // `complete-trip/index.ts` sets out: PostgREST resolves the role from the
  // scheme word, and a bare token authenticates nowhere.
  const match = /^Bearer\s+(\S+)\s*$/i.exec(req.headers.get('Authorization') ?? '');

  let callerId: string | null = null;
  if (match !== null) {
    // A real session check, not a decode. This function's whole value is that
    // the number goes only to somebody on the trip, and "somebody who presented
    // a well-formed token" is a weaker claim than "somebody signed in".
    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      { auth: { persistSession: false, autoRefreshToken: false } },
    );
    const { data, error } = await admin.auth.getUser(match[1]);
    if (!error && data.user) callerId = data.user.id;
  }

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json(400, { error: 'body must be JSON' });
  }
  const tripId = typeof (body as { tripId?: unknown })?.tripId === 'string'
    ? (body as { tripId: string }).tripId
    : '';

  const deps: ContactDeps = {
    callerId,
    lookup: buildContactLookup(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    ),
  };

  const result = await handleContact(tripId, deps);
  return json(result.status, result.body as Record<string, unknown>);
});
