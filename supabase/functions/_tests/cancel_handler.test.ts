import { assertEquals } from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import {
  elapsedSinceCommit,
  handleCancel,
  type CancelDeps,
  type TripRow,
} from '../cancel-trip/handler.ts';

const MINUTE = 60 * 1000;

// Every port is a recording fake, so a test can see what the handler *asked for*
// and not only what it answered. Nothing here opens a socket or reads an
// environment variable, which is the whole reason the handler was split out of
// `index.ts`: with `serve()` at module scope the file could not be imported
// without starting a server, and these six behaviours had no test at all.
interface Recorder {
  authenticated: string[];
  read: string[];
  writes: { tripId: string; fromState: string; cancelledAt: string }[];
  releasedDrivers: string[];
  releasedOffers: string[];
  compensations: { driverId: string; tripId: string; amountGhs: number }[];
}

interface Options {
  row?: TripRow | null;
  readError?: string | null;
  userId?: string | null;
  authError?: string | null;
  writeRow?: TripRow | null;
  writeError?: string | null;
  driverError?: string | null;
  offerError?: string | null;
  ledgerError?: string | null;
}

const row = (over: Partial<TripRow> = {}): TripRow => ({
  id: 'trip-1',
  rider_id: 'rider-1',
  driver_id: 'driver-1',
  state: 'arriving',
  created_at: new Date(Date.now() - 30 * MINUTE).toISOString(),
  matched_at: new Date(Date.now() - 6 * MINUTE).toISOString(),
  fare_ghs: 12.5,
  ...over,
});

const harness = (options: Options = {}) => {
  const calls: Recorder = {
    authenticated: [],
    read: [],
    writes: [],
    releasedDrivers: [],
    releasedOffers: [],
    compensations: [],
  };
  // `Promise.resolve` rather than `async`: the ports are declared as returning a
  // Promise, and an `async` arrow with no `await` in it is a `require-await`
  // lint error.
  const deps: CancelDeps = {
    authenticate: (token) => {
      calls.authenticated.push(token);
      return Promise.resolve({
        userId: options.userId === undefined ? 'rider-1' : options.userId,
        error: options.authError ?? null,
      });
    },
    readTrip: (tripId) => {
      calls.read.push(tripId);
      return Promise.resolve({
        row: 'row' in options ? options.row ?? null : row(),
        error: options.readError ?? null,
      });
    },
    writeCancel: (tripId, fromState, cancelledAt) => {
      calls.writes.push({ tripId, fromState, cancelledAt });
      const written = options.writeRow === undefined
        ? row({ state: 'cancelled', cancelled_at: cancelledAt })
        : options.writeRow;
      return Promise.resolve({ row: written, error: options.writeError ?? null });
    },
    releaseDriver: (driverId) => {
      calls.releasedDrivers.push(driverId);
      return Promise.resolve({ error: options.driverError ?? null });
    },
    releaseOffers: (tripId) => {
      calls.releasedOffers.push(tripId);
      return Promise.resolve({ error: options.offerError ?? null });
    },
    recordCompensation: (input) => {
      calls.compensations.push(input);
      return Promise.resolve({ error: options.ledgerError ?? null });
    },
  };
  return { deps, calls };
};

const request = (body: unknown = { tripId: 'trip-1' }) =>
  new Request('https://fn.test/cancel-trip', {
    method: 'POST',
    headers: { Authorization: 'Bearer rider-jwt' },
    body: JSON.stringify(body),
  });

const body = async (res: Response) => await res.json() as Record<string, unknown>;

// --- the state guard -------------------------------------------------------

Deno.test('a trip row whose state this build does not know is refused, not cancelled', async () => {
  const { deps, calls } = harness({ row: row({ state: 'expired' }) });
  const res = await handleCancel(request(), deps);
  assertEquals(res.status, 500);
  assertEquals(
    (await body(res)).error,
    'trip row carries a state this build does not know',
  );
  assertEquals(calls.writes.length, 0);
  assertEquals(calls.compensations.length, 0);
});

// The 500 and the message are what show the *guard* is the thing refusing. The
// policy function would also have refused this state -- its `default` arm returns
// -1 -- so a 409 here would have meant the guard was missing and the fail-closed
// default caught it, and the compensation would still have been avoided by luck
// rather than by the check.

// --- the row-count refusal -------------------------------------------------

Deno.test('a cancel write that matches no row is a 409, not a cancellation', async () => {
  // A lost race: a second cancel, or the driver's own app advancing the state,
  // matches nothing. `writeRow: null` is the zero-row read.
  const { deps, calls } = harness({ writeRow: null });
  const res = await handleCancel(request(), deps);
  assertEquals(res.status, 409);
  assertEquals((await body(res)).cancelled, false);
  // Nothing behind the trip write may run: the state this handler refused to
  // change is the one the driver is still attached to.
  assertEquals(calls.releasedDrivers.length, 0);
  assertEquals(calls.releasedOffers.length, 0);
  assertEquals(calls.compensations.length, 0);
});

