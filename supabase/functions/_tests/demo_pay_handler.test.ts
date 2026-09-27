import { assertEquals } from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import type { PaymentRow, TripRow } from '../complete-trip/handler.ts';
import { handleDemoPay, type DemoPayDeps, type PaymentInput } from '../demo-pay/handler.ts';

// Every port is a recording fake, so a test can see what the handler *asked for*
// and not only what it answered. Nothing here opens a socket or reads an
// environment variable, which is the whole reason the handler was split out of
// `index.ts`: with `serve()` at module scope the file could not be imported
// without starting a server.

interface Calls {
  authenticated: string[];
  tripsRead: string[];
  paymentsRead: { tripId: string; payerId: string }[];
  created: PaymentInput[];
}

interface Options {
  row?: TripRow | null;
  tripError?: string | null;
  userId?: string | null;
  open?: PaymentRow | null;
  openError?: string | null;
  created?: PaymentRow | null;
  createError?: string | null;
}

const row = (over: Partial<TripRow> = {}): TripRow => ({
  id: 'trip-1',
  rider_id: 'rider-1',
  driver_id: 'driver-1',
  state: 'arriving',
  fare_ghs: 20.4,
  ...over,
});

const payment = (over: Partial<PaymentRow> = {}): PaymentRow => ({
  id: 'pay-1',
  trip_id: 'trip-1',
  payer_id: 'rider-1',
  amount_ghs: 20.4,
  method: 'momo',
  state: 'pending',
  ...over,
});

const harness = (options: Options = {}) => {
  const calls: Calls = {
    authenticated: [],
    tripsRead: [],
    paymentsRead: [],
    created: [],
  };
  // `Promise.resolve` rather than `async`: the ports are declared as returning a
  // Promise, and an `async` arrow with no `await` in it is a `require-await`
  // lint error.
  const deps: DemoPayDeps = {
    authenticate: (token) => {
      calls.authenticated.push(token);
      return Promise.resolve({
        userId: options.userId === undefined ? 'rider-1' : options.userId,
        // `error` is declared by the port and never set here, because no
        // code path in this handler reads it: the 401 is `callerId` being null.
        error: null,
      });
    },
    findTrip: (tripId) => {
      calls.tripsRead.push(tripId);
      return Promise.resolve({
        row: 'row' in options ? options.row ?? null : row(),
        error: options.tripError ?? null,
      });
    },
    findOpenPayment: (tripId, payerId) => {
      calls.paymentsRead.push({ tripId, payerId });
      return Promise.resolve({
        row: 'open' in options ? options.open ?? null : null,
        error: options.openError ?? null,
      });
    },
    createPayment: (input) => {
      calls.created.push(input);
      return Promise.resolve({
        row: options.created === undefined
          ? payment({ id: 'pay-new', method: input.method })
          : options.created,
        error: options.createError ?? null,
      });
    },
  };
  return { deps, calls };
};

const call = (
  options: Options = {},
  overrides: { callerId?: string | null; method?: string; tripId?: string } = {},
) => {
  const { deps, calls } = harness(options);
  const promise = handleDemoPay({
    deps,
    callerId: overrides.callerId === undefined ? 'rider-1' : overrides.callerId,
    tripId: overrides.tripId ?? 'trip-1',
    method: overrides.method === undefined ? 'momo' : overrides.method,
  });
  return { promise, calls, deps };
};

const body = async (res: Response) => await res.json() as Record<string, unknown>;

// --- the refusal ladder ---------------------------------------------------

Deno.test('a caller with no identity is a 401 before any port is called', async () => {
  const { promise, calls } = call({}, { callerId: null });
  const res = await promise;
  assertEquals(res.status, 401);
  assertEquals((await body(res)).error, 'unauthenticated');
  assertEquals(calls.tripsRead.length, 0);
});

