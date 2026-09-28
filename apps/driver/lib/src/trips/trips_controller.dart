import 'package:flutter/foundation.dart';

import '../data/driver_repository.dart';
import '../data/driver_trip.dart';

/// The driver's own trip history.
///
/// A `ChangeNotifier` rather than a `FutureBuilder` inside the screen for the
/// reason `EarningsController` is one: the shell owns the instance, so a
/// rebuild does not start a second read and a half-drawn screen is never
/// shown, and the error survives a tab switch instead of disappearing when the
/// screen is torn down.
///
/// [load] never throws. A failed read is [error] and an empty list, because a
/// history that cannot be read and a history with nothing in it are both a
/// screen with no rows, and only one of them should say so.
class TripsController extends ChangeNotifier {
  TripsController(this._repo);

  final DriverRepository _repo;

  List<DriverTrip> _trips = const [];
  List<DriverTrip> get trips => _trips;

  bool _loading = false;
  bool get loading => _loading;

  String? _error;
  String? get error => _error;

  /// Whether the read succeeded and there was genuinely nothing to show.
  ///
  /// Separate from [_trips] being empty on purpose: the empty state has to
  /// distinguish "you have not driven yet" from "we could not read your trips",
  /// and the first frame of either looks identical to a list that has not been
  /// loaded.
  bool _loadedOnce = false;
  bool get loadedOnce => _loadedOnce;

  Future<void> load() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _trips = await _repo.myTrips();
    } on DriverAuthFailure catch (e) {
      _error = e.message;
    } on Object catch (e) {
      // A row the model cannot read throws a `TypeError`, which is an `Error`.
      // Catching only `DriverAuthFailure` would let that reach the framework as
      // an unhandled async error with nothing on the driver's screen.
      _error = e.toString();
    } finally {
      _loading = false;
      _loadedOnce = true;
      notifyListeners();
    }
  }
}
