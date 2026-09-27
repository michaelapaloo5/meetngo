// The HTTP surface. Everything that touches a client arrives through `OfferDeps`,
// so this file holds the routing, the status codes and the response bodies, and
// nothing here has to be believed about a client: the two-client construction
// lives in clients.ts and the rule set lives in resolve.ts.
import { corsHeaders } from '../_shared/cors.ts';
import { parseOfferCommand } from './command.ts';
import {
  confirmDecline,
  declineRefusal,
  resolveAccept,
  type OfferStateName,
  type TripStateName,
} from './resolve.ts';

const json = (status: number, payload: Record<string, unknown>) =>
  new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

// The offer row as the ownership read returns it, snake_case because that is
// what comes off the wire. `state` is a string rather than the offer-state union
// because nothing here narrows it: see `DeclineRow` in resolve.ts.
export interface OfferSnapshot {
  driver_id: string;
  state: string;
  trip_id: string;
  expires_at: string;
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
  // On the caller's own bearer, so `driver reads own offers` is what makes the
  // row evidence about this driver rather than merely visible to them.
  readOffer(offerId: string): Promise<{ row: OfferSnapshot | null; error: string | null }>;
  // On the service client, `state` only. See the note in `accept` for why this
  // cannot be read on the caller's bearer.
  readTripState(tripId: string): Promise<{ state: string | null; error: string | null }>;
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
  // Two reads, on two clients, and the split is forced by the policies rather
  // than chosen.
  //
  // The offer comes from the caller's own bearer, where `driver reads own
  // offers` (migration:530) is what makes the row evidence about *this* driver.
  // That policy is not sufficient on its own -- `rider reads offers on own trip`
  // (migration:532) also lets the trip's rider read every offer on it, which
  // probe 5 measures -- so the `driver_id` comparison below is what proves
  // ownership, and `accept_offer` checks it a second time under the trip lock
  // (migration:368).
  const { row, error: readError } = await deps.readOffer(offerId);
  if (readError) return json(500, { error: readError });
  if (!row || row.driver_id !== driverId) {
    return json(404, { accepted: false, reason: 'offer not found' });
  }

  // The trip state comes from the service client because the caller's own
  // bearer cannot get it: `driver reads assigned trips` (migration:520) is
  // `using (driver_id = auth.uid())`, and a trip's driver_id is NULL until
  // `accept_offer` matches it. Probe 11 measures the driver reading their own
  // offer and 0 trip rows at that moment; probe 12 measures the same read
  // returning 1 row after the accept. So no role this function can put a
  // caller's token on has an RLS path to the trip the offer belongs to.
  //
  // This is a privileged read of one column, and it is a read of a fact the
  // driver is entitled to anyway: it is the state of the trip their own offer is
  // on. `select('state')` and not `select('*')` is deliberate -- the trip row
  // also carries the rider's `pickup`, `dropoff` and `fare_ghs`, and this
  // function has no use for them. The decision it feeds is still the RPC's: a
  // refusal here only ever skips a call the RPC would have refused too, which is
  // what the monotonicity argument in resolve.ts is for.
  const { state: tripState, error: tripError } = await deps.readTripState(row.trip_id);
  if (tripError) return json(500, { error: tripError });

  // Only the chosen offer is passed in, so `released` is always empty and the
  // handler never reports sibling ids it has not read. `winnerDriverId` is
  // likewise not reported: the winner is the RPC's to name. Both fields exist so
  // the rule set is testable over a full offer set, which is where the mirror's
  // value is, and the handler uses only the classification.
  const classified = resolveAccept({
    existingOffers: [{
      id: offerId,
      driverId: row.driver_id,
      // Cast, not narrowed. `state` is the `offer_state` enum (migration:83), so
      // the database cannot produce a value outside it, and a cast that were
      // wrong would read as not-`pending` and refuse rather than accept. Same
      // direction for the trip state.
      state: row.state as OfferStateName,
      tripId: row.trip_id,
      // A trip that is gone, or in a state this build does not name, is not
      // `requested`, and both refuse. `accept_offer` answers `false / NULL /
      // NULL` for a missing trip (migration:330-334) for the same reason.
      tripState: (tripState ?? 'cancelled') as TripStateName,
      expiresAt: row.expires_at,
    }],
    chosenOfferId: offerId,
  });

  // A refusal the RPC would have made too, answered with the reason that
  // applies instead of a bare `false`. No write is skipped: every fact tested
  // above is monotone, so this accept was already invalid.
  if (!classified.accepted) {
    return json(classified.refusalStatus ?? 409, {
      accepted: false,
      reason: classified.reason,
    });
  }

  // Classified acceptable, and the RPC decides. A `false` here is the ordinary
  // outcome of losing the race, it is reported verbatim, and nothing the
  // classifier said overrides it.
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
