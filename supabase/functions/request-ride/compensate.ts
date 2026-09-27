// The trip insert and the offer fan-out are two separate calls, so a failure in
// the second leaves a `requested` trip with no offers behind it. Task 8's
// `activeTrip()` selects `requested` trips, so that orphan pins the rider's
// active trip and blocks every later ride request until the row is removed by
// hand. The compensation is safe in this window: the row was created moments
// earlier, `offers.trip_id` is `references trips on delete cascade` so any
// partially written offers go with it, and nothing can have come to depend on
// it yet.
//
// A delete is the whole fix. No ledger entry, no retry, no Task 5 RPC: the row
// never became a real trip.

export type DeleteTrip = (tripId: string) => Promise<{ error: { message: string } | null }>;

export type CompensatedFailure = {
  error: string;
  cleanupError?: string;
};

export async function deleteTripAndFail(
  deleteTrip: DeleteTrip,
  tripId: string,
  message: string,
): Promise<CompensatedFailure> {
  const { error } = await deleteTrip(tripId);
  // A delete that fails leaves the orphan in place, so the response says so
  // rather than reporting a clean 500 and hiding a row nothing will clean up.
  return error ? { error: message, cleanupError: error.message } : { error: message };
}
