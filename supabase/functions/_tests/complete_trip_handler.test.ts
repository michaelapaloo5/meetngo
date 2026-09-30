import { assertEquals } from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import {
  handleComplete,
  ledgerEntriesFor,
  readCompleteBody,
  type CompleteDeps,
  type LedgerEntryInput,
  type PaymentRow,
  type RatingInput,
  type TripRow,
} from '../complete-trip/handler.ts';
import { settleFare } from '../complete-trip/ledger.ts';

// Every port is a recording fake, so a test can see what the handler *asked for*
// and not only what it answered. Nothing here opens a socket or reads an
// environment variable, which is the whole reason the handler was split out of
// `index.ts`: with `serve()` at module scope the file could not be imported
// without starting a server, and the fourteen behaviours in the table below had
// no test at all.

interface LedgerCall {
  tripId: string;
  driverId: string;
  entries: LedgerEntryInput[];
}

interface Calls {
  authenticated: string[];
  tripsRead: string[];
  paymentsRead: string[];
  succeeded: string[];
  voided: string[];
  ledger: LedgerCall[];
  payouts: { tripId: string; driverId: string; amountGhs: number }[];
  ratings: RatingInput[];
  /** Which drivers had their launch-promo window looked up, in order. */
  promoLookups: string[];
  /** The rate each settled trip recorded, which must be the rate it settled at. */
  commissionRates: { tripId: string; rate: number }[];
}

interface Options {
  row?: TripRow | null;
  tripError?: string | null;
  userId?: string | null;
  payment?: PaymentRow | null;
  paymentError?: string | null;
  /** `false` is the zero-row match: a lost race, not a database error. */
  succeedRow?: PaymentRow | null;
  succeedError?: string | null;
  voidRow?: PaymentRow | null;
  voidError?: string | null;
  ledgerOk?: boolean;
  payoutOk?: boolean;
  ratingOk?: boolean;
  ratingDuplicate?: boolean;
  /**
   * The driver's launch-promo window. Absent means "no window", which is the
   * driver who has never completed a trip and therefore pays the standard 15%.
   * Set it to a live `ends_at` to put the trip inside the promo.
   */
  promo?: { endsAt: string } | null;
  promoError?: string | null;
  commissionRateOk?: boolean;
}

const row = (over: Partial<TripRow> = {}): TripRow => ({
  id: 'trip-1',
  rider_id: 'rider-1',
  driver_id: 'driver-1',
  state: 'completed',
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
    succeeded: [],
    voided: [],
    ledger: [],
    payouts: [],
    ratings: [],
    promoLookups: [],
    commissionRates: [],
  };
  // `Promise.resolve` rather than `async`: the ports are declared as returning a
  // Promise, and an `async` arrow with no `await` in it is a `require-await`
  // lint error.
  const deps: CompleteDeps = {
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
    findOpenPayment: (tripId) => {
      calls.paymentsRead.push(tripId);
      return Promise.resolve({
        row: 'payment' in options ? options.payment ?? null : payment(),
        error: options.paymentError ?? null,
      });
    },
    markPaymentSucceeded: (paymentId) => {
      calls.succeeded.push(paymentId);
      const written = options.succeedRow === undefined
        ? payment({ state: 'succeeded' })
        : options.succeedRow;
      return Promise.resolve({ row: written, error: options.succeedError ?? null });
    },
    markPaymentVoided: (paymentId) => {
      calls.voided.push(paymentId);
      const written = options.voidRow === undefined
        ? payment({ state: 'voided' })
        : options.voidRow;
      return Promise.resolve({ row: written, error: options.voidError ?? null });
    },
    writeLedger: (tripId, driverId, entries) => {
      calls.ledger.push({ tripId, driverId, entries });
      return Promise.resolve({ ok: options.ledgerOk ?? true, error: null });
    },
    writePayout: (tripId, driverId, amountGhs) => {
      calls.payouts.push({ tripId, driverId, amountGhs });
      return Promise.resolve({ ok: options.payoutOk ?? true, error: null });
    },
    // The launch promo. A window is opt-in per test so the default case is a
    // driver who has never completed a trip and pays the standard 15% -- the
    // state every existing settlement test is written against, and changing it
    // silently would have quietly rewritten what they all assert.
    findPromoWindow: (driverId) => {
      calls.promoLookups.push(driverId);
      return Promise.resolve({
        window: options.promo ?? null,
        error: options.promoError ?? null,
      });
    },
    recordCommissionRate: (tripId, rate) => {
      calls.commissionRates.push({ tripId, rate });
      return Promise.resolve({ ok: options.commissionRateOk ?? true, error: null });
    },
    writeRating: (input) => {
      calls.ratings.push(input);
      return Promise.resolve({
        ok: options.ratingOk ?? true,
        duplicate: options.ratingDuplicate ?? false,
      });
    },
  };
  return { deps, calls };
};