Deno.test('a method outside momo, cash and card is a 400 and reads nothing', async () => {
  // `pay_method` is a three-value enum (`init.sql:9`). The set is checked here
  // rather than left to the insert, so the refusal names the field.
  for (const method of ['cash', 'momo', 'card', 'mobile_money', 'MOMO', '', 'cash ']) {
    const { promise, calls } = call({}, { method });
    const res = await promise;
    if (['cash', 'momo', 'card'].includes(method)) {
      assertEquals(res.status, 200, method);
      assertEquals(calls.created[0].method, method, method);
      continue;
    }
    assertEquals(res.status, 400, method);
    assertEquals((await body(res)).error, 'unsupported method', method);
    assertEquals(calls.tripsRead.length, 0, method);
    assertEquals(calls.created.length, 0, method);
  }
});

Deno.test("another rider's trip is a 404 and a missing trip is the same 404", async () => {
  const stranger = call({ row: row({ rider_id: 'somebody-else' }) });
  const notYours = await stranger.promise;
  assertEquals(notYours.status, 404);
  assertEquals((await body(notYours)).error, 'not your trip');
  assertEquals(stranger.calls.created.length, 0);

  const missing = call({ row: null });
  const gone = await missing.promise;
  assertEquals(gone.status, 404);
  assertEquals(missing.calls.created.length, 0);
});

Deno.test('a failed trip read is a 500 and writes nothing', async () => {
  const { promise, calls } = call({ tripError: 'connection reset' });
  const res = await promise;
  assertEquals(res.status, 500);
  assertEquals((await body(res)).error, 'trip lookup failed');
  assertEquals(calls.created.length, 0);
});

Deno.test('a trip row whose state this build does not know is refused', async () => {
  const { promise, calls } = call({ row: row({ state: 'expired' }) });
  const res = await promise;
  assertEquals(res.status, 500);
  assertEquals(
    (await body(res)).error,
    'trip row carries a state this build does not know',
  );
  assertEquals(calls.created.length, 0);
});

Deno.test('a completed or a cancelled trip is a 409 and writes nothing', async () => {
  for (const state of ['completed', 'cancelled']) {
    const { promise, calls } = call({ row: row({ state }) });
    const res = await promise;
    assertEquals(res.status, 409, state);
    // The `error` key is what `describeFunctionFailure` reads
    // (`apps/rider/lib/src/data/function_failure.dart:29-38`), so a 409 without
    // it would read `Something went wrong (409)` where the rider can act.
    assertEquals((await body(res)).error, 'trip is not payable', state);
    assertEquals(calls.paymentsRead.length, 0, state);
    assertEquals(calls.created.length, 0, state);
  }
});

Deno.test('a row with no finite fare is a 500 rather than a zero charge', async () => {
  for (const fare of [null, undefined, '20.40', Number.NaN]) {
    const { promise, calls } = call({ row: row({ fare_ghs: fare }) });
    const res = await promise;
    assertEquals(res.status, 500, String(fare));
    assertEquals((await body(res)).error, 'trip row carries no finite fare', String(fare));
    assertEquals(calls.created.length, 0, String(fare));
  }
});

// --- the reuse ------------------------------------------------------------

Deno.test('an open pending payment is reused rather than a second one inserted', async () => {
  // `complete-trip` reads the **newest** payment for the trip, so a second row
  // would orphan the first forever: nothing reads it, nothing voids it, and it
  // sits in `payments` as a pending charge against a trip that was paid.
  //
  // The reused row's state is `succeeded`, not `pending`, and deliberately so: a
  // fixture whose row carries the literal the code could have written cannot tell
  // an echo from a hardcoded `state: 'pending'`, and that assertion is the whole
  // of what the `state` key in the 200 body is worth.
  const open = payment({ id: 'pay-open', state: 'succeeded' });
  const { promise, calls } = call({ open });
  const res = await promise;
  const payload = await body(res);
  assertEquals(res.status, 200);
  assertEquals(payload.payment, open);
  assertEquals(payload.state, 'succeeded');
  assertEquals(calls.created.length, 0);
});

Deno.test('the reused row is echoed, and its state is read off the row', async () => {
  // The same contract, stated as an equality against the row rather than as an
  // equality against a literal, so it holds for every state the port can answer
  // with and fails for a hardcoded one.
  for (const state of ['pending', 'succeeded']) {
    const open = payment({ id: 'pay-open', state });
    const { promise } = call({ open });
    const res = await promise;
    const payload = await body(res);
    assertEquals(payload.state, state);
    assertEquals(payload.state, (payload.payment as Record<string, unknown>).state);
  }
});

