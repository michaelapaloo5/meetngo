import { assert, assertEquals } from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import { FakeTime } from 'https://deno.land/std@0.224.0/testing/time.ts';
import { parseOfferCommand } from '../offers/command.ts';
import { handleOfferRequest, type OfferDeps } from '../offers/handler.ts';
import {
  confirmDecline,
  declineRefusal,
  resolveAccept,
  type OfferRow,
  type TripStateName,
} from '../offers/resolve.ts';

const offer = (over: Partial<OfferRow> = {}): OfferRow => ({
  id: 'o1',
  driverId: 'driverA',
  state: 'pending',
  tripId: 't1',
  tripState: 'requested',
  expiresAt: new Date(Date.now() + 10_000).toISOString(),
  ...over,
});

// ---------------------------------------------------------------------------
// resolveAccept: the mirror of the RPC's rules
// ---------------------------------------------------------------------------

Deno.test('accept_offer_single_winner_test: first accept wins and releases the rest', () => {
  const result = resolveAccept({
    existingOffers: [
      offer({ id: 'o1', driverId: 'driverA' }),
      offer({ id: 'o2', driverId: 'driverB' }),
      offer({ id: 'o3', driverId: 'driverC' }),
    ],
    chosenOfferId: 'o1',
  });
  assertEquals(result.accepted, true);
  assertEquals(result.winnerDriverId, 'driverA');
  assertEquals(result.released, ['o2', 'o3']);
  assertEquals(result.nextTripState, 'matched');
  assertEquals(result.reason, 'ok');
  // No refusal, so no status to send. The handler reads this field rather than
  // matching on `reason`.
  assertEquals(result.refusalStatus, null);
});

// The sibling filter is what frees the losing drivers, so it has to exclude
// every offer that is not a still-pending one. A filter that dropped the
// `state = 'pending'` clause would report offers that are already accepted or
// declined as newly released, and this pins that to ['o4'].
Deno.test('only the still-pending siblings are released', () => {
  const result = resolveAccept({
    existingOffers: [
      offer({ id: 'o1', driverId: 'driverA' }),
      offer({ id: 'o2', driverId: 'driverB' }),
      offer({ id: 'o3', driverId: 'driverB', state: 'declined' }),
      offer({ id: 'o4', driverId: 'driverC' }),
      offer({ id: 'o5', driverId: 'driverC', state: 'expired' }),
    ],
    chosenOfferId: 'o1',
  });
  assertEquals(result.accepted, true);
  assertEquals(result.released, ['o2', 'o4']);
});

// The losing accept. `nextTripState` is fed back as the chosen row's trip
// state, which is where the mirror reads it from, so the second call sees the
// trip the first one matched.
Deno.test('a second simultaneous accept is rejected with no side effects', () => {
  const offers = [offer({ id: 'o1', driverId: 'driverA' }), offer({ id: 'o2', driverId: 'driverB' })];
  const first = resolveAccept({ existingOffers: offers, chosenOfferId: 'o1' });
  const second = resolveAccept({
    existingOffers: [
      offer({ id: 'o1', driverId: 'driverA', tripState: first.nextTripState as TripStateName }),
      offer({ id: 'o2', driverId: 'driverB', tripState: first.nextTripState as TripStateName }),
    ],
    chosenOfferId: 'o2',
  });
  assertEquals(first.accepted, true);
  assertEquals(second.accepted, false);
  assertEquals(second.winnerDriverId, null);
  assertEquals(second.released, []);
  assertEquals(second.reason, 'trip is no longer awaiting a driver');
});

// All five non-`requested` states, so a check that tested only one of them, or
// tested the string against a list that is missing one, fails here.
Deno.test('accept after the trip left requested is rejected', () => {
  for (const state of ['matched', 'arriving', 'ongoing', 'completed', 'cancelled'] as const) {
    const result = resolveAccept({
      existingOffers: [offer({ tripState: state })],
      chosenOfferId: 'o1',
    });
    assertEquals(result.accepted, false, `trip state ${state} must reject accept`);
    assertEquals(result.nextTripState, state);
    assertEquals(result.refusalStatus, 409, `trip state ${state}`);
  }
});

// The order of the two refusals that can both fire, which is the only ordering
// the surface can observe: a declined offer on a matched trip reports the trip.
// A check that tested the offer's state first would say `offer already declined`,
// and that is a different answer about why a driver lost.
Deno.test('a terminal offer on a matched trip reports the trip, not the offer', () => {
  for (const state of ['accepted', 'declined', 'expired', 'released'] as const) {
    const result = resolveAccept({
      existingOffers: [offer({ state, tripState: 'matched' })],
      chosenOfferId: 'o1',
    });
    assertEquals(result.accepted, false);
    assertEquals(result.reason, 'trip is no longer awaiting a driver', `offer state ${state}`);
  }
});