const call = (
  options: Options = {},
  overrides: {
    callerId?: string | null;
    rating?: { stars: number; comment: string };
    tripId?: string;
  } = {},
) => {
  const { deps, calls } = harness(options);
  const promise = handleComplete({
    deps,
    callerId: overrides.callerId === undefined ? 'rider-1' : overrides.callerId,
    tripId: overrides.tripId ?? 'trip-1',
    rating: overrides.rating,
  });
  return { promise, calls, deps };
};

const body = async (res: Response) => await res.json() as Record<string, unknown>;

// The rounding `numeric(10,2)` does, written out here rather than imported: a
// test that rounds with the production helper cannot fail when the helper is
// wrong, and the identity below is the one the *database* has to keep, because
// `ledger_entries.amount_ghs` and `payouts.amount_ghs` are both
// `numeric(10,2)`. The sum is rounded as well as the terms, because two two-decimal
// numbers added as binary floats are not a two-decimal number: 20.42 and -3.06
// add to 17.360000000000003, which `numeric(10,2)` would store as 17.36 and
// which a strict `==` against 17.36 would report as a mismatch.
const round2 = (v: number) => Math.round(v * 100) / 100;

const stored = (entries: LedgerEntryInput[]): number =>
  round2(entries.reduce((total, entry) => total + entry.amountGhs, 0));

// --- the 401, the 403 and the 404 ----------------------------------------

Deno.test('a caller with no identity is a 401 before any port is called', async () => {
  const { promise, calls } = call({}, { callerId: null });
  const res = await promise;
  assertEquals(res.status, 401);
  assertEquals((await body(res)).error, 'unauthenticated');
  assertEquals(calls.tripsRead.length, 0);
  assertEquals(calls.paymentsRead.length, 0);
});

Deno.test("another rider's trip is a 403 and is never read into a response", async () => {
  const { promise, calls } = call({ row: row({ rider_id: 'somebody-else' }) });
  const res = await promise;
  assertEquals(res.status, 403);
  const payload = await body(res);
  assertEquals(payload.error, 'not your trip');
  // A 403 must not confirm that the trip exists, so the row never reaches the
  // response.
  assertEquals(payload.trip, undefined);
  assertEquals(calls.succeeded.length, 0);
  assertEquals(calls.ledger.length, 0);
  assertEquals(calls.payouts.length, 0);
});

Deno.test('a missing trip is a 404 and a failed read is a 500', async () => {
  const missing = call({ row: null });
  const notFound = await missing.promise;
  assertEquals(notFound.status, 404);
  assertEquals((await body(notFound)).error, 'trip not found');

  const failed = call({ tripError: 'connection reset' });
  const broken = await failed.promise;
  assertEquals(broken.status, 500);
  assertEquals((await body(broken)).error, 'trip lookup failed');
});

Deno.test('the driver may settle their own trip, and pays no rider for it', async () => {
  // The settlement is a function of the fare, so either party pressing the
  // button settles the same money. What must not change is who the money is
  // attributed to: `ledger_entries.driver_id` is not null (`init.sql:123`).
  const { promise, calls } = call({}, { callerId: 'driver-1' });
  const res = await promise;
  assertEquals(res.status, 200);
  assertEquals(calls.payouts, [{ tripId: 'trip-1', driverId: 'driver-1', amountGhs: 17.34 }]);
});

// --- the state guard -------------------------------------------------------