Deno.test('a failed cancel write is a 500, not a cancellation', async () => {
  const { deps } = harness({ writeError: 'deadlock detected' });
  const res = await handleCancel(request(), deps);
  assertEquals(res.status, 500);
  assertEquals((await body(res)).error, 'deadlock detected');
});

Deno.test('a failed cancel write is not reported to the rider as cancelled', async () => {
  const { deps } = harness({ writeError: 'permission denied' });
  const res = await handleCancel(request(), deps);
  const payload = await body(res);
  assertEquals(payload.cancelled, undefined);
  assertEquals(payload.trip, undefined);
});

// --- the 409 carries an `error` key ---------------------------------------

Deno.test('the 409 refusal body carries the error key the rider app reads', async () => {
  // `describeFunctionFailure` reads `details['error']`. A 409 without it reads
  // `Something went wrong (409)` on a screen where the rider can act.
  for (const options of [{ writeRow: null }, { row: row({ state: 'ongoing' }) }]) {
    const { deps } = harness(options);
    const res = await handleCancel(request(), deps);
    assertEquals(res.status, 409);
    const payload = await body(res);
    assertEquals(payload.error, 'This trip can no longer be cancelled');
    assertEquals(payload.cancelled, false);
  }
});

Deno.test('the 409 refusal is the answer for every state that is not cancellable', async () => {
  for (const state of ['ongoing', 'completed', 'cancelled']) {
    const { deps, calls } = harness({ row: row({ state }) });
    const res = await handleCancel(request(), deps);
    assertEquals(res.status, 409, state);
    assertEquals((await body(res)).compensatedGhs, -1, state);
    assertEquals(calls.writes.length, 0, state);
  }
});

// --- the three checked writes behind the trip write -----------------------

Deno.test('a failed driver release is a 500 that names the step', async () => {
  const { deps, calls } = harness({ driverError: 'profiles is locked' });
  const res = await handleCancel(request(), deps);
  assertEquals(res.status, 500);
  assertEquals(
    (await body(res)).error,
    'the trip was cancelled but the driver was not released: profiles is locked',
  );
  // The trip is already cancelled, so the offer release and the compensation
  // must not be recorded as though the whole chain had been refused.
  assertEquals(calls.writes.length, 1);
  assertEquals(calls.releasedOffers.length, 0);
  assertEquals(calls.compensations.length, 0);
});

Deno.test('a failed offer release is a 500 that names the step', async () => {
  const { deps, calls } = harness({ offerError: 'offers is locked' });
  const res = await handleCancel(request(), deps);
  assertEquals(res.status, 500);
  assertEquals(
    (await body(res)).error,
    'the trip was cancelled but its pending offers were not released: offers is locked',
  );
  assertEquals(calls.writes.length, 1);
  assertEquals(calls.compensations.length, 0);
});

Deno.test('a failed compensation insert is a 500 that names the step', async () => {
  const { deps } = harness({ ledgerError: 'ledger_entries is locked' });
  const res = await handleCancel(request(), deps);
  assertEquals(res.status, 500);
  assertEquals(
    (await body(res)).error,
    "the trip was cancelled but the driver's compensation was not recorded: ledger_entries is locked",
  );
});

Deno.test('a trip with no driver releases nobody and records no compensation', async () => {
  const { deps, calls } = harness({ row: row({ driver_id: null, state: 'requested' }) });
  const res = await handleCancel(request(), deps);
  assertEquals(res.status, 200);
  assertEquals(calls.releasedDrivers.length, 0);
  assertEquals(calls.releasedOffers.length, 0);
  assertEquals(calls.compensations.length, 0);
});

// --- cancelled_at and the 200 body ----------------------------------------

Deno.test('the cancel write sets cancelled_at to an ISO instant', async () => {
  const { deps, calls } = harness();
  await handleCancel(request(), deps);
  assertEquals(calls.writes.length, 1);
  const { cancelledAt } = calls.writes[0];
  assertEquals(new Date(cancelledAt).toISOString(), cancelledAt);
});

Deno.test('the 200 body carries the cancelled_at that was written, not the pre-update null', async () => {
  const { deps, calls } = harness();
  const res = await handleCancel(request(), deps);
  assertEquals(res.status, 200);
  const payload = await body(res);
  const trip = payload.trip as Record<string, unknown>;
  assertEquals(trip.cancelled_at, calls.writes[0].cancelledAt);
  assertEquals(trip.state, 'cancelled');
  assertEquals(payload.cancelled, true);
});

Deno.test('the 200 body reports the compensation the policy function decided', async () => {
  const { deps, calls } = harness();
  const res = await handleCancel(request(), deps);
  // `arriving`, six minutes past `matched_at`: past the two-minute window.
  assertEquals((await body(res)).compensatedGhs, 5.0);
  assertEquals(calls.compensations, [{
    driverId: 'driver-1',
    tripId: 'trip-1',
    amountGhs: 5.0,
  }]);
});