// The trip state comes from the chosen offer's own row. A sibling still reading
// `requested` must not talk the check out of rejecting: the mirror reads the row
// the RPC reads, which is the trip the chosen offer belongs to.
Deno.test("a chosen row's own trip state decides, not a sibling's", () => {
  const result = resolveAccept({
    existingOffers: [
      offer({ id: 'o1', tripState: 'matched' }),
      offer({ id: 'o2', tripState: 'requested' }),
    ],
    chosenOfferId: 'o1',
  });
  assertEquals(result.accepted, false);
  assertEquals(result.reason, 'trip is no longer awaiting a driver');
});

Deno.test('expired offer cannot be accepted', () => {
  const result = resolveAccept({
    existingOffers: [offer({ expiresAt: new Date(Date.now() - 1000).toISOString() })],
    chosenOfferId: 'o1',
  });
  assertEquals(result.accepted, false);
  assertEquals(result.reason, 'offer expired');
  assertEquals(result.released, []);
  assertEquals(result.refusalStatus, 409);
});

Deno.test('an offer at or before now is expired', () => {
  const result = resolveAccept({
    existingOffers: [offer({ expiresAt: new Date(Date.now() - 1).toISOString() })],
    chosenOfferId: 'o1',
  });
  assertEquals(result.accepted, false);
  assertEquals(result.reason, 'offer expired');
});

// The inclusive boundary itself, which the test above cannot reach: reading
// `Date.now()` a moment before the call means the row is always already past
// its expiry by the time the comparison runs, so a `<` would pass it. With the
// clock frozen the two sides are the same instant, and this is the only way to
// see `<=` from outside. The RPC's own comparison is `expires_at <= now()`
// (migration:375) and probe 9 of supabase/tests/verify_offer_authz.sql measures
// it refusing an offer whose expires_at is exactly now(), so this side is the
// one that has to hold the boundary. Task 4's `Offer.isExpired` is the strict
// one (offer.dart:35).
Deno.test('an offer expiring at exactly now is already expired', () => {
  const clock = new FakeTime(1_700_000_000_000);
  try {
    const result = resolveAccept({
      existingOffers: [offer({ expiresAt: new Date(Date.now()).toISOString() })],
      chosenOfferId: 'o1',
    });
    assertEquals(result.accepted, false, 'exactly now must count as expired');
    assertEquals(result.reason, 'offer expired');
  } finally {
    clock.restore();
  }
});

// The other side of the same frozen instant: one millisecond of life left, and
// a strict comparison would also read this as expired.
Deno.test('an offer with one millisecond left is still acceptable', () => {
  const clock = new FakeTime(1_700_000_000_000);
  try {
    const result = resolveAccept({
      existingOffers: [offer({ expiresAt: new Date(Date.now() + 1).toISOString() })],
      chosenOfferId: 'o1',
    });
    assertEquals(result.accepted, true);
  } finally {
    clock.restore();
  }
});

Deno.test('an offer with a moment left is still acceptable', () => {
  const result = resolveAccept({
    existingOffers: [offer({ expiresAt: new Date(Date.now() + 5_000).toISOString() })],
    chosenOfferId: 'o1',
  });
  assertEquals(result.accepted, true);
});

Deno.test('offers already in a terminal offer state cannot be re-accepted', () => {
  for (const state of ['declined', 'accepted', 'expired', 'released'] as const) {
    const result = resolveAccept({
      existingOffers: [offer({ state })],
      chosenOfferId: 'o1',
    });
    assertEquals(result.accepted, false, `offer state ${state} must reject accept`);
    assertEquals(result.reason, `offer already ${state}`);
    assertEquals(result.refusalStatus, 409, `offer state ${state}`);
  }
});

Deno.test('unknown offer id is rejected', () => {
  const result = resolveAccept({
    existingOffers: [offer({ id: 'o1', driverId: 'driverA' })],
    chosenOfferId: 'nope',
  });
  assertEquals(result.accepted, false);
  assertEquals(result.reason, 'offer not found');
  // There is no trip to have a state when the offer was never found, and
  // inventing one would be a caller-supplied value again.
  assertEquals(result.nextTripState, null);
  // 404 and not 409: the offer is not there, which is a different answer from
  // the offer being there in a state that forbids the accept.
  assertEquals(result.refusalStatus, 404);
});