Deno.test('a trip row whose state this build does not know is refused, not settled', async () => {
  const { promise, calls } = call({ row: row({ state: 'expired' }) });
  const res = await promise;
  assertEquals(res.status, 500);
  assertEquals(
    (await body(res)).error,
    'trip row carries a state this build does not know',
  );
  assertEquals(calls.paymentsRead.length, 0);
  assertEquals(calls.ledger.length, 0);
  assertEquals(calls.payouts.length, 0);
});

// --- a trip that is not finished is a 409, not a receipt -------------------

Deno.test('a trip that is not finished is refused and nothing is written', async () => {
  for (const state of ['requested', 'matched', 'arriving', 'ongoing']) {
    const { promise, calls } = call({ row: row({ state }) });
    const res = await promise;
    assertEquals(res.status, 409, state);
    assertEquals((await body(res)).error, 'This trip is not complete yet', state);
    // The payment is not even read, so a call on an `arriving` trip cannot
    // void the rider's open demo charge. The brief's draft voided it.
    assertEquals(calls.paymentsRead.length, 0, state);
    assertEquals(calls.voided.length, 0, state);
    assertEquals(calls.ledger.length, 0, state);
    assertEquals(calls.payouts.length, 0, state);
  }
});

// --- the money identity ----------------------------------------------------

Deno.test('the two ledger amounts sum to the payout, to the cent', async () => {
  // A real assertion over what the fakes were asked to write, not an identity
  // about the test's own arithmetic. The mutation this kills is the draft's:
  // the fare entry carrying the **net** payout and a negative commission
  // against the same driver, which nets 14.28 against a 17.34 payout.
  const { promise, calls } = call();
  const res = await promise;
  const payload = await body(res);
  assertEquals(res.status, 200);

  assertEquals(calls.ledger.length, 1);
  const { entries } = calls.ledger[0];
  assertEquals(entries.map((e) => e.kind), ['fare', 'commission']);
  assertEquals(entries[0].amountGhs, 20.4);
  assertEquals(entries[1].amountGhs < 0, true);
  assertEquals(stored(entries), round2(calls.payouts[0].amountGhs));
  // ...and to what the function told the rider it settled.
  const settlement = payload.settlement as Record<string, number>;
  assertEquals(calls.payouts[0].amountGhs, settlement.driverPayoutGhs);
  // The fare entry is the gross, which is the half of the pair the draft got
  // wrong: it wrote the net here and then took the commission off it again.
  assertEquals(entries[0].amountGhs, settlement.fareGhs);
});

Deno.test('the ledger pair keeps summing for every fare the settlement allows', async () => {
  for (const fare of [0, 0.01, 0.05, 6, 20.4, 20.42, 33.33, 112221]) {
    const { promise, calls } = call({ row: row({ fare_ghs: fare }) });
    await promise;
    const { entries } = calls.ledger[0];
    assertEquals(stored(entries), round2(calls.payouts[0].amountGhs), `fare ${fare}`);
  }
});

Deno.test('a trip with no driver settles the payment and writes no money', async () => {
  const { promise, calls } = call({ row: row({ driver_id: null }) });
  const res = await promise;
  assertEquals(res.status, 200);
  assertEquals(calls.succeeded, ['pay-1']);
  // `ledger_entries.driver_id` and `payouts.driver_id` are both `not null`, so
  // a trip with no driver has nothing to write against.
  assertEquals(calls.ledger.length, 0);
  assertEquals(calls.payouts.length, 0);
});

// --- the checked writes ---------------------------------------------------

Deno.test('a void write that matches no row is a 404 and writes no ledger', async () => {
  const { promise, calls } = call({
    row: row({ state: 'cancelled' }),
    voidRow: null,
  });
  const res = await promise;
  assertEquals(res.status, 404);
  assertEquals((await body(res)).error, 'payment not found');
  assertEquals(calls.ledger.length, 0);
});

Deno.test('a failed void write is a 500 and writes no ledger', async () => {
  const { promise, calls } = call({
    row: row({ state: 'cancelled' }),
    voidError: 'payments is locked',
  });
  const res = await promise;
  assertEquals(res.status, 500);
  assertEquals((await body(res)).error, 'void write failed');
  assertEquals(calls.ledger.length, 0);
});

