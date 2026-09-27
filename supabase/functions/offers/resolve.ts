// The decision rules, with no I/O in them, so the rule set is testable without
// a live project.
//
// `resolveAccept` is a *mirror* of the `accept_offer` RPC, not a gate. The
// handler does not consult it before calling the RPC, and must not: the RPC
// decides under a lock on the trip row, and any answer computed before the call
// would be stale by the time it mattered. It exists so the rules are pinned by
// tests, and the lock behaviour is pinned by
// supabase/tests/verify_concurrency.sql, which fires two real concurrent
// accepts against the real RPC.

export type OfferStateName = 'pending' | 'accepted' | 'declined' | 'expired' | 'released';

export type TripStateName =
  | 'requested' | 'matched' | 'arriving' | 'ongoing' | 'completed' | 'cancelled';

export interface OfferRow {
  id: string;
  driverId: string;
  state: OfferStateName;
  tripId: string;
  // The trip's state as of the read, which is the authoritative value. The RPC
  // reads the trip under `for update` and tests that row (migration:373), so
  // the mirror reads the same row rather than a value handed to it by a caller.
  tripState: TripStateName;
  expiresAt: string;
}

export interface AcceptResult {
  accepted: boolean;
  winnerDriverId: string | null;
  released: string[];
  // Null only when the offer was not found, because then there is no trip to
  // have a state.
  nextTripState: TripStateName | null;
  reason: string;
}

// A refusal carrying the status to send it with, so the handler has one shape
// for "this caller may not do that to this offer" whatever the reason.
export interface Refusal {
  status: number;
  reason: string;
}

export type DeclineResult = { declined: true } | ({ declined: false } & Refusal);

export function resolveAccept(input: {
  existingOffers: OfferRow[];
  chosenOfferId: string;
}): AcceptResult {
  const reject = (reason: string, nextTripState: TripStateName | null): AcceptResult => ({
    accepted: false,
    winnerDriverId: null,
    released: [],
    nextTripState,
    reason,
  });

  // Order matches the RPC's own: it tests that the offer exists (migration:304-307)
  // before it tests the trip, so an unknown id reports "offer not found" even
  // when the trip is long gone. The brief passed the trip state in separately
  // and tested it first, which is both a caller-supplied value the code never
  // cross-checked against the row and the opposite order to the database.
  const chosen = input.existingOffers.find((o) => o.id === input.chosenOfferId);
  if (!chosen) return reject('offer not found', null);
  if (chosen.tripState !== 'requested') {
    return reject('trip is no longer awaiting a driver', chosen.tripState);
  }
  if (chosen.state !== 'pending') return reject(`offer already ${chosen.state}`, chosen.tripState);

  // Inclusive, and it has to stay inclusive. The RPC refuses the offer with
  // `v_offer.expires_at <= now()` (migration:375), and probe 9 of
  // supabase/tests/verify_offer_authz.sql measures that an offer whose
  // `expires_at` is exactly `now()` is refused, with the offer moved to
  // `expired`. Task 4's `Offer.isExpired` reads
  // `DateTime.now().isAfter(expiresAt)` (offer.dart:35), which is the strict
  // comparison, so the two disagree at exactly `expiresAt`. This side is the one
  // that matches the database; Task 4 is the side to change. Do not "fix" this
  // to match Dart.
  if (new Date(chosen.expiresAt).getTime() <= Date.now()) {
    return reject('offer expired', chosen.tripState);
  }

  // The offer TTL is not read here and is not configurable: Task 6 writes
  // `expires_at` 20 seconds out (request-ride/index.ts:9) and this test only
  // compares against the value already on the row.
  return {
    accepted: true,
    winnerDriverId: chosen.driverId,
    released: input.existingOffers
      .filter((o) => o.id !== chosen.id && o.state === 'pending')
      .map((o) => o.id),
    nextTripState: 'matched',
    reason: 'ok',
  };
}

// The decline needs three facts, and they are not available at the same moment:
// the row comes from the caller's own read and the row count from the write
// that follows it. So the decision is two functions and the handler has to call
// both. Each returns a refusal rather than a boolean so that "not your offer"
// and "already accepted" cannot be collapsed into one silent no.

// `state` is a plain string, not `OfferStateName`. The value arrives from the
// database, and anything outside the enum is then not 'pending', so it is
// refused rather than written. An unrecognised state must never be the reason a
// decline is reported as having happened.
export interface DeclineRow {
  driverId: string;
  state: string;
}

// Stage one, before the write: may this caller write `declined` on this row at
// all? Returns null when the write may go ahead.
//
// The ownership test is not optional and it is not the same test as "the read
// found a row". `rider reads offers on own trip` (migration:532) lets the
// trip's own rider read every offer on it, and probe 5 measures that the rider
// does read the row and is still refused by the RPC afterwards. A row from the
// read therefore proves the caller may *see* the offer, and only the
// `driver_id` comparison proves it is theirs.
export function declineRefusal(input: {
  row: DeclineRow | null;
  callerDriverId: string;
}): Refusal | null {
  if (!input.row) return { status: 404, reason: 'offer not found' };
  if (input.row.driverId !== input.callerDriverId) {
    return { status: 404, reason: 'offer not found' };
  }
  if (input.row.state !== 'pending') {
    return { status: 409, reason: `offer is already ${input.row.state}` };
  }
  return null;
}

// Stage two, after the write: did the write change a row? Zero did not.
//
// This is the check whose absence makes the whole decline path a lie. The write
// is filtered on `id`, `driver_id` and `state = 'pending'`, and all three can
// stop matching between the read and the write: a rival accept takes the offer,
// a second decline from the same driver takes it, or the row is gone. The
// client reports `error = null` in every one of those cases, so the row count is
// the only evidence, and a decline that changed nothing must not answer
// `{declined: true}`.
//
// `id` is the offers primary key (migration:78) and the write filters on it, so
// 0 and 1 are the only counts reachable. Anything else is unreachable, and is
// refused on the same ground rather than waved through.
export function confirmDecline(updated: number): DeclineResult {
  if (updated === 1) return { declined: true };
  return { declined: false, status: 409, reason: 'offer is no longer pending' };
}
