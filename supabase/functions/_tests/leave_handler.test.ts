import { assertEquals } from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import {
  handleLeave,
  isTripStateName,
  refusalFor,
  WITHDRAWABLE_STATE,
  type LeaveDeps,
  type LeaveTripRow,
} from '../leave-trip/handler.ts';

// Every port is a recording fake, so a test can see what the handler *asked for*
// and not only what it answered. Nothing here opens a socket or reads an
// environment variable, which is the reason the handler is split out of
// `index.ts`: with `serve()` at module scope the file could not be imported
// without starting a server, and these rules would have no test at all.
//
// The rule that matters most -- a driver may not withdraw once the rider is in the
// car -- has no user-visible failure when it is wrong. The trip moves to
// `requested`, the rider goes back in the pool, and nobody reports it; the driver
// has stranded a passenger and the app said it was fine. So it is pinned here and
// again against the deployed function in `toolchain/verify-leave-trip.mjs`.

interface Recorder {
  authenticated: string[];
  read: string[];
  withdrawals: { tripId: string; driverId: string; reason: string }[];
  returns: { tripId: string; fromState: string }[];
  releasedDrivers: string[];
  releasedOffers: string[];
}

interface Options {
  row?: LeaveTripRow | null;
  readError?: string | null;
  userId?: string | null;
  authError?: string | null;
  writeRow?: LeaveTripRow | null;
  writeError?: string | null;
  withdrawalError?: string | null;
  priorWithdrawal?: boolean;
  withdrawalLookupError?: string | null;
}

const row = (over: Partial<LeaveTripRow> = {}): LeaveTripRow => ({
  id: '11111111-1111-1111-1111-111111111111',
  rider_id: 'rider-1',
  driver_id: 'driver-1',
  state: 'arriving',
  ...over,
});

function fake(o: Options = {}): { deps: LeaveDeps; log: Recorder } {
  const log: Recorder = {
    authenticated: [],
    read: [],
    withdrawals: [],
    returns: [],
    releasedDrivers: [],
    releasedOffers: [],
  };
  const current = o.row === undefined ? row() : o.row;
  const deps: LeaveDeps = {
    authenticate: async (token) => {
      log.authenticated.push(token);
      return {
        userId: o.userId === undefined ? 'driver-1' : o.userId,
        error: o.authError ?? null,
      };
    },
    readTrip: async (tripId) => {
      log.read.push(tripId);
      return { row: current, error: o.readError ?? null };
    },
    returnToRequested: async (tripId, fromState) => {
      log.returns.push({ tripId, fromState });
      // A conditional update that matched no row answers null, not an error, and
      // the handler has to tell those apart.
      const result = o.writeRow === undefined ? row({ state: 'requested' }) : o.writeRow;
      return { row: result, error: o.writeError ?? null };
    },
    recordWithdrawal: async (tripId, driverId, reason) => {
      log.withdrawals.push({ tripId, driverId, reason });
      return { error: o.withdrawalError ?? null };
    },
    hasWithdrawn: async () => ({
      row: o.priorWithdrawal ?? false,
      error: o.withdrawalLookupError ?? null,
    }),
    releaseDriver: async (driverId) => {
      log.releasedDrivers.push(driverId);
      return { error: null };
    },
    releaseOffers: async (tripId) => {
      log.releasedOffers.push(tripId);
      return { error: null };
    },
  };
  return { deps, log };
}

const post = (body: unknown, token = 'tok'): Request =>
  new Request('https://x/leave-trip', {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });

const TRIP = '11111111-1111-1111-1111-111111111111';

async function status(res: Response): Promise<number> {
  return res.status;
}

// ---------------------------------------------------------------- the rules

Deno.test('the only withdrawable state is arriving', () => {
  assertEquals(WITHDRAWABLE_STATE, 'arriving');
  assertEquals(refusalFor('arriving'), null);
});

Deno.test('ongoing is refused, and the reason names the rider', () => {
  // The one that matters. `ongoing` means somebody is in the vehicle, and
  // "leaving" is stranding them.
  const why = refusalFor('ongoing');
  assertEquals(why === null, false);
  assertEquals(String(why).includes('in the car'), true);
});

Deno.test('matched points at the control that does apply', () => {
  // Not merely "no". A driver with an offer they have not accepted needs to be
  // told there is another button.
  assertEquals(String(refusalFor('matched')).includes('Decline the offer'), true);
  assertEquals(String(refusalFor('requested')).includes('Decline the offer'), true);
});