Deno.test('a free cancel records no compensation row', async () => {
  const { deps, calls } = harness({
    row: row({
      state: 'matched',
      matched_at: new Date(Date.now() - 30_000).toISOString(),
    }),
  });
  const res = await handleCancel(request(), deps);
  assertEquals((await body(res)).compensatedGhs, 0);
  assertEquals(calls.compensations.length, 0);
  assertEquals(calls.releasedDrivers, ['driver-1']);
  assertEquals(calls.releasedOffers, ['trip-1']);
});

Deno.test('the write is filtered by the state it read, so the cancel is single-winner', async () => {
  const { deps, calls } = harness();
  await handleCancel(request(), deps);
  assertEquals(calls.writes, [{
    tripId: 'trip-1',
    fromState: 'arriving',
    cancelledAt: calls.writes[0].cancelledAt,
  }]);
});

// --- the elapsed-since-commit helper --------------------------------------

Deno.test('an unparseable timestamp is not read as past the free window', () => {
  // `NaN <= 120_000` is false, so without the guard a junk `matched_at` pays the
  // driver. This is the whole reason `elapsedSinceCommit` returns 0 for it.
  assertEquals(elapsedSinceCommit('junk', new Date().toISOString()), 0);
  assertEquals(elapsedSinceCommit(null, 'also junk'), 0);
  assertEquals(
    elapsedSinceCommit(null, new Date(Date.now() - MINUTE).toISOString()) >= 30_000,
    true,
  );
});

// --- routing, ownership and the body --------------------------------------

Deno.test('a request with no bearer is refused before any port is called', async () => {
  const { deps, calls } = harness();
  const res = await handleCancel(
    new Request('https://fn.test/cancel-trip', { method: 'POST', body: '{}' }),
    deps,
  );
  assertEquals(res.status, 401);
  assertEquals((await body(res)).error, 'unauthenticated');
  assertEquals(calls.read.length, 0);
});

Deno.test('the token is stripped of its Bearer prefix before it is authenticated', async () => {
  const { deps, calls } = harness();
  await handleCancel(request(), deps);
  assertEquals(calls.authenticated, ['rider-jwt']);
});

Deno.test('a token the auth server refuses is a 401', async () => {
  const { deps, calls } = harness({ userId: null, authError: 'invalid JWT' });
  const res = await handleCancel(request(), deps);
  assertEquals(res.status, 401);
  assertEquals(calls.read.length, 0);
});

Deno.test('another rider trip is a 403 and is never read into a response', async () => {
  const { deps, calls } = harness({ row: row({ rider_id: 'somebody-else' }) });
  const res = await handleCancel(request(), deps);
  assertEquals(res.status, 403);
  assertEquals((await body(res)).error, 'not your trip');
  assertEquals(calls.writes.length, 0);
});

Deno.test('a missing trip is a 404 and a failed read is a 500', async () => {
  const missing = harness({ row: null });
  assertEquals((await handleCancel(request(), missing.deps)).status, 404);

  const failed = harness({ readError: 'connection reset' });
  const res = await handleCancel(request(), failed.deps);
  assertEquals(res.status, 500);
  assertEquals((await body(res)).error, 'connection reset');
});

Deno.test('a body that is not JSON and a body with no tripId are both 400', async () => {
  const { deps } = harness();
  const malformed = await handleCancel(
    new Request('https://fn.test/cancel-trip', {
      method: 'POST',
      headers: { Authorization: 'Bearer rider-jwt' },
      body: 'not json',
    }),
    deps,
  );
  assertEquals(malformed.status, 400);
  assertEquals((await body(malformed)).error, 'body must be JSON');

  for (const payload of [{}, { tripId: '' }, { tripId: 7 }, null]) {
    const res = await handleCancel(request(payload), deps);
    assertEquals(res.status, 400, JSON.stringify(payload));
    assertEquals((await body(res)).error, 'tripId is required');
  }
});

Deno.test('an OPTIONS preflight answers ok with the CORS headers', async () => {
  const { deps, calls } = harness();
  const res = await handleCancel(
    new Request('https://fn.test/cancel-trip', { method: 'OPTIONS' }),
    deps,
  );
  assertEquals(res.status, 200);
  assertEquals(res.headers.get('Access-Control-Allow-Origin'), '*');
  assertEquals(calls.authenticated.length, 0);
});

Deno.test('every error body is JSON, which is what functions_client decodes', async () => {
  const { deps } = harness({ row: row({ state: 'ongoing' }) });
  const res = await handleCancel(request(), deps);
  assertEquals(res.headers.get('Content-Type'), 'application/json');
  assertEquals(typeof (await body(res)).error, 'string');
});
