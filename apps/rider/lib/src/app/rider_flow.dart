import 'package:flutter/foundation.dart';
import 'package:mng_core/mng_core.dart';

import '../booking/route_confirm_page.dart';
import '../data/trip_functions.dart';
import '../data/trip_repository.dart';
import '../trip/trip_controller.dart';

/// There is no promo code.
//
// RIDE30 was here and it was wrong in three separate ways: it went on every
// ride with no redemption record, the banner said "first ride" while nothing
// enforced a first ride, and the server capped the discount at GHS 40 while the
// app did not cap it at all -- so above GHS 133.33 the rider agreed to a number
// lower than the one they were charged.
//
// The offer is withdrawn rather than reduced. Keeping it at 3% would keep two
// calculations alive -- the gross and the net -- and the only thing that number
/// was for was to be wrong.

/// The ride flow, from tapping search to seeing a receipt.
///
/// Owns only the two things a screen cannot work out for itself: which step of
/// the flow the rider is on, and the trip itself. Every server call is delegated
/// -- the trip row to `TripRepository`, the settlement and the demo payment to
/// `TripController` -- so nothing here duplicates a rule that already has a
/// test against it.
class RiderFlow extends ChangeNotifier {
  RiderFlow({required this.trips, required this.functions})
    : calc = FareCalculator(),
      controller = TripController(trips: trips, functions: functions);

  final TripRepository trips;
  final TripFunctions functions;
  final FareCalculator calc;
  final TripController controller;

  bool _requesting = false;
  bool get requesting => _requesting;

  String? _requestError;
  String? get requestError => _requestError;

  RouteDraft? _draft;
  RouteDraft? get draft => _draft;

  /// Puts the flow back at the home screen and forgets the finished trip.
  void reset() {
    _requesting = false;
    _requestError = null;
    _draft = null;
    notifyListeners();
  }

  /// Asks the server for a ride on the drafted route. The returned trip is in
  /// `requested` state; the rider moves to the finding-driver screen and waits
  /// for a driver to accept one of the offers.
  Future<Trip?> requestRide(RouteDraft draft) async {
    _draft = draft;
    _requesting = true;
    _requestError = null;
    notifyListeners();
    try {
      final trip = await trips.requestRide(
        pickup: draft.pickup,
        dropoff: draft.dropoff,
        category: draft.category,
      );
      return trip;
    } on Object catch (e) {
      _requestError = e.toString();
      return null;
    } finally {
      _requesting = false;
      notifyListeners();
    }
  }

  /// Re-reads the rider's active trip. Polled rather than streamed on purpose:
  /// during a pilot a visible, loggable number of round trips is worth more
  /// than a silent subscription, and a stream that never connects looks
  /// identical to a trip nobody accepted.
  Future<Trip?> refreshActive() async {
    try {
      return await trips.activeTrip();
    } on Object catch (e) {
      _requestError = e.toString();
      notifyListeners();
      return null;
    }
  }
}