Deno.test('a failed void ledger write is a 500 that names the step', async () => {
  const { promise, calls } = call({
    row: row({ state: 'cancelled' }),
    ledgerOk: false,
  });
  const res = await promise;
  assertEquals(res.status, 500);
  assertEquals((await body(res)).error, 'void ledger write failed');
  assertEquals(calls.payouts.length, 0);
});

Deno.test('a succeed write that matches no row is a 404 and writes no money', async () => {
  const { promise, calls } = call({ succeedRow: null });
  const res = await promise;
  assertEquals(res.status, 404);
  assertEquals((await body(res)).error, 'payment not found');
  assertEquals(calls.ledger.length, 0);
  assertEquals(calls.payouts.length, 0);
});

Deno.test('a failed succeed write is a 500 and writes no money', async () => {
  const { promise, calls } = call({ succeedError: 'payments is locked' });
  const res = await promise;
  assertEquals(res.status, 500);
  assertEquals((await body(res)).error, 'payment write failed');
  assertEquals(calls.ledger.length, 0);
  assertEquals(calls.payouts.length, 0);
});

Deno.test('a failed ledger write is a 500 and does not claim a payout', async () => {
  const { promise, calls } = call({ ledgerOk: false });
  const res = await promise;
  assertEquals(res.status, 500);
  assertEquals((await body(res)).error, 'ledger write failed');
  assertEquals(calls.ledger.length, 1);
  // The payout is behind the ledger on purpose: a `payouts` row with no fare
  // behind it is a wallet that grew by an amount nothing earned.
  assertEquals(calls.payouts.length, 0);
});

Deno.test('a failed payout write is a 500 after the ledger is written', async () => {
  const { promise, calls } = call({ payoutOk: false });
  const res = await promise;
  assertEquals(res.status, 500);
  assertEquals((await body(res)).error, 'payout write failed');
  // Reported, not hidden: the fare and the commission are in the driver's
  // ledger and cannot be unwritten by answering an error instead.
  assertEquals(calls.ledger.length, 1);
});

Deno.test('a failed payment lookup is a 500 rather than a settlement', async () => {
  const { promise, calls } = call({ paymentError: 'connection reset' });
  const res = await promise;
  assertEquals(res.status, 500);
  assertEquals((await body(res)).error, 'payment lookup failed');
  assertEquals(calls.ledger.length, 0);
});

Deno.test('a row with no finite fare is a 500 rather than a zero settlement', async () => {
  for (const fare of [null, undefined, '20.40', Number.NaN]) {
    const { promise, calls } = call({ row: row({ fare_ghs: fare }) });
    const res = await promise;
    assertEquals(res.status, 500, String(fare));
    assertEquals((await body(res)).error, 'trip row carries no finite fare', String(fare));
    // `Number(null)` is 0 and `Number(undefined)` is NaN, so a coercion here
    // would settle GHS 0.00 for a damaged row and write it to the ledger.
    assertEquals(calls.ledger.length, 0, String(fare));
  }
});

// --- the repeat call -------------------------------------------------------

Deno.test('a second call on a settled trip writes no money a second time', async () => {
  // A double tap, or a retry of a call whose response was lost. `payments` and
  // `payouts` carry no unique constraint on trip (`init.sql:112-130`), so the
  // second pair of rows would be accepted and the driver's ledger would count
  // the fare twice.
  const { deps, calls } = harness();
  const first = await handleComplete({ deps, callerId: 'rider-1', tripId: 'trip-1' });
  assertEquals(first.status, 200);
  assertEquals(calls.ledger.length, 1);
  assertEquals(calls.payouts.length, 1);

  // The payment the first call moved to `succeeded` is what the second call
  // reads back, which is the whole point of `findOpenPayment` not filtering on
  // `state = 'pending'`.
  const settled: PaymentRow = payment({ state: 'succeeded' });
  const again: CompleteDeps = {
    ...deps,
    findOpenPayment: () => Promise.resolve({ row: settled, error: null }),
  };
  const second = await handleComplete({ deps: again, callerId: 'rider-1', tripId: 'trip-1' });
  assertEquals(second.status, 200);
  assertEquals((await body(second)).paymentState, 'succeeded');
  // Nothing at all, on any of the four writes. A charge on this path would
  // either credit the fare twice or, with the void condition keyed on the
  // absence of a charge rather than on the decision, void a payment that had
  // already succeeded.
  assertEquals(calls.succeeded.length, 1);
  assertEquals(calls.voided.length, 0);
  assertEquals(calls.ledger.length, 1);
  assertEquals(calls.payouts.length, 1);
});