Deno.test('every state is either withdrawable or has a real reason', () => {
  for (const state of [
    'requested',
    'matched',
    'arriving',
    'ongoing',
    'completed',
    'cancelled',
  ]) {
    assertEquals(isTripStateName(state), true, state);
    const why = refusalFor(state);
    if (state === 'arriving') {
      assertEquals(why, null, 'the one withdrawable state has no refusal');
    } else {
      // A non-empty sentence, not an empty string. An empty reason renders as a
      // disabled button with nothing to explain it, which is what this started as.
      assertEquals(typeof why === 'string' && why.length > 0, true, state);
    }
  }
});

Deno.test('an unknown state is refused rather than guessed at', () => {
  // A state this build has never heard of must not fall through to "allowed".
  assertEquals(isTripStateName('teleporting'), false);
  assertEquals(refusalFor('teleporting') === null, false);
});

// ------------------------------------------------------------- the handler

Deno.test('a driver withdraws while arriving', async () => {
  const { deps, log } = fake();
  const res = await handleLeave(
    post({ tripId: TRIP, reason: 'rider_absent' }),
    deps,
  );
  assertEquals(await status(res), 200);
  assertEquals(log.withdrawals.length, 1);
  assertEquals(log.withdrawals[0].reason, 'rider_absent');
  assertEquals(log.releasedDrivers, ['driver-1']);
  assertEquals(log.releasedOffers, [TRIP]);
});

Deno.test('the trip goes back to requested, from the state it was in', async () => {
  const { deps, log } = fake();
  await handleLeave(post({ tripId: TRIP }), deps);
  // Conditional on `fromState`, so two presses cannot both believe they won.
  assertEquals(log.returns[0].fromState, 'arriving');
});

Deno.test('a driver cannot withdraw while the rider is in the car', async () => {
  const { deps, log } = fake({ row: row({ state: 'ongoing' }) });
  const res = await handleLeave(post({ tripId: TRIP }), deps);
  // 409 and not 403: the caller is who they say, the request is well-formed, and
  // the trip is in a state that cannot be left.
  assertEquals(await status(res), 409);
  assertEquals(log.withdrawals, []);
  assertEquals(log.returns, []);
});

Deno.test('the rider cannot use this to cancel', async () => {
  // Cancellation has its own rules and its own money attached; it is a different
  // function and a different set of numbers.
  const { deps, log } = fake({ userId: 'rider-1' });
  const res = await handleLeave(post({ tripId: TRIP }), deps);
  assertEquals(await status(res), 403);
  assertEquals(log.withdrawals, []);
});

Deno.test('a second press is a success, not "not your trip"', async () => {
  // The trip after a successful withdrawal: the driver has been cleared, so the
  // ownership check would refuse a driver standing on the very screen that cleared
  // them. The end state they asked for is the state the row is already in.
  const { deps, log } = fake({
    row: row({ driver_id: null, state: 'requested' }),
    priorWithdrawal: true,
  });
  const res = await handleLeave(post({ tripId: TRIP }), deps);
  assertEquals(await status(res), 200);
  const body = await res.json();
  assertEquals(body.alreadyLeft, true);
  // Nothing was written twice.
  assertEquals(log.withdrawals, []);
  assertEquals(log.returns, []);
});

Deno.test('a released trip is still refused to a stranger', async () => {
  // The exemption above is for a driver who withdrew. It must not become a way for
  // anybody else to walk away with a 200 on somebody else's trip.
  const { deps, log } = fake({
    row: row({ driver_id: null, state: 'requested' }),
    userId: 'stranger',
    priorWithdrawal: false,
  });
  const res = await handleLeave(post({ tripId: TRIP }), deps);
  assertEquals(await status(res), 403);
  assertEquals(log.withdrawals, []);
});

Deno.test('a half-finished withdrawal is not treated as a second press', async () => {
  // The withdrawal is recorded before the state moves. A row with the driver still
  // assigned means a previous attempt got that far and failed -- this driver is
  // still driving to the pickup and must be allowed to try again, not told they
  // already left.
  const { deps, log } = fake({
    row: row({ state: 'arriving' }),
    priorWithdrawal: true,
  });
  const res = await handleLeave(post({ tripId: TRIP, reason: 'rider_absent' }), deps);
  assertEquals(await status(res), 200);
  assertEquals(log.withdrawals.length, 1);
  assertEquals(log.returns.length, 1);
});

