// The HTTP surface. Everything that touches a client arrives through `OfferDeps`,
// so this file holds the routing, the status codes and the response bodies, and
// nothing here has to be believed about a client: the two-client construction
// lives in clients.ts and the rule set lives in resolve.ts.
import { corsHeaders } from '../_shared/cors.ts';
import { parseOfferCommand } from './command.ts';
import { confirmDecline, declineRefusal, resolveAccept, type OfferStateName } from './resolve.ts';

// The two classifier refusals the handler answers itself, and the only two. The
// test is on the reason prefix, which is a string match, and that is a real
// coupling: `resolveAccept` is the single place the reasons are produced, the
// two that belong to the RPC are produced by the very same function, and a
// reworded reason here would silently send a terminal offer to the RPC -- which
// is safe, just less specific. Widening the other way is the dangerous
// direction and `terminal refusal` / `offer not found` is checked explicitly in
// the test file rather than left to this prefix to carry.
const OURS = ['offer not found', 'offer already '];
const classificationIsOurs = (reason: string): boolean =>
  OURS.some((prefix) => reason.startsWith(prefix));

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
  // Read because it is free on a read that happens anyway, and passed to the
  // classifier truthfully. The handler does not act on the expiry verdict, for
  // the reason in `accept`.
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
  // On the caller's own bearer too, and there is deliberately no port for
  // reading a trip: the classifier's trip-state verdict is one the handler does
  // not act on, because the RPC's refusal path is what performs the `expired`
  // write. See `accept`.
  acceptOffer(offerId: string): Promise<{ rows: unknown; error: string | null }>;
  writeDecline(offerId: string, driverId: string): Promise<{ updated: number; error: string | null }>;
}

export async function handleOfferRequest(req: Request, deps: OfferDeps): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  // A Deno Edge Function has no session to read, so the identity comes from the
  // request's own bearer and the token is passed to `getUser` explicitly.
  //
  // The `Bearer ` scheme is **required**, not stripped. PostgREST resolves the
  // role from that scheme word and not from the header's mere presence: wai's
  // `extractBearerAuth` returns the token only when the scheme compares equal to
  // `bearer` after lowercasing, and PostgREST substitutes `""` otherwise, so a
  // bare token authenticates nowhere. Stripping the prefix leniently would be
  // worse than refusing it, because `authenticate` is the one port that
  // tolerates a bare token -- supabase-js's `getUser(token)` adds the scheme
  // itself -- while `readOffer` and `acceptOffer` forward the raw header. The
  // request would then pass the identity check and fail later at a PostgREST
  // port, with an outcome that is a 500 or a misleading 404. Refusing here
  // makes that unreachable.
  //
  // The scheme is matched case-insensitively, which is what wai's comparison
  // does, so `bearer <token>` is accepted the same as `Bearer <token>`.
  const match = /^Bearer\s+(\S+)\s*$/i.exec(req.headers.get('Authorization') ?? '');
  if (!match) return json(401, { error: 'unauthenticated' });
  const token = match[1];

  const { userId, error: authError } = await deps.authenticate(token);
  if (authError || !userId) return json(401, { error: 'unauthenticated' });
  const driverId = userId;

  // `req.json()` throws on a truncated or non-JSON body. Unguarded, that escapes
  // to `serve`'s default onError, which is
  // `new Response("Internal Server Error", { status: 500 })` with no headers at
  // all (std 0.224.0 `http/server.ts:102-106`). The body is the smaller problem:
  // that response carries no `Access-Control-Allow-Origin`, so a browser or
  // Flutter-web client cannot read it, and every other response this handler
  // returns goes out through `corsHeaders`. Catching it here is what keeps a
  // malformed body a readable 400.
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
  // One refusal shape for every refusal this handler produces: `accepted`,
  // `tripId`, `winnerDriverId`, `reason`. Task 13 can read `tripId` off any of
  // them without branching on which refusal it got.
  //
  // `tripId` is null here even when the row was read, because the row is
  // somebody else's and naming its trip would hand a stranger an id they have no
  // claim to. An offer that is not there has no trip to name either.
  if (!row || row.driver_id !== driverId) {
    return json(404, {
      accepted: false,
      tripId: null,
      winnerDriverId: null,
      reason: 'offer not found',
    });
  }

  // No trip read, and that is the point. An earlier version of this function
  // read the trip's state from the service client here, to feed the
  // classifier's `trip is no longer awaiting a driver` branch, and that read
  // cost a privileged round trip per accept. It is gone because the handler does
  // not act on that verdict: the RPC's refusal path is what moves the offer to
  // `expired` there (migration:373-376), and skipping the call skipped the
  // write. So `tripState` is passed as null -- "not read" -- and the mirror
  // skips the check it has no data for rather than guessing.
  //
  // The read was not possible on the caller's own bearer either, which is why
  // the port had to be the service one: `driver reads assigned trips`
  // (migration:520) is `using (driver_id = auth.uid())` and a trip's driver_id
  // is NULL until `accept_offer` matches it, so probe 11 measures the driver
  // reading their own offer and 0 trip rows at that moment. Neither reading it
  // nor not reading it is a shortcut here; not reading it is the only option
  // that also keeps the write.
  //
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
      // wrong would read as not-`pending` and refuse rather than accept.
      state: row.state as OfferStateName,
      tripId: row.trip_id,
      // Not read, and not guessed. See the note above.
      tripState: null,
      expiresAt: row.expires_at,
    }],
    chosenOfferId: offerId,
  });

  // Act on a refusal **only** when the RPC's `expired` write cannot fire for it.
  // That write is `where id = p_offer and state = 'pending'` (migration:376), so
  // it is inert for an offer that is not there and for one already in a terminal
  // state. For `offer expired` and `trip is no longer awaiting a driver` the RPC
  // *does* write, and those two verdicts are deliberately ignored here so the
  // call goes out and the offer is moved to `expired`. `classificationIsOurs`
  // names the two, so narrowing or widening this set is a visible edit.
  //
  // The 404 above has already answered the not-there case, so in practice this
  // branch is the terminal-state refusal. It is kept as a named condition rather
  // than folded into the 404 because the two answers come from different facts
  // and the classifier is where that fact is interpreted.
  if (!classified.accepted && classificationIsOurs(classified.reason)) {
    // `tripId` is the one field this refusal can supply truthfully: the offer
    // row was read, so `trip_id` is known. Every accept refusal carries the same
    // three keys, with `tripId: null` where the trip is not knowable, so Task
    // 13 can read `tripId` without branching on which refusal it got.
    return json(classified.refusalStatus ?? 409, {
      accepted: false,
      tripId: row.trip_id,
      winnerDriverId: null,
      reason: classified.reason,
    });
  }

  // Classified acceptable -- or classified with a verdict the RPC owns, which is
  // most of the refusals -- and the RPC decides. A `false` here is the ordinary
  // outcome of losing the race, or the correct answer for an expired offer, and
  // it is reported verbatim. Nothing the classifier said can override it or
  // promote it: the classifier is only ever read in the branch above, which
  // returns.
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