Deno.test('a repeat call after a failed ledger write does not pay twice', async () => {
  // The residual of the already-succeeded guard, stated rather than hidden: the
  // payment is marked succeeded *before* the ledger write, so a failed ledger
  // write leaves the trip settled and the driver unpaid. What the guard buys is
  // that the retry does not write a second fare on top of the first -- the
  // money that is already in the ledger is what the retry keeps.
  const broken = harness({ ledgerOk: false });
  const failed = await handleComplete({
    deps: broken.deps,
    callerId: 'rider-1',
    tripId: 'trip-1',
  });
  assertEquals(failed.status, 500);
  assertEquals(broken.calls.payouts.length, 0);

  // The retry sees the payment the first call moved to `succeeded`, and the same
  // failing ledger port, so nothing is written again at all.
  const settled: PaymentRow = payment({ state: 'succeeded' });
  const retryDeps: CompleteDeps = {
    ...broken.deps,
    findOpenPayment: () => Promise.resolve({ row: settled, error: null }),
  };
  const res = await handleComplete({
    deps: retryDeps,
    callerId: 'rider-1',
    tripId: 'trip-1',
  });
  assertEquals(res.status, 200);
  assertEquals((await body(res)).paymentState, 'succeeded');
  assertEquals(broken.calls.succeeded.length, 1);
  assertEquals(broken.calls.ledger.length, 1);
  assertEquals(broken.calls.payouts.length, 0);
});

// --- the void path ---------------------------------------------------------

Deno.test('a cancelled trip voids the open charge and writes a zero void entry', async () => {
  const { promise, calls } = call({ row: row({ state: 'cancelled' }) });
  const res = await promise;
  const payload = await body(res);
  assertEquals(res.status, 200);
  assertEquals(payload.paymentState, 'voided');
  assertEquals(calls.voided, ['pay-1']);
  assertEquals(calls.succeeded.length, 0);
  assertEquals(calls.ledger, [{
    tripId: 'trip-1',
    driverId: 'driver-1',
    // Zero and not a negative: the charge never became a credit, so the driver's
    // record of this trip is nothing rather than a debit.
    entries: [{
      kind: 'void',
      amountGhs: 0,
      note: 'Trip was not completed, charge voided',
    }],
  }]);
  assertEquals(calls.payouts.length, 0);
});

Deno.test('a second call on a cancelled trip writes no second void entry', async () => {
  const { deps, calls } = harness({ row: row({ state: 'cancelled' }) });
  await handleComplete({ deps, callerId: 'rider-1', tripId: 'trip-1' });
  assertEquals(calls.ledger.length, 1);

  const voided: PaymentRow = payment({ state: 'voided' });
  const again: CompleteDeps = {
    ...deps,
    findOpenPayment: () => Promise.resolve({ row: voided, error: null }),
  };
  const res = await handleComplete({ deps: again, callerId: 'rider-1', tripId: 'trip-1' });
  assertEquals(res.status, 200);
  assertEquals((await body(res)).paymentState, 'voided');
  assertEquals(calls.ledger.length, 1);
  assertEquals(calls.voided.length, 1);
});

Deno.test('a cancelled trip with no payment at all still answers voided', async () => {
  const { promise, calls } = call({ row: row({ state: 'cancelled' }), payment: null });
  const res = await promise;
  assertEquals(res.status, 200);
  assertEquals((await body(res)).paymentState, 'voided');
  assertEquals(calls.voided.length, 0);
  assertEquals(calls.ledger.length, 0);
});

Deno.test('a completed trip with no payment row settles the money anyway', async () => {
  const { promise, calls } = call({ payment: null });
  const res = await promise;
  assertEquals(res.status, 200);
  assertEquals((await body(res)).paymentState, 'succeeded');
  assertEquals(calls.succeeded.length, 0);
  assertEquals(calls.payouts, [{ tripId: 'trip-1', driverId: 'driver-1', amountGhs: 17.34 }]);
});

