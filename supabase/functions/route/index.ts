// The only file that starts anything. `route.ts` holds the engine selection,
// the normalisation and the traffic factor so they can be tested against a
// stubbed `fetch`; this wires the one real thing it needs, the function secret.
//
// There is deliberately no client and no session check. Routing is a public
// fact about roads, not user data, and this function reads nothing and writes
// nothing -- it has no service key and issues no query. Locking it behind a
// signed-in user would add a round trip to every navigation frame to protect
// nothing, and the abuse that matters (burning the upstream quota) is the same
// either way.
import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { handleRoute } from './route.ts';

serve((req) => handleRoute(req, {
  fetch,
  // Absent or refused is the normal state of affairs today: the HeiGIT account
  // answers 403 on every endpoint, so the function falls through to the
  // keyless engine and reports `degraded: true`. The day the key starts
  // working this picks it up with no redeploy of the app.
  orsKey: Deno.env.get('ORS_API_KEY') ?? null,
}));