// The RPC tests the offer's existence before the trip's state (migration:304-307),
// so an unknown id reports the offer even on a trip that is long gone. An
// ordering that tested the trip first would say the opposite.
Deno.test('an unknown offer id reports the offer, not the trip', () => {
  const result = resolveAccept({
    existingOffers: [offer({ id: 'o1', tripState: 'cancelled' })],
    chosenOfferId: 'nope',
  });
  assertEquals(result.reason, 'offer not found');
});

// ---------------------------------------------------------------------------
// parseOfferCommand
// ---------------------------------------------------------------------------

const commandBody = (over: Record<string, unknown> = {}) => ({
  action: 'accept',
  offerId: '0f2c1d6a-3b4e-4c5d-8e9f-a0b1c2d3e4f5',
  ...over,
});

const refuseCommand = (raw: unknown): string => {
  const result = parseOfferCommand(raw);
  assert(!result.ok, `expected a refusal, got ${JSON.stringify(result)}`);
  return result.error;
};

Deno.test('a valid accept and a valid decline are both taken', () => {
  for (const action of ['accept', 'decline'] as const) {
    const result = parseOfferCommand(commandBody({ action }));
    assert(result.ok, JSON.stringify(result));
    assertEquals(result.value.action, action);
    assertEquals(result.value.offerId, '0f2c1d6a-3b4e-4c5d-8e9f-a0b1c2d3e4f5');
  }
});

// Everything that is not exactly 'decline' would fall through to the accept
// path under `body.action === 'decline'`, and accepting an offer on a driver's
// behalf matches the trip for real. Each of these is a value a client can send.
Deno.test('an action that is not accept or decline is refused', () => {
  assertEquals(refuseCommand(commandBody({ action: 'Accept' })), 'action must be one of accept, decline');
  assertEquals(refuseCommand(commandBody({ action: 'accept ' })), 'action must be one of accept, decline');
  assertEquals(refuseCommand(commandBody({ action: 'delete' })), 'action must be one of accept, decline');
  assertEquals(refuseCommand(commandBody({ action: 1 })), 'action must be one of accept, decline');
  assertEquals(refuseCommand(commandBody({ action: true })), 'action must be one of accept, decline');
  assertEquals(refuseCommand(commandBody({ action: null })), 'action must be one of accept, decline');
  // The missing one, which is the case a client hits by sending `offerId` alone.
  const { action: _dropped, ...withoutAction } = commandBody();
  assertEquals(refuseCommand(withoutAction), 'action must be one of accept, decline');
});

Deno.test('a non-string offerId is refused', () => {
  assertEquals(refuseCommand(commandBody({ offerId: 7 })), 'offerId must be a string');
  assertEquals(refuseCommand(commandBody({ offerId: true })), 'offerId must be a string');
  assertEquals(refuseCommand(commandBody({ offerId: ['id'] })), 'offerId must be a string');
  assertEquals(refuseCommand(commandBody({ offerId: { id: 'x' } })), 'offerId must be a string');
  const { offerId: _dropped, ...withoutId } = commandBody();
  assertEquals(refuseCommand(withoutId), 'offerId must be a string');
});

// A non-uuid id reaches PostgREST as `id=eq.<value>`, which it answers with a
// 400 that the handler would surface as a 500. An empty string is the case a
// text field that was never filled in arrives as.
Deno.test('an offerId that is not a uuid is refused', () => {
  assertEquals(refuseCommand(commandBody({ offerId: '' })), 'offerId must be a uuid');
  assertEquals(refuseCommand(commandBody({ offerId: 'nope' })), 'offerId must be a uuid');
  assertEquals(refuseCommand(commandBody({ offerId: '123' })), 'offerId must be a uuid');
  assertEquals(
    refuseCommand(commandBody({ offerId: '0f2c1d6a-3b4e-4c5d-8e9f-a0b1c2d3e4f5; select 1' })),
    'offerId must be a uuid',
  );
});

Deno.test('a body that is not a JSON object is refused', () => {
  assertEquals(refuseCommand([]), 'body must be a JSON object');
  assertEquals(refuseCommand(null), 'body must be a JSON object');
  assertEquals(refuseCommand('accept'), 'body must be a JSON object');
  assertEquals(refuseCommand(5), 'body must be a JSON object');
});

Deno.test('an unknown extra field is left alone', () => {
  const result = parseOfferCommand(commandBody({ reason: 'no thanks' }));
  assert(result.ok, JSON.stringify(result));
  assertEquals(result.value.action, 'accept');
});

// ---------------------------------------------------------------------------
// The decline decision
// ---------------------------------------------------------------------------

