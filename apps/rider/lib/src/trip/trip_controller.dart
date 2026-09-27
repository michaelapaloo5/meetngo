import 'package:flutter/foundation.dart';
import 'package:mng_core/mng_core.dart';

import '../data/trip_functions.dart';
import '../data/trip_repository.dart';
import 'receipt_screen.dart' show Settlement;

/// The settlement and the demo payment, as state a screen can read and a test can
/// drive.
///
/// All three of these methods are the only outlets on this class, and anything
/// escaping one reaches the framework as an unhandled async error rather than as
/// anything the rider can read, so all three catch. The catch is on `Object` and
/// not on `Exception`, and that is load-bearing rather than defensive: a 200
/// whose `trip` lacks a column throws a `TypeError` out of `Trip.fromJson`, and
/// a `TypeError` is an `Error`, not an `Exception`. Measured with such a body
/// before this was widened, `complete()` threw `_TypeError` out of the method
/// with `error == null` -- the unreadable failure this paragraph exists to
/// prevent. All three also apply the discipline Task 10 applied to `sosRaised` on
/// `TrackingController`:
///
///  * every failure path sets `error`, and **none** of them clears
///    `settlement`. A receipt that was already on screen and a rating that then
///    failed is a receipt the rider already has; a failed `complete` that blanked
///    the total would take away the one fact the screen exists to show.
///  * `busy` is turned off in a `finally` that always notifies, so no path can
///    leave a button permanently disabled.
///
/// There is deliberately no client-side `canTransition(state, completed)` guard
/// on `complete`, even though `TrackingController.cancel` has one. The local trip
/// is a cache: the driver's app moves the state under the rider, so a rider whose
/// copy still says `arriving` is exactly the rider whose call the server would
/// accept. The function refuses a trip that is not `completed` with a 409 whose
/// `error` key this class reports, and that refusal is made against the row the
/// database holds.
class TripController extends ChangeNotifier {
  TripController({
    required this.trips,
    required this.functions,
    Trip? initialTrip,
  }) : _trip = initialTrip;

  final TripRepository trips;
  final TripFunctions functions;

  Trip? _trip;
  Trip? get trip => _trip;

  bool _busy = false;
  bool get busy => _busy;

  String? _error;
  String? get error => _error;

  Settlement? _settlement;
  Settlement? get settlement => _settlement;

  PaymentState? _paymentState;
  PaymentState? get paymentState => _paymentState;

