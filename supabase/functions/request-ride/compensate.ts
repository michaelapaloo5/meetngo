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

export type Outcome<T> = { ok: true; value: T } | ({ ok: false } & CompensatedFailure);

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

// Runs the offer fan-out, and compensates the trip insert if it does not
// finish. A *checked* failure — a 42501 from the match RPC, a rejected offers
// insert — is reported the same way as an *unchecked* one, because both mean the
// same thing: a `requested` trip that no driver was ever offered and that Task
// 8's `activeTrip()` will keep handing back. The unchecked route is the one
// that needed guarding: it used to escape to `serve`'s default onError, which
// returns a bare 500 and leaves the row behind.
export async function compensating<T>(
  deleteTrip: DeleteTrip,
  tripId: string,
  work: () => Promise<T>,
): Promise<Outcome<T>> {
  try {
    return { ok: true, value: await work() };
  } catch (thrown) {
    const message = thrown instanceof Error ? thrown.message : String(thrown);
    return { ok: false, ...(await deleteTripAndFail(deleteTrip, tripId, message)) };
  }
}