// --- the ratings path -----------------------------------------------------

Deno.test('a rating in the request writes one rider row against the trip', async () => {
  const { promise, calls } = call({}, { rating: { stars: 4, comment: 'Great' } });
  const res = await promise;
  const payload = await body(res);
  assertEquals(res.status, 200);
  assertEquals(calls.ratings, [{
    tripId: 'trip-1',
    raterId: 'rider-1',
    rateeId: 'driver-1',
    fromRole: 'rider',
    stars: 4,
    comment: 'Great',
  }]);
  assertEquals(payload.ratingState, 'recorded');
});

Deno.test('a call with no rating writes no row and says so', async () => {
  const { promise, calls } = call();
  const res = await promise;
  assertEquals((await body(res)).ratingState, 'skipped');
  assertEquals(calls.ratings.length, 0);
});

Deno.test('stars of 0 and 6 are a 400 and write nothing at all', async () => {
  for (const stars of [0, 6, -1, 7, 2.5, Number.NaN]) {
    const { promise, calls } = call({}, { rating: { stars, comment: '' } });
    const res = await promise;
    assertEquals(res.status, 400, String(stars));
    assertEquals((await body(res)).error, 'stars must be 1 to 5', String(stars));
    assertEquals(calls.ratings.length, 0, String(stars));
    // Nothing is settled either: the request was refused before the first
    // lookup, so a bad rating cannot leave a trip half settled.
    assertEquals(calls.tripsRead.length, 0, String(stars));
    assertEquals(calls.ledger.length, 0, String(stars));
  }
});

Deno.test('a duplicate rating is the 409 it is, inside a 200 that kept the settlement', async () => {
  // `unique (trip_id, from_role)` (`init.sql:141`) makes a re-rating a duplicate
  // rather than a second row, and it is a mistake rather than a fault. The
  // status cannot be this response's own: `functions_client` throws on anything
  // outside 200..299
  // (`functions_client-2.7.1/lib/src/functions_client.dart:255-269`), which
  // would throw away the `paymentState` the money write just produced.
  const { promise, calls } = call({ ratingDuplicate: true, ratingOk: false }, {
    rating: { stars: 4, comment: '' },
  });
  const res = await promise;
  const payload = await body(res);
  assertEquals(res.status, 200);
  assertEquals(payload.paymentState, 'succeeded');
  assertEquals(payload.ratingState, 'duplicate');
  assertEquals(payload.ratingStatus, 409);
  // The money is untouched by the duplicate: it was already written and is
  // reported as written.
  assertEquals(calls.payouts, [{ tripId: 'trip-1', driverId: 'driver-1', amountGhs: 17.34 }]);
});

Deno.test('a failed rating insert does not unsettle the trip', async () => {
  const { promise, calls } = call({ ratingOk: false }, {
    rating: { stars: 4, comment: '' },
  });
  const res = await promise;
  const payload = await body(res);
  assertEquals(res.status, 200);
  assertEquals(payload.paymentState, 'succeeded');
  assertEquals(payload.ratingState, 'failed');
  assertEquals(payload.ratingStatus, 500);
  assertEquals(calls.payouts.length, 1);
});

Deno.test('a completed trip with no driver reports the rating as failed, not skipped', async () => {
  const { promise, calls } = call({ row: row({ driver_id: null }) }, {
    rating: { stars: 3, comment: '' },
  });
  const res = await promise;
  const payload = await body(res);
  assertEquals(res.status, 200);
  // `ratee_id` is `not null` (`init.sql:136`): the rider asked for a rating to
  // be saved and there is nobody to save it about.
  assertEquals(payload.ratingState, 'failed');
  assertEquals(calls.ratings.length, 0);
});