Deno.test('an unauthenticated call is refused before anything is read', async () => {
  const { deps, log } = fake({ authError: 'bad token' });
  const res = await handleLeave(post({ tripId: TRIP }), deps);
  assertEquals(await status(res), 401);
  assertEquals(log.read, []);
});

Deno.test('a missing token is refused', async () => {
  const { deps, log } = fake();
  const res = await handleLeave(
    new Request('https://x/leave-trip', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ tripId: TRIP }),
    }),
    deps,
  );
  assertEquals(await status(res), 401);
  assertEquals(log.authenticated, []);
});

Deno.test('a malformed tripId is refused before the database is asked', async () => {
  const { deps, log } = fake();
  const res = await handleLeave(post({ tripId: 'not-a-uuid' }), deps);
  assertEquals(await status(res), 400);
  // Postgres answers a malformed uuid with 22P02 that says less about what went
  // wrong than this does.
  assertEquals(log.read, []);
});

Deno.test('an unknown trip is a 404', async () => {
  const { deps, log } = fake({ row: null });
  const res = await handleLeave(post({ tripId: TRIP }), deps);
  assertEquals(await status(res), 404);
  assertEquals(log.withdrawals, []);
});

Deno.test('the withdrawal is recorded before the state moves', async () => {
  // The ordering is the design. If the state change fails the driver is still on a
  // trip they have said they are leaving and the app can offer a retry. If the
  // recording failed after the state moved, the trip would be back in the pool
  // with a driver who has no memory of declining it.
  const order: string[] = [];
  const { deps } = fake();
  const wrapped: LeaveDeps = {
    ...deps,
    // Annotated explicitly, because spreading `deps` into an object literal
    // discards the contextual type and Deno's checker has no idea what these
    // three parameters are. `deno test` type-checks, so this is a compile error
    // rather than a warning.
    recordWithdrawal: async (t: string, d: string, r: string) => {
      order.push('record');
      return deps.recordWithdrawal(t, d, r);
    },
    returnToRequested: async (t: string, s: string) => {
      order.push('state');
      return deps.returnToRequested(t, s);
    },
  };
  await handleLeave(post({ tripId: TRIP }), wrapped);
  assertEquals(order, ['record', 'state']);
});

Deno.test('a failed recording stops the withdrawal, and nothing moves', async () => {
  const { deps, log } = fake({ withdrawalError: 'no' });
  const res = await handleLeave(post({ tripId: TRIP }), deps);
  assertEquals(await status(res), 500);
  // The trip has not moved, so the driver is still on it and can try again.
  assertEquals(log.returns, []);
});

Deno.test('a conditional update that matched nothing is a conflict', async () => {
  // Something changed the trip between the read and the write -- the rider
  // cancelled, or a second press won the race. Reporting success here would tell
  // a driver they are free while the row says otherwise.
  const { deps, log } = fake({ writeRow: null });
  const res = await handleLeave(post({ tripId: TRIP }), deps);
  assertEquals(await status(res), 409);
  assertEquals(log.releasedDrivers, [], 'and it does not pretend to have released them');
});

Deno.test('a long reason is truncated, not refused', async () => {
  // A driver writing more than 300 characters about a pickup is telling staff
  // something useful. Refusing it over the character count is pedantry.
  const { deps, log } = fake();
  await handleLeave(post({ tripId: TRIP, reason: 'x'.repeat(900) }), deps);
  assertEquals(log.withdrawals[0].reason.length, 300);
});

Deno.test('a missing reason is allowed', async () => {
  const { deps, log } = fake();
  const res = await handleLeave(post({ tripId: TRIP }), deps);
  assertEquals(await status(res), 200);
  assertEquals(log.withdrawals[0].reason, '');
});

Deno.test('a non-POST method is refused', async () => {
  const { deps } = fake();
  const res = await handleLeave(
    new Request('https://x/leave-trip', { method: 'GET' }),
    deps,
  );
  assertEquals(await status(res), 405);
});

Deno.test('a preflight is answered', async () => {
  const { deps } = fake();
  const res = await handleLeave(
    new Request('https://x/leave-trip', { method: 'OPTIONS' }),
    deps,
  );
  assertEquals(await status(res), 200);
});

Deno.test('a body that is not json is refused', async () => {
  const { deps, log } = fake();
  const res = await handleLeave(
    new Request('https://x/leave-trip', {
      method: 'POST',
      headers: { Authorization: 'Bearer tok', 'Content-Type': 'application/json' },
      body: 'not json',
    }),
    deps,
  );
  assertEquals(await status(res), 400);
  assertEquals(log.read, []);
});