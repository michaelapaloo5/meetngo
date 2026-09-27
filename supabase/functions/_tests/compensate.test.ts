import { assertEquals } from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import { deleteTripAndFail, type DeleteTrip } from '../request-ride/compensate.ts';

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