Deno.test('declineRefusal passes a pending offer of the caller', () => {
  assertEquals(declineRefusal({ row: { driverId: 'd1', state: 'pending' }, callerDriverId: 'd1' }), null);
});

Deno.test('declineRefusal refuses an offer that does not exist', () => {
  assertEquals(
    declineRefusal({ row: null, callerDriverId: 'd1' }),
    { status: 404, reason: 'offer not found' },
  );
});

// The rider on their own trip can read every offer on it (probe 5), so a row
// from the read does not prove ownership and the driver_id test is the only
// thing standing there. It answers the same 404 as an unknown id, so the answer
// does not tell a stranger the offer exists.
Deno.test("declineRefusal refuses another driver's offer as not found", () => {
  assertEquals(
    declineRefusal({ row: { driverId: 'd2', state: 'pending' }, callerDriverId: 'd1' }),
    { status: 404, reason: 'offer not found' },
  );
});

Deno.test('declineRefusal refuses a terminal offer, and says which state', () => {
  for (const state of ['accepted', 'declined', 'expired', 'released']) {
    assertEquals(
      declineRefusal({ row: { driverId: 'd1', state }, callerDriverId: 'd1' }),
      { status: 409, reason: `offer is already ${state}` },
    );
  }
});

// An offer state outside the enum, which the database cannot produce but a
// changed response shape could. It is refused, and it is never written.
Deno.test('declineRefusal refuses a state it does not recognise', () => {
  assertEquals(
    declineRefusal({ row: { driverId: 'd1', state: 'pendingish' }, callerDriverId: 'd1' }),
    { status: 409, reason: 'offer is already pendingish' },
  );
});

Deno.test('confirmDecline reports one changed row as a decline', () => {
  assertEquals(confirmDecline(1), { declined: true });
});

// The one the whole decline path exists to get right. The write is filtered on
// `state = 'pending'`, so a rival accept or a second decline makes it match
// nothing, and the client still reports `error = null`.
Deno.test('confirmDecline does not report a zero-row write as a decline', () => {
  assertEquals(confirmDecline(0), {
    declined: false,
    status: 409,
    reason: 'offer is no longer pending',
  });
});

Deno.test('confirmDecline refuses a count the primary key cannot produce', () => {
  assertEquals(confirmDecline(2).declined, false);
});

// ---------------------------------------------------------------------------
// The handler
// ---------------------------------------------------------------------------

const OFFER_ID = '0f2c1d6a-3b4e-4c5d-8e9f-a0b1c2d3e4f5';
const TRIP_ID = '1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d';

const offerRow = (over: Record<string, unknown> = {}) => ({
  driver_id: 'd1',
  state: 'pending',
  trip_id: TRIP_ID,
  expires_at: new Date(Date.now() + 10_000).toISOString(),
  ...over,
});

interface Harness {
  deps: OfferDeps;
  calls: string[];
}

const harness = (over: Partial<OfferDeps> = {}): Harness => {
  const calls: string[] = [];
  const deps: OfferDeps = {
    authenticate: (token) => {
      calls.push(`authenticate:${token}`);
      return Promise.resolve({ userId: 'd1', error: null });
    },
    readOffer: (offerId) => {
      calls.push(`readOffer:${offerId}`);
      return Promise.resolve({ row: offerRow(), error: null });
    },
    readTripState: (tripId) => {
      calls.push(`readTripState:${tripId}`);
      return Promise.resolve({ state: 'requested', error: null });
    },
    acceptOffer: (offerId) => {
      calls.push(`acceptOffer:${offerId}`);
      return Promise.resolve({
        rows: [{ accepted: true, trip_id: 't1', driver_id: 'd1' }],
        error: null,
      });
    },
    writeDecline: (offerId, driverId) => {
      calls.push(`writeDecline:${offerId}:${driverId}`);
      return Promise.resolve({ updated: 1, error: null });
    },
    ...over,
  };
  return { deps, calls };
};

const post = (body: unknown, init: { raw?: string; headers?: Record<string, string> } = {}) =>
  new Request('https://example.supabase.co/functions/v1/offers', {
    method: 'POST',
    headers: { Authorization: 'Bearer DRIVER-JWT', ...init.headers },
    body: init.raw ?? JSON.stringify(body),
  });

const call = async (body: unknown, over: Partial<OfferDeps> = {}, init: { raw?: string; headers?: Record<string, string> } = {}) => {
  const h = harness(over);
  const res = await handleOfferRequest(post(body, init), h.deps);
  return { res, calls: h.calls, body: await res.json() as Record<string, unknown> };
};

