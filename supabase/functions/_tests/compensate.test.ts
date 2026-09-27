import { assertEquals } from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import { compensating, deleteTripAndFail, type DeleteTrip } from '../request-ride/compensate.ts';

Deno.test('a failure after the insert deletes the trip row that was inserted', async () => {
  const deleted: string[] = [];
  const deleteTrip: DeleteTrip = (tripId) => {
    deleted.push(tripId);
    return Promise.resolve({ error: null });
  };

  const failure = await deleteTripAndFail(deleteTrip, 'trip-0001', 'offer insert failed');

  assertEquals(deleted, ['trip-0001']);
  assertEquals(failure, { error: 'offer insert failed' });
});

Deno.test('the original failure is still reported when the delete itself fails', async () => {
  const deleteTrip: DeleteTrip = () =>
    Promise.resolve({ error: { message: 'permission denied for table trips' } });

  const failure = await deleteTripAndFail(deleteTrip, 'trip-0001', 'match failed');

  assertEquals(failure, {
    error: 'match failed',
    cleanupError: 'permission denied for table trips',
  });
});

// The unchecked route to the same orphan: anything thrown between the trip
// insert and the response used to escape to `serve`'s default onError, which
// returns a bare 500 and leaves the `requested` row behind for Task 8's
// `activeTrip()` to keep serving.
Deno.test('a throw during the fan-out compensates the trip insert', async () => {
  const deleted: string[] = [];
  const deleteTrip: DeleteTrip = (tripId) => {
    deleted.push(tripId);
    return Promise.resolve({ error: null });
  };

  const outcome = await compensating(deleteTrip, 'trip-0001', () =>
    Promise.reject(new Error('match_offers_for_trip: Unexpected token < in JSON at position 0'))
  );

  assertEquals(deleted, ['trip-0001']);
  assertEquals(outcome, {
    ok: false,
    error: 'match_offers_for_trip: Unexpected token < in JSON at position 0',
  });
});

Deno.test('a fan-out that throws something that is not an Error still compensates', async () => {
  const deleted: string[] = [];
  const deleteTrip: DeleteTrip = (tripId) => {
    deleted.push(tripId);
    return Promise.resolve({ error: null });
  };

  const outcome = await compensating(deleteTrip, 'trip-0001', () =>
    Promise.reject('rows.map is not a function')
  );

  assertEquals(deleted, ['trip-0001']);
  assertEquals(outcome, { ok: false, error: 'rows.map is not a function' });
});

Deno.test('a completed fan-out does not delete the trip', async () => {
  const deleted: string[] = [];
  const deleteTrip: DeleteTrip = (tripId) => {
    deleted.push(tripId);
    return Promise.resolve({ error: null });
  };

  const outcome = await compensating(deleteTrip, 'trip-0001', () => Promise.resolve(['d-1']));

  assertEquals(deleted, []);
  assertEquals(outcome, { ok: true, value: ['d-1'] });
});

Deno.test('a compensating delete that fails is reported through the fan-out too', async () => {
  const deleteTrip: DeleteTrip = () =>
    Promise.resolve({ error: { message: 'permission denied for table trips' } });

  const outcome = await compensating(deleteTrip, 'trip-0001', () =>
    Promise.reject(new Error('offers insert failed'))
  );

  assertEquals(outcome, {
    ok: false,
    error: 'offers insert failed',
    cleanupError: 'permission denied for table trips',
  });
});
