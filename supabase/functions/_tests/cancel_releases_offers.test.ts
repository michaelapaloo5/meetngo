import { assertEquals } from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import { handleCancel, type CancelDeps, type TripRow } from '../cancel-trip/handler.ts';

/**
 * Cancelling a trip nobody has taken must still release its offers.
 *
 * `releaseOffers` used to sit inside `if (row.driver_id)`, so the one case where
 * offers are still pending -- a rider cancelling before any driver accepts -- was
 * the one case that never released them. They then sit pending on a cancelled
 * trip forever, and a driver browsing offers is shown ride requests for rides
 * that do not exist.
 *
 * Seventeen offers were found in exactly that state. These three tests are the
 * regression guard; the first one fails against the old code.
 */

const row = (over: Partial<TripRow> = {}): TripRow => ({
  id: 'trip-1',
  rider_id: 'rider-1',
  driver_id: 'driver-1',
  state: 'arriving',
  created_at: new Date(Date.now() - 30 * 60000).toISOString(),
  matched_at: new Date(Date.now() - 6 * 60000).toISOString(),
  fare_ghs: 12.5,
  ...over,
});

const harness = (options: { row?: TripRow; offerError?: string | null } = {}) => {
  const releasedOffers: string[] = [];
  const releasedDrivers: string[] = [];
  const compensations: unknown[] = [];

  const deps: CancelDeps = {
    authenticate: () => Promise.resolve({ userId: 'rider-1', error: null }),
    readTrip: () => Promise.resolve({
      row: options.row ?? row(),
      error: null,
    }),
    writeCancel: (_tripId, _fromState, cancelledAt) => Promise.resolve({
      row: row({ driver_id: null, state: 'cancelled', cancelled_at: cancelledAt }),
      error: null,
    }),
    releaseOffers: (tripId) => {
      releasedOffers.push(tripId);
      return Promise.resolve({ error: options.offerError ?? null });
    },
    releaseDriver: (driverId) => {
      releasedDrivers.push(driverId);
      return Promise.resolve({ error: null });
    },
    recordCompensation: (input) => {
      compensations.push(input);
      return Promise.resolve({ error: null });
    },
  };

  return { deps, releasedOffers, releasedDrivers, compensations };
};

const request = () =>
  new Request('https://fn.test/cancel-trip', {
    method: 'POST',
    headers: { Authorization: 'Bearer rider-jwt' },
    body: JSON.stringify({ tripId: 'trip-1' }),
  });

Deno.test('cancelling a trip no driver has taken still releases its offers', async () => {
  const { deps, releasedOffers } = harness({
    // `requested` with nobody assigned: the common case, and the only one where
    // offers are still pending at the moment of cancellation.
    row: row({ driver_id: null, state: 'requested', matched_at: null }),
  });

  const res = await handleCancel(request(), deps);

  assertEquals(res.status, 200);
  assertEquals(
    releasedOffers,
    ['trip-1'],
    'the offers were left pending on a cancelled trip, so a driver is offered a ride that does not exist',
  );
});

Deno.test('a trip with no driver releases no driver and pays no compensation', async () => {
  const { deps, releasedDrivers, compensations } = harness({
    row: row({ driver_id: null, state: 'requested', matched_at: null }),
  });

  await handleCancel(request(), deps);

  assertEquals(releasedDrivers, [], 'released a driver who was never assigned');
  assertEquals(compensations, [], 'recorded compensation for a driver who does not exist');
});

Deno.test('a failed offer release is reported rather than swallowed', async () => {
  // Silently dropping it is how the seventeen accumulated: the trip reads as
  // cancelled, the rider is told it worked, and the offers stay pending with
  // nothing left that will ever revisit them.
  const { deps } = harness({
    row: row({ driver_id: null, state: 'requested', matched_at: null }),
    offerError: 'write failed',
  });

  const res = await handleCancel(request(), deps);

  assertEquals(res.status, 500);
  assertEquals(
    (await res.json() as Record<string, unknown>).error,
    'the trip was cancelled but its pending offers were not released: write failed',
  );
});