  /// Settles a finished trip and optionally records the rider's rating of the
  /// driver in the same call.
  ///
  /// `complete-trip` is the only path that can write a `ratings` row: the table
  /// carries a SELECT policy and no INSERT policy (`init.sql:555-556`), so RLS
  /// default-denies the rider's own credential, and this function has already
  /// authenticated the caller and established that the caller is one of the
  /// trip's two parties.
  ///
  /// The driver's half of the two-way rating is Task 14's, in the driver's app.
  /// `unique (trip_id, from_role)` (`init.sql:141`) is what makes the two of them
  /// one row each.
  Future<void> complete({int? stars, String comment = ''}) async {
    final current = _trip;
    if (current == null) {
      _error = 'There is no trip to complete';
      notifyListeners();
      return;
    }
    // The same rule the function enforces, checked here so a rider who cannot
    // pick a star never spends a round trip on a request that is going to be
    // refused. `Rating.isValidStars` is 1..5 (`mng_core/lib/src/models/
    // rating.dart:24`); the same values would be a 400 from
    // `check (stars between 1 and 5)` (`init.sql:138`) if they got through.
    if (stars != null && !Rating.isValidStars(stars)) {
      _error = 'Pick a rating from 1 to 5';
      notifyListeners();
      return;
    }
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final data = await functions.invoke('complete-trip', {
        'tripId': current.id,
        // Omitted rather than sent as null: a `rating` of null is not the same
        // request as no rating at all, and the function's reader treats an
        // absent key as "no rating to save".
        if (stars != null) 'rating': {'stars': stars, 'comment': comment},
      });
      _apply(data);
    } on Object catch (e) {
      // `settlement` is deliberately untouched. It is not cleared here, and not
      // set to null, because a failed call is not evidence that the money did
      // not move -- and a screen that blanks a total it already showed is
      // claiming the trip was not paid.
      _report(e);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Records a demo charge for the trip. Never contacts a provider: the
  /// `payments` row it writes carries `is_demo = true` and the migration
  /// refuses any other value (`init.sql:176`).
  Future<void> pay({required PayMethod method}) async {
    final current = _trip;
    if (current == null) {
      _error = 'There is no trip to pay for';
      notifyListeners();
      return;
    }
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final data = await functions.invoke('demo-pay', {
        'tripId': current.id,
        // `method.name` and not a hardcoded `momo`: the enum is the only place
        // the three values `pay_method` allows are named on this side
        // (`init.sql:9`), and a hardcoded value would make `pay(method: cash)`
        // charge a MoMo row.
        'method': method.name,
      });
      final state = _paymentStateOf(data['state']);
      if (state != null) _paymentState = state;
    } on Object catch (e) {
      _report(e);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Reads the rider's own active trip. A receipt screen needs the row the
  /// database holds, not the copy the controller was constructed with.
  Future<void> refresh() async {
    try {
      final fresh = await trips.activeTrip();
      if (fresh != null) _trip = fresh;
    } on Object catch (e) {
      // The trip on screen is left as it was: a failed read is not evidence
      // about the trip, and replacing it with nothing would take away the only
      // thing a settlement screen has to show.
      _report(e);
    }
    notifyListeners();
  }

  void _apply(Map<String, dynamic> data) {
    // The **money first, the row last**, and the order is the point rather than
    // the order the body would read most naturally in. `Trip.fromJson` casts with
    // `as` and no null case, so a row that does not parse throws a `TypeError`,
    // and whatever is read before the throw is what survives it. Applied in this
    // order, a response whose `trip` is unreadable still leaves the rider a total
    // and a payment state, which are the two facts a receipt exists to show, and
    // `trip` keeps the copy the controller already had. The throw is caught one
    // level up by `complete`'s `on Object` and reported by `_report` as a row
    // this app cannot read, not as a network failure: the response arrived, so
    // claiming otherwise would be a lie.
    final settlement = _settlementOf(data['settlement']);
    if (settlement != null) _settlement = settlement;
    final paymentState = _paymentStateOf(data['paymentState']);
    if (paymentState != null) _paymentState = paymentState;
    // The rating is the one part of the response that can have failed on a call
    // that otherwise succeeded, and the function answers 200 for it on purpose
    // (`complete-trip/handler.ts`, `rateTrip`): the money is already written, so
    // a failed rating must not unsettle the trip. It is reported here as an
    // error the rider can read, and `settlement` above is still stored.
    if (data['ratingState'] == 'failed') {
      final reason = data['ratingError'];
      _error = reason is String && reason.isNotEmpty
          ? reason
          : 'Your rating was not saved';
    }
    // The row the function echoed is the row the database holds, and the local
    // copy can be a state behind: the driver's app moves the state under the
    // rider. Read last, for the reason at the top of this method.
    final trip = data['trip'];
    if (trip is Map) _trip = Trip.fromJson(trip.cast<String, dynamic>());
  }

  /// The message for a failure, and which of the three buckets it fell into.
  ///
  /// An `Object` rather than an `Exception`, because the clause that calls this
  /// is `on Object` and a `TypeError` from a row this app cannot read is the case
  /// that most needs a message. It is deliberately **not** reported as a network
  /// failure: the response arrived, and "Could not reach the server" on a screen
  /// that already has a receipt on it is a lie the rider cannot act on.
  void _report(Object failure) {
    if (failure is TripRequestFailure) {
      _error = failure.message;
      return;
    }
    _error = failure is Exception ? _unreachable : _unreadable;
  }

  /// A number off a JSON body, or null when it is not one. A `num` is what a
  /// `numeric` column arrives as; anything else leaves the field alone rather
  /// than settling a total out of a string or a null.
  static double? _number(Object? raw) =>
      raw is num && raw.isFinite ? raw.toDouble() : null;

  /// The four numbers or nothing. A settlement with a missing or non-numeric
  /// field is not a settlement, and storing a partly-read one would put a
  /// `GHS NaN` on a receipt.
  static Settlement? _settlementOf(Object? raw) {
    if (raw is! Map) return null;
    final fare = _number(raw['fareGhs']);
    final commission = _number(raw['commissionGhs']);
    final payout = _number(raw['driverPayoutGhs']);
    if (fare == null || commission == null || payout == null) return null;
    return Settlement(fareGhs: fare, commissionGhs: commission, driverPayoutGhs: payout);
  }

  /// A `PaymentState` off a JSON string, or null. `byName` throws on a name the
  /// enum does not carry, and a `StateError` escaping `complete` would reach the
  /// framework rather than the rider.
  static PaymentState? _paymentStateOf(Object? raw) {
    if (raw is! String) return null;
    for (final state in PaymentState.values) {
      if (state.name == raw) return state;
    }
    return null;
  }

  /// The message for a call that never reached the function. Every failure here
  /// is a `TripRequestFailure` carrying the function's own `error` string, so
  /// this is the fallback for anything else -- a `TypeError` from a null
  /// assertion, say, which is an `Error` and not an `Exception` and is
  /// deliberately not caught.
  static const _unreachable = 'Could not reach the server';

  /// For a response this app could not read: a row missing a column
  /// `Trip.fromJson` casts, or a fault in this file. Distinct from
  /// [_unreachable] so a rider is never told the server is down when it answered.
  static const _unreadable = 'The trip details could not be read';
}