Deno.test('the accept path answers accepted, the trip and the winner', async () => {
  const { res, calls, body } = await call({ action: 'accept', offerId: OFFER_ID });
  assertEquals(res.status, 200);
  assertEquals(body, { accepted: true, tripId: 't1', winnerDriverId: 'd1' });
  // The identity is resolved from the caller's own token, the offer is read on
  // that token, the trip state is read for the classifier, and only then does
  // the accept go out. The write port is never touched on this path.
  assertEquals(calls, [
    'authenticate:DRIVER-JWT',
    `readOffer:${OFFER_ID}`,
    `readTripState:${TRIP_ID}`,
    `acceptOffer:${OFFER_ID}`,
  ]);
});

Deno.test("accepting another driver's offer is a 404 and never reaches the RPC", async () => {
  const { res, calls, body } = await call(
    { action: 'accept', offerId: OFFER_ID },
    { readOffer: () => Promise.resolve({ row: offerRow({ driver_id: 'd2' }), error: null }) },
  );
  assertEquals(res.status, 404);
  assertEquals(body, { accepted: false, reason: 'offer not found' });
  assertEquals(calls.filter((c) => c.startsWith('acceptOffer')), []);
});

Deno.test('accepting an offer that does not exist is a 404', async () => {
  const { res, calls } = await call(
    { action: 'accept', offerId: OFFER_ID },
    { readOffer: () => Promise.resolve({ row: null, error: null }) },
  );
  assertEquals(res.status, 404);
  assertEquals(calls.filter((c) => c.startsWith('acceptOffer')), []);
});

// Losing the race is the normal outcome of this function, not a fault. A
// handler that turns a `false` row into a 500 is what this pins: the RPC's
// refusal and its trip id are both reported, and the status stays 200.
Deno.test("a false from accept_offer is a 200, not a 500", async () => {
  const { res, body } = await call(
    { action: 'accept', offerId: OFFER_ID },
    { acceptOffer: () => Promise.resolve({ rows: [{ accepted: false, trip_id: 't1', driver_id: null }], error: null }) },
  );
  assertEquals(res.status, 200);
  assertEquals(body, { accepted: false, tripId: 't1', winnerDriverId: null });
});

// The RPC returns exactly one row however it went, including the unknown-id
// path (probe 10), so an empty array is a response this function does not
// understand. Reporting it as `accepted: false` would tell the driver they lost
// a race that the database never adjudicated.
Deno.test('an empty answer from accept_offer is a 500, not a lost race', async () => {
  const { res, body } = await call(
    { action: 'accept', offerId: OFFER_ID },
    { acceptOffer: () => Promise.resolve({ rows: [], error: null }) },
  );
  assertEquals(res.status, 500);
  assertEquals(body, { error: 'accept_offer returned no row' });
});

Deno.test('a non-boolean accepted is a 500, not a refusal passed through', async () => {
  const { res, body } = await call(
    { action: 'accept', offerId: OFFER_ID },
    { acceptOffer: () => Promise.resolve({ rows: [{ accepted: 'true', trip_id: 't1', driver_id: 'd1' }], error: null }) },
  );
  assertEquals(res.status, 500);
  assertEquals(body, { error: 'accept_offer returned a non-boolean accepted' });
});

Deno.test('an error from accept_offer is a 500 carrying the message', async () => {
  const { res, body } = await call(
    { action: 'accept', offerId: OFFER_ID },
    { acceptOffer: () => Promise.resolve({ rows: null, error: 'deadlock detected' }) },
  );
  assertEquals(res.status, 500);
  assertEquals(body, { error: 'deadlock detected' });
});

Deno.test('an error on the ownership read is a 500', async () => {
  const { res, body, calls } = await call(
    { action: 'accept', offerId: OFFER_ID },
    { readOffer: () => Promise.resolve({ row: null, error: 'permission denied for table offers' }) },
  );
  assertEquals(res.status, 500);
  assertEquals(body, { error: 'permission denied for table offers' });
  assertEquals(calls.filter((c) => c.startsWith('acceptOffer')), []);
});

// ---------------------------------------------------------------------------
// The accept classifier: refusals skip the RPC, a pass defers to it
// ---------------------------------------------------------------------------

