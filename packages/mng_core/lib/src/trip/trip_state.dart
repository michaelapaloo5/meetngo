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
      this == requested || this == matched || this == arriving || this == ongoing;

  bool get isTerminal => this == completed || this == cancelled;
}

class IllegalTripTransition implements Exception {
  const IllegalTripTransition(this.from, this.to);

  final TripState from;
  final TripState to;

  @override
  String toString() => 'IllegalTripTransition: cannot move trip from $from to $to';
}

const Map<TripState, Set<TripState>> _legal = {
  TripState.requested: {TripState.matched, TripState.cancelled},
  TripState.matched: {TripState.arriving, TripState.cancelled},
  TripState.arriving: {TripState.ongoing, TripState.cancelled},
  TripState.ongoing: {TripState.completed},
  TripState.completed: {},
  TripState.cancelled: {},
};

bool canTransition(TripState from, TripState to) => _legal[from]!.contains(to);

TripState nextState(TripState from, TripState to) {
  if (!canTransition(from, to)) {
    throw IllegalTripTransition(from, to);
  }
  return to;
}