Deno.test('the state reported on a new charge is the state of the row written', async () => {
  // As above, on the create branch: a real provider's confirmation would arrive
  // as a `succeeded` row, and a literal `pending` would report the opposite of
  // what the database holds.
  const written = payment({ id: 'pay-new', state: 'succeeded' });
  const { promise } = call({ created: written });
  const res = await promise;
  const payload = await body(res);
  assertEquals(res.status, 200);
  assertEquals(payload.payment, written);
  assertEquals(payload.state, 'succeeded');
});

Deno.test('a second call reuses the same row, so a double tap charges once', async () => {
  // The same double tap the reuse exists for, driven through both calls: the
  // first finds nothing and inserts, the second finds what the first inserted.
  const { deps, calls } = harness();
  const first = await handleDemoPay({
    deps,
    callerId: 'rider-1',
    tripId: 'trip-1',
    method: 'momo',
  });
  assertEquals(first.status, 200);
  const inserted = payment({ id: 'pay-new' });

  const secondDeps: DemoPayDeps = {
    ...deps,
    findOpenPayment: () => Promise.resolve({ row: inserted, error: null }),
  };
  const second = await handleDemoPay({
    deps: secondDeps,
    callerId: 'rider-1',
    tripId: 'trip-1',
    method: 'momo',
  });
  assertEquals(second.status, 200);
  assertEquals((await body(second)).payment, inserted);
  assertEquals(calls.created.length, 1);
});

Deno.test('the open payment is looked up for this rider and this trip', async () => {
  const { promise, calls } = call({ open: payment() });
  await promise;
  assertEquals(calls.paymentsRead, [{ tripId: 'trip-1', payerId: 'rider-1' }]);
});

Deno.test('a failed open-payment read is a 500 and inserts nothing', async () => {
  const { promise, calls } = call({ openError: 'connection reset' });
  const res = await promise;
  assertEquals(res.status, 500);
  assertEquals((await body(res)).error, 'payment lookup failed');
  assertEquals(calls.created.length, 0);
});

// --- the insert -----------------------------------------------------------

Deno.test('a demo charge writes a pending row for the trip fare and the method', async () => {
  const { promise, calls } = call({}, { method: 'cash' });
  const res = await promise;
  const payload = await body(res);
  assertEquals(res.status, 200);
  assertEquals(calls.created, [{
    tripId: 'trip-1',
    payerId: 'rider-1',
    amountGhs: 20.4,
    method: 'cash',
  }]);
  assertEquals(payload.state, 'pending');
});

Deno.test('a failed insert is a 500 that carries the database message', async () => {
  const { promise } = call({ createError: 'duplicate key value violates unique constraint' });
  const res = await promise;
  assertEquals(res.status, 500);
  assertEquals(
    (await body(res)).error,
    'duplicate key value violates unique constraint',
  );
});

Deno.test('an insert that wrote no row is a 500 rather than a charge nobody made', async () => {
  const { promise } = call({ created: null });
  const res = await promise;
  assertEquals(res.status, 500);
  assertEquals((await body(res)).error, 'payment was not written');
});

Deno.test('every trip state that can still be charged is chargeable', async () => {
  // The four non-terminal states, and the two terminal ones refused above. The
  // enum is `trip_state` (`init.sql:4-5`).
  for (const state of ['requested', 'matched', 'arriving', 'ongoing']) {
    const { promise, calls } = call({ row: row({ state }) });
    const res = await promise;
    assertEquals(res.status, 200, state);
    assertEquals(calls.created.length, 1, state);
  }
});

Deno.test('every error body is JSON, which is what functions_client decodes', async () => {
  for (const options of [{ row: null }, { tripError: 'boom' }, { row: row({ state: 'completed' }) }]) {
    const { promise } = call(options);
    const res = await promise;
    assertEquals(res.headers.get('Content-Type'), 'application/json');
    assertEquals(typeof (await body(res)).error, 'string');
  }
});
