// The HTTP surface. Everything that touches a client arrives through `OfferDeps`,
// so this file holds the routing, the status codes and the response bodies, and
// nothing here has to be believed about a client: the two-client construction
// lives in clients.ts and the rule set lives in resolve.ts.
import { corsHeaders } from '../_shared/cors.ts';
import { parseOfferCommand } from './command.ts';
import { confirmDecline, declineRefusal } from './resolve.ts';

const json = (status: number, payload: Record<string, unknown>) =>
  new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

// The row as the ownership read returns it, snake_case because that is what
// comes off the wire. `state` is a string rather than the offer-state union
// because nothing here narrows it: see `DeclineRow` in resolve.ts.
export interface OfferSnapshot {
  driver_id: string;
  state: string;
}

export interface AcceptRpcRow {
  accepted: unknown;
  trip_id: string | null;
  driver_id: string | null;
}

export interface OfferDeps {
  // Resolves a bearer token to a user id. `error` and `userId` are both checked:
  // `getUser` answers a malformed or revoked token with a null user *and* an
  // error, and either alone is enough to refuse.
  authenticate(token: string): Promise<{ userId: string | null; error: string | null }>;
  readOffer(offerId: string): Promise<{ row: OfferSnapshot | null; error: string | null }>;
  acceptOffer(offerId: string): Promise<{ rows: unknown; error: string | null }>;
  writeDecline(offerId: string, driverId: string): Promise<{ updated: number; error: string | null }>;
}

export async function handleOfferRequest(req: Request, deps: OfferDeps): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  // A Deno Edge Function has no session to read, so the identity comes from the
  // request's own bearer and the token is passed to `getUser` explicitly. The
  // `Bearer ` prefix is stripped rather than required: an `Authorization` that
  // is already the bare token is still a credential, and refusing it would be a
  // client-shaped failure in a function that is otherwise fine.
  const header = req.headers.get('Authorization') ?? '';
  const token = header.replace(/^Bearer\s+/i, '');
  if (!token) return json(401, { error: 'unauthenticated' });

  const { userId, error: authError } = await deps.authenticate(token);
  if (authError || !userId) return json(401, { error: 'unauthenticated' });
  const driverId = userId;

  // `req.json()` throws on a truncated or non-JSON body. Unguarded, that escapes
  // to `serve`'s default onError, which returns a bare 500 with no body, so a
  // client that sends a bad body is told its request failed rather than that its
  // body was wrong.
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json(400, { error: 'body must be JSON' });
  }

  const command = parseOfferCommand(body);
  if (!command.ok) return json(400, { error: command.error });
  const { action, offerId } = command.value;

  if (action === 'decline') return decline(deps, offerId, driverId);
  return accept(deps, offerId, driverId);
}

async function accept(
  deps: OfferDeps,
  offerId: string,
  driverId: string,
): Promise<Response> {
  // The read exists to answer 404 rather than to authorise: `accept_offer`
  // refuses a stranger's offer with the same `false` it gives a lost race, so
  // without this the driver app cannot tell "that is not your offer" from "you
  // were too slow", and the 404 is the only thing that can.
  const { row, error: readError } = await deps.readOffer(offerId);
  if (readError) return json(500, { error: readError });
  if (!row || row.driver_id !== driverId) {
    return json(404, { accepted: false, reason: 'offer not found' });
  }

  const { rows, error } = await deps.acceptOffer(offerId);
  if (error) return json(500, { error });

  // `accept_offer` is declared `returns table (accepted boolean, trip_id uuid,
  // driver_id uuid)` (migration:292), so PostgREST answers with a one-row array
  // however the call went: even the unknown-id path returns
  // `false / NULL / NULL` (probe 10). An empty array is therefore not a lost
  // race, it is a response this function does not understand, and reporting it
  // as `accepted: false` would tell the driver they lost when nothing says they
  // did. A `false` row, by contrast, is a normal outcome and is a 200.
  if (!Array.isArray(rows) || rows.length === 0) {
    return json(500, { error: 'accept_offer returned no row' });
  }
  const row0 = rows[0] as AcceptRpcRow;

  // `accepted` is a boolean in the OUT list, and the driver app casts it, so a
  // non-boolean here is a broken response rather than a refusal to be passed
  // through as one. Same reasoning as `isFiniteNumber` in request-ride: a
  // response shape that silently becomes a wrong answer is refused instead.
  if (typeof row0.accepted !== 'boolean') {
    return json(500, { error: 'accept_offer returned a non-boolean accepted' });
  }

  return json(200, {
    accepted: row0.accepted,
    // Echoed on both outcomes, and it is not always null on a refusal: the
    // expiry and terminal-offer path answers with the trip id and a null driver
    // (probe 9), while the ownership and unknown-id paths answer with both null
    // (probes 1, 2, 4, 5, 10). The driver app uses it to close the offer queue.
    tripId: row0.trip_id ?? null,
    winnerDriverId: row0.accepted ? row0.driver_id ?? null : null,
  });
}

async function decline(
  deps: OfferDeps,
  offerId: string,
  driverId: string,
): Promise<Response> {
  // The read is on the caller's own bearer, so `driver reads own offers`
  // (migration:530) is what makes it evidence about *this* driver, and the
  // write is on the service key because `offers` has no UPDATE policy
  // (migration:530 and :532 are its only two policies; probes 6 and 7 measure
  // the consequence). Three invariants are established here that RLS would
  // otherwise have provided: the offer exists, it is still pending, and it
  // belongs to the caller.
  const { row, error: readError } = await deps.readOffer(offerId);
  if (readError) return json(500, { error: readError });

  const refusal = declineRefusal({
    row: row ? { driverId: row.driver_id, state: row.state } : null,
    callerDriverId: driverId,
  });
  if (refusal) return json(refusal.status, { declined: false, reason: refusal.reason });

  // Only reached once the read says the offer is this driver's and still
  // pending, so the three filters on the write are a second line of defence
  // rather than the only one.
  const { updated, error } = await deps.writeDecline(offerId, driverId);
  if (error) return json(500, { error });

  const result = confirmDecline(updated);
  if (!result.declined) {
    return json(result.status, { declined: false, reason: result.reason });
  }
  return json(200, { declined: true });
}
