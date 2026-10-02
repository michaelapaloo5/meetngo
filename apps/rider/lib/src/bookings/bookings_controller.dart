import 'package:flutter/foundation.dart';
import 'package:mng_core/mng_core.dart';

import '../data/booked_trip.dart';
import '../data/failure_message.dart';
import '../data/trip_repository.dart';

/// Which rides the list is showing.
///
/// A **set** of states rather than one, because "Live" is more than one state: a
/// ride that is `arriving` or `started` is just as live as one that is `assigned`,
/// and a single-state filter would show a rider with an arriving car an empty
/// list and tell them they had no rides. A set of states also cannot express the
/// combinations a set of chips would invite -- "active and cancelled" is not a
/// question anybody has.
class BookingsFilter {
  const BookingsFilter({required this.label, this.states});

  /// Shown on the chip.
  final String label;

  /// The trip states to ask for, or null for every state.
  final Set<TripState>? states;

  /// Whether two filters ask the same question, used to skip a pointless reload.
  bool sameAs(BookingsFilter other) => setEquals(other.states, states);
}

/// The filters offered, in order.
class BookingsFilters {
  const BookingsFilters._();

  /// Every ride, newest first.
  static const BookingsFilter all = BookingsFilter(label: 'All');

  /// The rides still in progress.
  ///
  /// Derived from `TripState.isActive` rather than written out, because "live" is
  /// a property of the enum and not a decision this file gets to make. A
  /// hand-copied list of four names would silently stop covering a state the
  /// moment somebody added one, and the failure is invisible: the chip still
  /// renders, it just quietly hides that rider's ride.
  static final BookingsFilter live = BookingsFilter(
    label: 'Live',
    states: <TripState>{
      for (final s in TripState.values)
        if (s.isActive) s,
    },
  );

  static const BookingsFilter completed = BookingsFilter(
    label: 'Done',
    states: <TripState>{TripState.completed},
  );

  static const BookingsFilter cancelled = BookingsFilter(
    label: 'Cancelled',
    states: <TripState>{TripState.cancelled},
  );

  /// The filters offered, in the order the chips are shown.
  ///
  /// **One list, and the UI iterates this and nothing else.** It was built as
  /// `[all, live, ...chips]` with `chips` itself also containing `all`, which
  /// drew two "All" chips side by side. A test caught it; a single ordered
  /// source is the fix, not the test.
  ///
  /// Between them the four chips are exhaustive over `TripState.values`: every
  /// state that `isActive` is under Live, and every `isTerminal` state has its
  /// own. A state in neither category would be a ride the app cannot find, and
  /// `every trip state is reachable from a chip` walks the enum to keep that
  /// true.
  static final List<BookingsFilter> offered = <BookingsFilter>[
    all,
    live,
    completed,
    cancelled,
  ];
}

/// The three states the bookings list can be in.
///
/// Loading, loaded and failed are separate rather than a list plus a nullable
/// message, because a list that is empty and a list that never arrived look
/// identical on screen otherwise: both render nothing between the header and
/// the bottom edge. [BookingsController.trips] being empty inside
/// [BookingsStatus.loaded] is the only combination that may print "No rides
/// yet".
enum BookingsStatus { loading, loaded, failed }

/// The rider's own trips, newest first.
///
/// Reads through [TripRepository.history] rather than filtering a live trip
/// stream, so a rider who last rode a week ago sees that ride and not an empty
/// screen. The read is scoped to `rider_id = auth.uid()` inside the repository,
/// which is the same scope RLS enforces and the reason a rider who is also an
/// assigned driver on someone else's trip does not get that trip here.
class BookingsController extends ChangeNotifier {
  BookingsController(this._trips);

  final TripRepository _trips;

  BookingsStatus _state = BookingsStatus.loading;
  BookingsStatus get state => _state;

  List<BookedTrip> _rows = const [];
  List<BookedTrip> get trips => _rows;

  String? _error;
  String? get error => _error;

  bool _loading = false;
  bool get loading => _loading;

  BookingsFilter _filter = BookingsFilters.all;

  /// The filter the list is currently showing.
  BookingsFilter get filter => _filter;

  /// Which request is in flight, so a slow one cannot overwrite a newer one.
  ///
  /// Chips are tapped faster than a network round trip, so without this the
  /// second read can land before the first and the list ends up showing the
  /// filter the rider has already moved off. That is the same lost-update shape
  /// as the tracking poll that froze on a value the caller had moved past, so it
  /// is guarded here by the number the read was started with rather than by
  /// hoping the requests come back in order.
  int _generation = 0;

  /// The read that is currently running, so a second one can wait for it.
  ///
  /// Needed because [load] coalesces a request that arrives while one is in
  /// flight. Coalescing is right for two pull-to-refreshes and wrong for a chip
  /// tap: a rider who taps "Cancelled" during a read for "Done" must still get
  /// their cancelled rides, not be left holding the previous filter's rows under
  /// a chip that now says something else.
  Future<void> _running = Future<void>.value();

  /// Switch filter and reload.
  ///
  /// Returns immediately; the list updates when the read lands.
  Future<void> setFilter(BookingsFilter next) async {
    if (next.sameAs(_filter)) return;
    _filter = next;
    // Wait for whatever is already in flight rather than dropping this request.
    // The older read is made harmless by [load]'s generation check, so waiting
    // costs one round trip and guarantees the chip and the list agree.
    await _running;
    await load();
  }

  /// Re-read, coalescing with a read that is already running.
  ///
  /// Returns the running read when there is one. The generation number inside is
  /// what makes that safe: a caller that arrives late still gets a future that
  /// completes when the data is in, and never gets the older read's rows.
  Future<void> load() {
    if (_loading) return _running;
    final started = _load();
    _running = started;
    return started;
  }

  Future<void> _load() async {
    _loading = true;
    _error = null;
    // Painted as a spinner over the previous list rather than replacing it, so
    // a pull-to-refresh that fails leaves the rider's last known list readable
    // instead of blanking it.
    notifyListeners();
    final mine = ++_generation;
    try {
      final rows = await _trips.history(states: _filter.states);
      // A read that was already overtaken must not write: it would put the
      // previous filter's rows back under the new chip.
      if (mine != _generation) return;
      _rows = rows;
      _state = BookingsStatus.loaded;
    } on Object catch (e) {
      if (mine != _generation) return;
      _error = describeFailure(e);
      // A failed first load is a failed screen. A failed refresh is not, and
      // turning the first into an empty list would print "No rides yet" over a
      // network problem, which is a lie a rider acts on.
      if (_state != BookingsStatus.loaded) _state = BookingsStatus.failed;
    } finally {
      // Only the newest read may clear the flag, or an overtaken read leaves the
      // controller stuck "loading" with no request running.
      if (mine == _generation) _loading = false;
      notifyListeners();
    }
  }
}