// Each of the classifier's three refusals on an offer that is otherwise the
// caller's. The RPC is never called, and each answer carries the reason that
// applies rather than the blanket 404 the offer read used to produce.
Deno.test('a classified refusal answers its own reason and never reaches the RPC', async () => {
  const cases: [string, Record<string, unknown>, Record<string, unknown>, number][] = [
    [
      'offer already declined',
      { state: 'declined' },
      {},
      409,
    ],
    [
      'offer already accepted',
      { state: 'accepted' },
      {},
      409,
    ],
    [
      'offer already released',
      { state: 'released' },
      {},
      409,
    ],
    [
      'offer expired',
      { expires_at: new Date(Date.now() - 1000).toISOString() },
      {},
      409,
    ],
    [
      'trip is no longer awaiting a driver',
      {},
      { state: 'matched' },
      409,
    ],
  ];
  for (const [reason, offer, trip, status] of cases) {
    const { res, calls, body } = await call(
      { action: 'accept', offerId: OFFER_ID },
      {
        readOffer: () => Promise.resolve({ row: offerRow(offer), error: null }),
        readTripState: () =>
          Promise.resolve({ state: 'requested' as string | null, error: null, ...trip }),
      },
    );
    assertEquals(res.status, status, reason);
    assertEquals(body, { accepted: false, reason });
    // The whole point: a refusal the RPC would have made too is not paid for.
    assertEquals(calls.filter((c) => c.startsWith('acceptOffer')), [], reason);
  }
});

// Every one of the six trip states refuses, and a trip that is missing entirely
// refuses rather than crashing. `accept_offer` answers `false / NULL / NULL`
// for a missing trip (migration:330-334), so a null state is the safe direction.
Deno.test('a trip that has left requested is refused before the RPC', async () => {
  for (const state of ['matched', 'arriving', 'ongoing', 'completed', 'cancelled', null] as const) {
    const { res, calls, body } = await call(
      { action: 'accept', offerId: OFFER_ID },
      { readTripState: () => Promise.resolve({ state, error: null }) },
    );
    assertEquals(res.status, 409, `trip state ${state}`);
    assertEquals(body, { accepted: false, reason: 'trip is no longer awaiting a driver' });
    assertEquals(calls.filter((c) => c.startsWith('acceptOffer')), [], `trip state ${state}`);
  }
});

// The direction most likely to be got wrong. The classifier passed, so the RPC
// was called, and the RPC says the driver lost the race. The answer is the
// RPC's, verbatim: `accepted: false`. Nothing the classifier said may promote
// this to a win, and nothing it said may be reported to the driver as the
// outcome.
Deno.test('a pre-check pass whose RPC answers false is reported as false', async () => {
  const { res, body } = await call(
    { action: 'accept', offerId: OFFER_ID },
    {
      acceptOffer: () =>
        Promise.resolve({ rows: [{ accepted: false, trip_id: 't1', driver_id: null }], error: null }),
    },
  );
  assertEquals(res.status, 200);
  assertEquals(body, { accepted: false, tripId: 't1', winnerDriverId: null });
  assertEquals(body.accepted, false);
});

// The winner is the RPC's to name, not the classifier's. The two can differ: the
// classifier reads `offers.driver_id` before the call, and `accept_offer` re-reads
// the offer under the trip lock and returns that value (migration:381 and :403),
// so an offer reassigned in that window is matched to its *new* driver -- and the
// ownership re-check at migration:368 is what refuses that caller. Both ids are
// the caller's own here so the call is allowed to succeed, which is exactly the
// window the migration's own comment warns about. The handler must report the
// RPC's driver, so this pins it with the two ids deliberately different.
Deno.test('the winner is the RPC\'s driver, not the one the classifier read', async () => {
  const { res, body } = await call(
    { action: 'accept', offerId: OFFER_ID },
    {
      readOffer: () => Promise.resolve({ row: offerRow({ driver_id: 'd1' }), error: null }),
      acceptOffer: () =>
        Promise.resolve({ rows: [{ accepted: true, trip_id: 't1', driver_id: 'd2' }], error: null }),
    },
  );
  assertEquals(res.status, 200);
  assertEquals(body, { accepted: true, tripId: 't1', winnerDriverId: 'd2' });
});

// The mirror image, and the reason the pre-check exists at all: a refusal here
// is one the RPC agrees with, so the driver gets a reason instead of a bare
// false. This is the improvement over the old blanket 404.
Deno.test('a classified refusal replaces the blanket 404 with a specific reason', async () => {
  const { res, body } = await call(
    { action: 'accept', offerId: OFFER_ID },
    { readOffer: () => Promise.resolve({ row: offerRow({ state: 'expired' }), error: null }) },
  );
  assertEquals(res.status, 409);
  assertEquals(body.reason, 'offer already expired');
});

