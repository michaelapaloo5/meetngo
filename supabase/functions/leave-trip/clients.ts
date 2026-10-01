// The six ports `handleLeave` takes, and the Supabase client behind them.
//
// The same split as `cancel-trip/clients.ts`, for the same reason: every one of
// these writes is something a client cannot make, so the rules live in
// `handler.ts` against an interface and the credentials live here.

import { createClient, type SupabaseClient } from 'jsr:@supabase/supabase-js@2';

export function buildService(): SupabaseClient {
  // `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` are injected
  // by the platform. The service key bypasses RLS, which is what makes the
  // `trip_withdrawals` insert possible at all -- that table has no policies on
  // purpose, and a client key would be refused.
  return createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    { auth: { persistSession: false } },
  );
}

const first = <T>(rows: T[] | null): T | null => (rows && rows.length > 0 ? rows[0] : null);
const ok = (error: { message: string } | null): string | null => error?.message ?? null;

export interface LeaveTripRow {
  id: string;
  rider_id: string;
  driver_id: string | null;
  state: string;
  [column: string]: unknown;
}

export interface LeaveDeps {
  authenticate(token: string): Promise<{ userId: string | null; error: string | null }>;
  readTrip(tripId: string): Promise<{ row: LeaveTripRow | null; error: string | null }>;

  /// Put the trip back to `requested`, conditional on it still being in
  /// `fromState`.
  ///
  /// The `.eq('state', fromState)` is the whole concurrency story. Two requests
  /// at once -- the driver pressing the button twice, or the rider cancelling at
  /// the same moment -- must not both believe they were the one who moved it. With
  /// the condition, exactly one update matches a row and the other matches none
  /// and reads back null, which the handler reports as a conflict rather than as a
  /// success.
  ///
  /// `driver_id` is cleared here, and that is load-bearing rather than tidy.
  /// `activeTrip` in the driver app selects `driver_id = me and state in
  /// ('requested','matched','arriving','ongoing')` -- so a trip returned to
  /// `requested` with the driver still on it comes straight back as that driver's
  /// active trip. The Leave button would appear to do nothing, the sheet would
  /// stay up, and the second press would answer "You do not have this trip yet.
  /// Decline the offer instead." -- which is what it did, live, before this line
  /// existed. The trip is not in the pool until it has nobody on it.
  returnToRequested(
    tripId: string,
    fromState: string,
  ): Promise<{ row: LeaveTripRow | null; error: string | null }>;

  /// Record that this driver withdrew from this trip.
  ///
  /// An upsert rather than an insert, because a driver who presses the button
  /// twice has not withdrawn twice, and the unique constraint on
  /// `(trip_id, driver_id)` would otherwise answer the second press with a 409 --
  /// which the driver would see as the app failing on a trip they are trying to
  /// leave.
  recordWithdrawal(
    tripId: string,
    driverId: string,
    reason: string,
  ): Promise<{ error: string | null }>;

  /// Whether this driver has already withdrawn from this trip.
  ///
  /// Exists for one case: the driver pressed the button twice. The first press
  /// released the trip and cleared `driver_id`, so the second press arrives at a
  /// trip that is no longer theirs -- and the ownership check would answer 403
  /// "not your trip" to a driver standing on the screen they just left. This is
  /// what tells those two apart.
  ///
  /// Recorded *before* the state moves, so it can be true while the trip is still
  /// `arriving` and still assigned to this driver, if a previous attempt recorded
  /// the withdrawal and then failed to release. The handler therefore only trusts
  /// it together with ownership that has actually been given up.
  hasWithdrawn(
    tripId: string,
    driverId: string,
  ): Promise<{ row: boolean; error: string | null }>;

  /// The driver goes back on the road.
  ///
  /// Not `offline`. A driver who leaves one trip because the pickup was impossible
  /// is still on the road and still wants the next one; taking them offline as a
  /// side effect of one bad street would cost a rider the next available car.
  releaseDriver(driverId: string): Promise<{ error: string | null }>;

  /// Any offers still pending on this trip are void, because the trip is back in
  /// the pool and a second round of offers would be a second wave of drivers being
  /// summoned for a ride somebody else is already driving towards.
  releaseOffers(tripId: string): Promise<{ error: string | null }>;
}

export function buildDeps(service: SupabaseClient): LeaveDeps {
  return {
    authenticate: async (token) => {
      // Both fields are checked: `getUser` answers a revoked or malformed token
      // with a null user *and* an error, and either alone is enough to refuse.
      const { data, error } = await service.auth.getUser(token);
      return { userId: data.user?.id ?? null, error: error?.message ?? null };
    },

    readTrip: async (tripId) => {
      const { data, error } = await service
        .from('trips')
        .select('*')
        .eq('id', tripId)
        .limit(1);
      return { row: first(data as LeaveTripRow[] | null), error: ok(error) };
    },

    returnToRequested: async (tripId, fromState) => {
      const { data, error } = await service
        .from('trips')
        // `matched_at` is cleared as well as the state. It records when the trip
        // was matched, and leaving it in place would make a re-matched trip look
        // like it had been waiting on this driver for however long they took to
        // leave -- which is exactly the sort of number somebody would use to argue
        // the driver wasted the rider's time.
        .update({ state: 'requested', driver_id: null, matched_at: null })
        .eq('id', tripId)
        .eq('state', fromState)
        .select('*');
      return { row: first(data as LeaveTripRow[] | null), error: ok(error) };
    },

    recordWithdrawal: async (tripId, driverId, reason) => {
      const { error } = await service.from('trip_withdrawals').upsert(
        { trip_id: tripId, driver_id: driverId, reason },
        { onConflict: 'trip_id,driver_id' },
      );
      return { error: ok(error) };
    },

    hasWithdrawn: async (tripId, driverId) => {
      // `limit(1)` rather than fetching the row: all this needs to know is
      // whether it exists. `count: 'exact'` would be a second full count the
      // caller has no use for.
      const { data, error } = await service
        .from('trip_withdrawals')
        .select('trip_id')
        .eq('trip_id', tripId)
        .eq('driver_id', driverId)
        .limit(1);
      return { row: !!(data && data.length > 0), error: ok(error) };
    },

    releaseDriver: async (driverId) => {
      const { error } = await service
        .from('profiles')
        .update({ availability: 'online' })
        .eq('id', driverId);
      return { error: ok(error) };
    },

    releaseOffers: async (tripId) => {
      const { error } = await service
        .from('offers')
        .update({ state: 'released' })
        .eq('trip_id', tripId)
        .eq('state', 'pending');
      return { error: ok(error) };
    },
  };
}