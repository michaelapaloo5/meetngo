// The only file that starts anything. `buildDeps` turns the client into the six
// ports `handleCancel` takes, so the routing and the rules stay testable without
// a client and this stays short enough to read. Same shape as
// `offers/index.ts`.
import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { buildClients, buildDeps } from './clients.ts';
import { handleCancel } from './handler.ts';

serve((req) => handleCancel(req, buildDeps(buildClients())));
