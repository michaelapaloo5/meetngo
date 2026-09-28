import 'package:flutter/foundation.dart';
import 'package:mng_core/mng_core.dart';

import '../data/driver_repository.dart';

/// The one live trip, as state a screen can read and a test can drive.
///
/// The local [trip] is a cache of the row, and every move is written before it
/// is believed: [advance] and [submitPickupOtp] both wait for
/// `advanceTripState` and only then change [trip]. The other order reports a
/// state the database rejected, which is the bug
/// `enforce_trip_transition` exists to make impossible to hide.
class ActiveTripController extends ChangeNotifier {
  ActiveTripController(this._repo);

  final DriverRepository _repo;

  Trip? trip;
  String? error;
  bool busy = false;

  static const _actionLabels = {
    TripState.matched: 'Start navigation',
    TripState.arriving: 'Arrived at pickup',
    TripState.ongoing: 'Complete the trip',
    TripState.completed: 'Trip finished',
  };

  String get headline => switch (trip?.state) {
        TripState.matched => 'New trip assigned',
        TripState.arriving => 'Collect your rider',
        TripState.ongoing => 'On the way',
        TripState.completed => 'Trip finished',
        _ => 'No active trip',
      };

  String get primaryActionLabel => _actionLabels[trip?.state] ?? 'No action';

  bool get canAdvance {
    final state = trip?.state;
    return state == TripState.matched ||
        state == TripState.arriving ||
        state == TripState.ongoing;
  }

  /// True once the trip is over, and the screen's cue to hand back to the shell.
  ///
  /// Separate from [canAdvance] on purpose. The plan derived the button's
  /// enabled state from `canAdvance`, which is false at `completed`, so the one
  /// button that ends the trip could never be pressed and `onFinished` was
  /// unreachable.
  bool get isFinished => trip?.state == TripState.completed;

  Future<bool> advance() async {
    error = null;
    final current = trip;
    if (current == null || !canAdvance) {
      error = 'Nothing to advance';
      notifyListeners();
      return false;
    }
    if (current.state == TripState.arriving) {
      error = 'Enter the pickup code to start the trip';
      notifyListeners();
      return false;
    }
    final to = switch (current.state) {
      TripState.matched => TripState.arriving,
      TripState.ongoing => TripState.completed,
      _ => null,
    };
    if (to == null) return false;

    busy = true;
    notifyListeners();
    try {
      await _repo.advanceTripState(current.id, to);
      trip = current.copyWith(state: to);
      return true;
    } on DriverAuthFailure catch (e) {
      error = e.message;
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Checks the rider's 4-digit code and, only if it is right, starts the trip.
  ///
  /// Length is checked before the network call so a two-digit code is a message
  /// on the screen rather than a round trip.
  Future<bool> submitPickupOtp(String code) async {
    error = null;
    final current = trip;
    if (current == null || current.state != TripState.arriving) {
      error = 'No trip waiting for a pickup code';
      notifyListeners();
      return false;
    }
    if (code.trim().length != 4) {
      error = 'The pickup code is 4 digits';
      notifyListeners();
      return false;
    }
    busy = true;
    notifyListeners();
    try {
      await _repo.verifyPickupOtp(current.id, code);
      await _repo.advanceTripState(current.id, TripState.ongoing);
      trip = current.copyWith(state: TripState.ongoing);
      return true;
    } on DriverAuthFailure catch (e) {
      error = e.message;
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}
