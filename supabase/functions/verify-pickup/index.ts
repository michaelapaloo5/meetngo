import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';

import { corsHeaders } from '../_shared/cors.ts';

const json = (status: number, payload: Record<string, unknown>) =>
  new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

/**
 * Checks a rider's pickup code for a driver who has arrived.
 *
 * The comparison happens here rather than in the app because `trips` carries a
 * full-row SELECT policy for the assigned driver (`driver reads assigned trips`,
 * `init.sql:520`): a driver can read `trips.pickup_otp` with their own
 * credential, so an app-side comparison would prove nothing. This does not
 * remove that read -- a real build moves the code out of `trips` into a table
 * with no client policy at all, which a Postgres column grant cannot do. Until
 * then the honest limitation is that the code proves a rider said four digits,
 * not that the rider is standing there.
 *
 * Deployed with the service key: the code is only ever read here, and only ever
 * for the trip the caller is the driver of.
 */

const bearer = (header: string | null): string | null => {
  if (!header) return null;
  // The scheme word is required, not stripped-and-hoped-for. PostgREST 12.2.3
  // `Auth.hs:107` uses `Wai.extractBearerAuth` from wai-extra, which returns
  // Nothing unless the header begins with "bearer", so a bare token resolves to
  // the empty string and the request would run as anon.
  const match = /^Bearer\s+(\S+)\s*$/i.exec(header.trim());
  return match ? match[1] : null;
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CODE = /^[0-9]{4}$/;

serve(
  async (req: Request) => {
    if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
    if (req.method !== 'POST') return json(405, { error: 'method not allowed' });

    const url = Deno.env.get('SUPABASE_URL');
    const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!url || !key) return json(500, { error: 'server is not configured' });

    const token = bearer(req.headers.get('Authorization'));
    if (!token) return json(401, { error: 'sign in required' });

    const supabase = new SupabaseClient(url, key, {
      auth: { persistSession: false },
    });

    const { data: userData, error: userError } = await supabase.auth
      .getUser(token);
    const userId = userError ? null : userData.user?.id;
    if (!userId) return json(401, { error: 'sign in required' });

    let body: unknown;
    try {
      body = await req.json();
    } catch {
      return json(400, { error: 'body must be json' });
    }
    const { tripId, code } = (body ?? {}) as { tripId?: unknown; code?: unknown };
    if (typeof tripId !== 'string' || !UUID.test(tripId)) {
      return json(400, { error: 'tripId must be a uuid' });
    }
    if (typeof code !== 'string' || !CODE.test(code)) {
      return json(400, { error: 'code must be four digits' });
    }

    const { data: rows, error: readError } = await supabase
      .from('trips')
      .select('id,driver_id,state,pickup_otp')
      .eq('id', tripId)
      .limit(1);
    if (readError) return json(500, { error: 'could not read the trip' });

    const trip = (rows ?? [])[0] as Record<string, unknown> | undefined;
    // "No such trip" and "not your trip" are deliberately the same answer, or
    // this becomes an oracle for guessing which trip ids exist.
    if (!trip || trip.driver_id !== userId) {
      return json(404, { error: 'trip not found' });
    }
    if (trip.state !== 'arriving') {
      return json(409, { error: 'not waiting for pickup' });
    }
    if (String(trip.pickup_otp ?? '') !== code) {
      return json(400, { error: 'that code is not right' });
    }

    return json(200, { ok: true, tripId });
  },
  { onError: (e) => json(500, { error: String(e) }) },
);
