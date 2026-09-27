import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { buildClients, buildDeps } from './clients.ts';
import { handleOfferRequest } from './handler.ts';

// The only file that starts anything. `buildDeps` turns the two clients into
// the four ports `handleOfferRequest` takes, so the routing and the rules stay
// testable without a client and this stays short enough to read.
serve((req) => handleOfferRequest(req, buildDeps(buildClients(req))));
