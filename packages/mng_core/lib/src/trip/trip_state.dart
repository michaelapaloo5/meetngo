/// Mirrors the Postgres `trip_state` enum and the DB trigger that rejects
/// illegal moves. See spec section 4.5.
enum TripState {
  requested,
  matched,
  arriving,
  ongoing,
  completed,
  cancelled;

  bool get isActive =>
      this == requested ||
      this == matched ||
      this == arriving ||
      this == ongoing;

  bool get isTerminal => this == completed || this == cancelled;
}

class IllegalTripTransition implements Exception {
  const IllegalTripTransition(this.from, this.to);

  final TripState from;
  final TripState to;

  @override
  String toString() =>
      'IllegalTripTransition: cannot move trip from $from to $to';
}

const Map<TripState, Set<TripState>> _legal = {
  TripState.requested: {TripState.matched, TripState.cancelled},
  TripState.matched: {TripState.arriving, TripState.cancelled},
  // `requested` is the driver abandoning a trip they started driving towards, and
  // it is the only backwards move here: it is the one `leave-trip` performs when
  // it puts a trip back in the pool. `matched -> requested` is deliberately NOT
  // legal -- declining before moving is `offers/decline`, which never reaches this
  // table. Mirrors migration 20260930000010.
  TripState.arriving: {
    TripState.ongoing,
    TripState.cancelled,
    TripState.requested,
  },
  TripState.ongoing: {TripState.completed},
  TripState.completed: {},
  TripState.cancelled: {},
};

bool canTransition(TripState from, TripState to) =>
    _legal[from]?.contains(to) ?? false;

TripState nextState(TripState from, TripState to) {
  if (!canTransition(from, to)) {
    throw IllegalTripTransition(from, to);
  }
  return to;
}