// The trip read is on the service client because the caller's bearer cannot get
// it, so a failure there is a 500 of its own and must not be reported as a lost
// race or a refusal.
Deno.test('an error on the trip state read is a 500 and never reaches the RPC', async () => {
  const { res, calls, body } = await call(
    { action: 'accept', offerId: OFFER_ID },
    { readTripState: () => Promise.resolve({ state: null, error: 'permission denied for table trips' }) },
  );
  assertEquals(res.status, 500);
  assertEquals(body, { error: 'permission denied for table trips' });
  assertEquals(calls.filter((c) => c.startsWith('acceptOffer')), []);
});

// An offer state the build does not name is not `pending`, so it refuses. A cast
// that were wrong has to fail this way and not the other one.
Deno.test('an offer state the build does not name is refused, not accepted', async () => {
  const { res, body, calls } = await call(
    { action: 'accept', offerId: OFFER_ID },
    { readOffer: () => Promise.resolve({ row: offerRow({ state: 'pendingish' }), error: null }) },
  );
  assertEquals(res.status, 409);
  assertEquals(body, { accepted: false, reason: 'offer already pendingish' });
  assertEquals(calls.filter((c) => c.startsWith('acceptOffer')), []);
});

Deno.test('the decline path answers declined and writes the row', async () => {
  const { res, calls, body } = await call({ action: 'decline', offerId: OFFER_ID });
  assertEquals(res.status, 200);
  assertEquals(body, { declined: true });
  assertEquals(calls, [
    'authenticate:DRIVER-JWT',
    `readOffer:${OFFER_ID}`,
    `writeDecline:${OFFER_ID}:d1`,
  ]);
});

Deno.test('declining an offer that does not exist is a 404 and writes nothing', async () => {
  const { res, calls, body } = await call(
    { action: 'decline', offerId: OFFER_ID },
    { readOffer: () => Promise.resolve({ row: null, error: null }) },
  );
  assertEquals(res.status, 404);
  assertEquals(body, { declined: false, reason: 'offer not found' });
  assertEquals(calls.filter((c) => c.startsWith('writeDecline')), []);
});

Deno.test("declining another driver's offer is a 404 and writes nothing", async () => {
  const { res, calls, body } = await call(
    { action: 'decline', offerId: OFFER_ID },
    { readOffer: () => Promise.resolve({ row: offerRow({ driver_id: 'd2' }), error: null }) },
  );
  assertEquals(res.status, 404);
  assertEquals(body, { declined: false, reason: 'offer not found' });
  // The write is filtered on driver_id as well, so it would have matched
  // nothing. It must not be attempted at all: the point of the read is to
  // establish the three invariants before a service-role write that bypasses
  // the policies which would otherwise have.
  assertEquals(calls.filter((c) => c.startsWith('writeDecline')), []);
});

Deno.test('declining an offer that is already terminal is a 409 and writes nothing', async () => {
  for (const state of ['accepted', 'declined', 'expired', 'released']) {
    const { res, calls, body } = await call(
      { action: 'decline', offerId: OFFER_ID },
      { readOffer: () => Promise.resolve({ row: offerRow({ state }), error: null }) },
    );
    assertEquals(res.status, 409, `state ${state} must be a 409`);
    assertEquals(body, { declined: false, reason: `offer is already ${state}` });
    assertEquals(calls.filter((c) => c.startsWith('writeDecline')), []);
  }
});

// The defect the whole decline path is built around. A rival accept or a second
// decline from the same driver takes the offer between the read and the write,
// the write matches nothing, and the client reports `error = null`. Answering
// `{declined: true}` here reports a state change that never happened.
Deno.test('a decline that matched zero rows is not reported as declined', async () => {
  const { res, body } = await call(
    { action: 'decline', offerId: OFFER_ID },
    { writeDecline: () => Promise.resolve({ updated: 0, error: null }) },
  );
  assertEquals(res.status, 409);
  assertEquals(body, { declined: false, reason: 'offer is no longer pending' });
});

Deno.test('an error on the decline write is a 500, not a decline', async () => {
  const { res, body } = await call(
    { action: 'decline', offerId: OFFER_ID },
    { writeDecline: () => Promise.resolve({ updated: 0, error: 'permission denied for table offers' }) },
  );
  assertEquals(res.status, 500);
  assertEquals(body, { error: 'permission denied for table offers' });
});

Deno.test('the write is scoped to the caller, not to the request body', async () => {
  // Nothing in the body names a driver, so the id the write is scoped to is the
  // one the token resolved to. A body carrying a `driverId` is ignored.
  const { calls } = await call({ action: 'decline', offerId: OFFER_ID, driverId: 'd2' as never });
  assertEquals(calls.at(-1), `writeDecline:${OFFER_ID}:d1`);
});