Deno.test('a ledger kind this build has no amount for is refused, not guessed', () => {
  // `settleAgainstTripState` returns one of three kind lists, so the unknown-kind
  // arm is unreachable through the handler. It is pinned directly, on the pure
  // function, because the alternative -- a `default` arm that writes a zero row
  // for a kind it does not know -- is a silent wrong answer, and
  // `ledger_entries.kind`'s CHECK would refuse most such guesses anyway
  // (`init.sql:126`), turning a programming slip into a 500 from the database
  // with nothing in the body to say what it was.
  const settlement = settleFare(20.4);
  assertEquals(ledgerEntriesFor(['bonus'], settlement), null);
  assertEquals(ledgerEntriesFor(['fare', 'bonus'], settlement), null);
  // The three the decision can ask for, each with the amount it owes.
  assertEquals(ledgerEntriesFor(['fare'], settlement), [
    { kind: 'fare', amountGhs: 20.4, note: 'Trip fare' },
  ]);
  assertEquals(ledgerEntriesFor(['commission'], settlement), [{
    kind: 'commission',
    amountGhs: -(settlement.fareGhs - settlement.driverPayoutGhs),
    note: 'Platform commission 15%',
  }]);
  // Zero, and not a negative: the voided charge never became a credit.
  assertEquals(ledgerEntriesFor(['void'], settlement), [
    { kind: 'void', amountGhs: 0, note: 'Trip was not completed, charge voided' },
  ]);
  // An empty list is not an error. It is what a `completed` trip with an
  // already-`succeeded` payment asks for, and it writes nothing.
  assertEquals(ledgerEntriesFor([], settlement), []);
});

Deno.test('a cancelled trip still takes the rating', async () => {
  const { promise, calls } = call({ row: row({ state: 'cancelled' }) }, {
    rating: { stars: 1, comment: 'Never arrived' },
  });
  const res = await promise;
  assertEquals(res.status, 200);
  assertEquals((await body(res)).ratingState, 'recorded');
  assertEquals(calls.ratings.length, 1);
});

// --- the request body reader ---------------------------------------------

Deno.test('a body with no usable tripId is refused before the trip is read', () => {
  for (const payload of [{}, { tripId: '' }, { tripId: 7 }, null, 'trip-1', []]) {
    const parsed = readCompleteBody(payload);
    assertEquals(parsed.ok, false, JSON.stringify(payload));
    if (!parsed.ok) assertEquals(typeof parsed.error, 'string', JSON.stringify(payload));
  }
  assertEquals(readCompleteBody({ tripId: 'trip-1' }).ok, true);
});

Deno.test('a rating of the wrong shape is refused and a good one is carried through', () => {
  for (const rating of ['five', 5, [], { stars: '4' }, { comment: 'no stars' }]) {
    const parsed = readCompleteBody({ tripId: 'trip-1', rating });
    assertEquals(parsed.ok, false, JSON.stringify(rating));
  }
  // The range is the handler's check, not the reader's, so 0 and 6 come through
  // here and are refused there with a 400 of their own.
  for (const stars of [0, 6, 4, 2.5]) {
    const parsed = readCompleteBody({ tripId: 'trip-1', rating: { stars, comment: 'c' } });
    assertEquals(parsed.ok, true, String(stars));
    if (parsed.ok) {
      assertEquals(parsed.rating, { stars, comment: 'c' });
    }
  }
  const noComment = readCompleteBody({ tripId: 'trip-1', rating: { stars: 4 } });
  assertEquals(noComment.ok, true);
  if (noComment.ok) assertEquals(noComment.rating, { stars: 4, comment: '' });
});

// --- the response shape ---------------------------------------------------

Deno.test('the 200 body carries the trip, the settlement and the payment state', async () => {
  const { promise } = call();
  const res = await promise;
  const payload = await body(res);
  assertEquals(res.headers.get('Content-Type'), 'application/json');
  assertEquals((payload.trip as Record<string, unknown>).id, 'trip-1');
  assertEquals(payload.settlement, {
    fareGhs: 20.4,
    commissionGhs: 3.06,
    driverPayoutGhs: 17.34,
  });
  assertEquals(payload.paymentState, 'succeeded');
});

Deno.test('every error body is JSON, which is what functions_client decodes', async () => {
  for (const options of [{ row: null }, { tripError: 'boom' }, { row: row({ state: 'ongoing' }) }]) {
    const { promise } = call(options);
    const res = await promise;
    assertEquals(res.headers.get('Content-Type'), 'application/json');
    assertEquals(typeof (await body(res)).error, 'string');
  }
});
