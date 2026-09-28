import 'package:flutter/foundation.dart';

import '../data/booked_trip.dart';
import '../data/failure_message.dart';
import '../data/trip_repository.dart';

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

  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    _error = null;
    // Painted as a spinner over the previous list rather than replacing it, so
    // a pull-to-refresh that fails leaves the rider's last known list readable
    // instead of blanking it.
    notifyListeners();
    try {
      final rows = await _trips.history();
      _rows = rows;
      _state = BookingsStatus.loaded;
    } on Object catch (e) {
      _error = describeFailure(e);
      // A failed first load is a failed screen. A failed refresh is not, and
      // turning the first into an empty list would print "No rides yet" over a
      // network problem, which is a lie a rider acts on.
      if (_state != BookingsStatus.loaded) _state = BookingsStatus.failed;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }
}