// A typo in the action, a missing action and an unknown action all reach the
// parser. Each must stop before any query, because under
// `body.action === 'decline'` every one of them would take the accept path and
// match the trip for a driver who never accepted.
Deno.test('a bad action is a 400 and no query runs at all', async () => {
  for (const body of [
    { action: 'Accept', offerId: OFFER_ID },
    { action: 'delete', offerId: OFFER_ID },
    { offerId: OFFER_ID },
    { action: 'accept' },
    {},
  ]) {
    const { res, calls } = await call(body);
    assertEquals(res.status, 400, `body ${JSON.stringify(body)} must be a 400`);
    assertEquals(calls, ['authenticate:DRIVER-JWT'], `body ${JSON.stringify(body)} must not query`);
  }
});

Deno.test('a body that is not JSON is a 400, not a bare 500', async () => {
  const { res, body } = await call(null, {}, { raw: '{action:' });
  assertEquals(res.status, 400);
  assertEquals(body, { error: 'body must be JSON' });
});

Deno.test('a request with no bearer is a 401 before anything is read', async () => {
  const h = harness();
  const res = await handleOfferRequest(
    new Request('https://example.supabase.co/functions/v1/offers', { method: 'POST' }),
    h.deps,
  );
  assertEquals(res.status, 401);
  assertEquals(await res.json(), { error: 'unauthenticated' });
  assertEquals(h.calls, []);
});

// `getUser` answers a revoked or malformed token with a null user *and* an
// error. Checking only `!user` would let a future version that returns one
// without the other through, so both are pinned.
Deno.test('a token that resolves to no user is a 401', async () => {
  for (
    const outcome of [
      { userId: null, error: null },
      { userId: null, error: 'invalid claim: missing sub claim' },
      { userId: null, error: 'User from sub claim in JWT does not exist' },
      // A user *and* an error. `getUser` does not answer this way today, but a
      // check on `!userId` alone would let it through and treat an
      // authentication that reported a failure as an identity.
      { userId: 'd1', error: 'Auth session missing!' },
    ]
  ) {
    const calls: string[] = [];
    const h = harness({
      authenticate: (token) => {
        calls.push(`authenticate:${token}`);
        return Promise.resolve(outcome);
      },
    });
    const res = await handleOfferRequest(
      post({ action: 'accept', offerId: OFFER_ID }),
      h.deps,
    );
    assertEquals(res.status, 401, JSON.stringify(outcome));
    assertEquals(await res.json(), { error: 'unauthenticated' });
    // The identity is resolved and then nothing else runs: no read, no RPC, no
    // write. The override replaced the recording `authenticate`, so this
    // recorder sees the call above and nothing else.
    assertEquals(calls, ['authenticate:DRIVER-JWT']);
  }
});

Deno.test('a bare token with no Bearer prefix is still a credential', async () => {
  const h = harness();
  await handleOfferRequest(
    new Request('https://example.supabase.co/functions/v1/offers', {
      method: 'POST',
      headers: { Authorization: 'DRIVER-JWT' },
      body: JSON.stringify({ action: 'decline', offerId: OFFER_ID }),
    }),
    h.deps,
  );
  assertEquals(h.calls[0], 'authenticate:DRIVER-JWT');
});

Deno.test('a preflight is answered without a token', async () => {
  const h = harness();
  const res = await handleOfferRequest(
    new Request('https://example.supabase.co/functions/v1/offers', { method: 'OPTIONS' }),
    h.deps,
  );
  assertEquals(res.status, 200);
  assertEquals(await res.text(), 'ok');
  assertEquals(res.headers.get('Access-Control-Allow-Origin'), '*');
  assertEquals(h.calls, []);
});

// Every response carries the CORS headers and the JSON content type, so the
// Flutter client can read a refusal rather than failing to parse it.
Deno.test('every response is JSON with the CORS headers', async () => {
  const cases: [unknown, Partial<OfferDeps>][] = [
    [{ action: 'accept', offerId: OFFER_ID }, {}],
    [{ action: 'decline', offerId: OFFER_ID }, {}],
    [{ action: 'nope', offerId: OFFER_ID }, {}],
    [{ action: 'decline', offerId: OFFER_ID }, { readOffer: () => Promise.resolve({ row: null, error: null }) }],
  ];
  for (const [body, over] of cases) {
    const { res } = await call(body, over);
    assertEquals(res.headers.get('Content-Type'), 'application/json', JSON.stringify(body));
    assertEquals(res.headers.get('Access-Control-Allow-Origin'), '*', JSON.stringify(body));
  }
});
