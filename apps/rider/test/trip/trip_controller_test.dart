import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/data/trip_functions.dart';
import 'package:meetngo_rider/src/data/booked_trip.dart';
import 'package:meetngo_rider/src/data/location_service.dart';
import 'package:meetngo_rider/src/data/trip_repository.dart';
import 'package:meetngo_rider/src/trip/trip_controller.dart';
import 'package:mng_core/mng_core.dart';

Trip tripInState(TripState state) => Trip(
      id: 't1',
      riderId: 'r1',
      driverId: 'd1',
      category: RideCategory.standard,
      state: state,
      pickup: const TripStop('P', GeoPoint(5.6037, -0.1870), 'Osu, Accra'),
      dropoff: const TripStop('D', GeoPoint(5.6052, -0.1660), 'Airport Residential'),
      distanceKm: 2.4,
      fareGhs: 20.40,
      isDemo: true,
    );

/// The body `complete-trip` answers with on a settled trip, written by hand to
/// the shape its `json()` helper produces: a JSON object with `settlement` and
/// `paymentState` in it, and the three money numbers as JSON numbers because
/// that is what a `numeric` column serialises as.
Map<String, dynamic> settledBody({String ratingState = 'skipped'}) => {
      'trip': {
        'id': 't1',
        'rider_id': 'r1',
        'driver_id': 'd1',
        'category': 'standard',
        'state': 'completed',
        'pickup': {
          'label': 'Osu',
          'address': 'Osu, Accra',
          'point': {'lat': 5.6037, 'lng': -0.1870},
        },
        'dropoff': {
          'label': 'Airport',
          'address': 'Airport Residential',
          'point': {'lat': 5.6052, 'lng': -0.1660},
        },
        'distance_km': 2.4,
        'fare_ghs': 20.4,
        'is_demo': true,
        'eta_minutes': null,
      },
      'settlement': const {
        'fareGhs': 20.40,
        'commissionGhs': 3.06,
        'driverPayoutGhs': 17.34,
      },
      'paymentState': 'succeeded',
      'ratingState': ratingState,
    };

/// Records every call and answers from `answers`, so a test can see what the
/// controller *asked for* and not only what it did with the answer.
class FakeTripFunctions implements TripFunctions {
  final List<({String name, Map<String, dynamic> body})> calls = [];

  /// Thrown by the next call, then the repository behaves.
  Object? failure;

  /// A completer the next call waits on, so `busy` can be read mid-flight.
  Completer<void>? gate;

  /// The body the next call answers with. Null answers with `{}`.
  Map<String, dynamic>? answer;

  @override
  Future<Map<String, dynamic>> invoke(String name, Map<String, dynamic> body) async {
    calls.add((name: name, body: body));
    final pending = gate;
    if (pending != null) await pending.future;
    final thrown = failure;
    if (thrown != null) {
      failure = null;
      throw thrown;
    }
    return answer ?? const {};
  }
}

class FakeTripRepository implements TripRepository {
  @override
  Future<DriverContact> driverContact(String tripId) async =>
      const DriverContact.unavailable();


  @override
  Future<List<BookedTrip>> history({
    int limit = 50,
    Set<TripState>? states,
    DateTime? since,
    String? search,
  }) async => const [];

  @override
  Future<DeviceLocation> locate() async =>
      const DeviceLocation(LocationOutcome.denied);
  /// Thrown by `activeTrip` when set.
  Object? refreshFailure;

  /// The row `activeTrip` answers with. Null by default.
  Trip? active;

  /// Where the assigned driver is, for the tests that draw the car.
  VehicleFix? driverPoint;

  @override
  Future<Trip?> activeTrip() async {
    final thrown = refreshFailure;
    if (thrown != null) throw thrown;
    return active;
  }

  @override
  Stream<Trip> watchTrip(String tripId) => const Stream<Trip>.empty();

  @override
  Future<Trip> requestRide({
    required TripStop pickup,
    required TripStop dropoff,
    required RideCategory category,
    String? promoCode,
  }) async =>
      tripInState(TripState.requested);

  @override
  Future<VehicleFix?> assignedDriverLocation(String? driverId) async => driverPoint;
  @override
  Future<void> cancelTrip(String tripId) async {}

  @override
  Future<GeoPoint?> currentLocation() async => null;

  @override
  Future<void> raiseSos(String tripId, String note) async {}
}

/// Every test that wants a trip gets one from here. The two that want *no* trip
/// build the controller themselves, because a `??` in a helper cannot tell
/// "passed null" from "passed nothing" -- and a helper that quietly supplied a
/// trip would have had both of those tests pass against a controller that
/// ignored the call entirely.
TripController controllerWith({
  FakeTripFunctions? functions,
  FakeTripRepository? trips,
  Trip? initialTrip,
}) =>
    TripController(
      trips: trips ?? FakeTripRepository(),
      functions: functions ?? FakeTripFunctions(),
      initialTrip: initialTrip ?? tripInState(TripState.completed),
    );

TripController controllerWithNoTrip(FakeTripFunctions functions) => TripController(
      trips: FakeTripRepository(),
      functions: functions,
    );

void main() {
  // --- complete() ---------------------------------------------------------

  test('complete invokes complete-trip with the trip id and stores the settlement', () async {
    final functions = FakeTripFunctions()..answer = settledBody();
    final c = controllerWith(functions: functions);

    await c.complete();

    expect(functions.calls.single.name, 'complete-trip');
    expect(functions.calls.single.body, {'tripId': 't1'});
    expect(c.settlement, isNotNull);
    expect(c.settlement!.fareGhs, 20.40);
    expect(c.settlement!.commissionGhs, 3.06);
    expect(c.settlement!.driverPayoutGhs, 17.34);
    expect(c.paymentState, PaymentState.succeeded);
    expect(c.error, isNull);
  });

  test('complete stores the trip row the function echoed back', () async {
    final functions = FakeTripFunctions()..answer = settledBody();
    final c = controllerWith(functions: functions, initialTrip: tripInState(TripState.ongoing));

    await c.complete();

    // The driver app moves the state under the rider, so the copy the controller
    // was constructed with can be a state behind. The function's row is the one
    // the receipt is about.
    expect(c.trip!.state, TripState.completed);
    expect(c.trip!.fareGhs, 20.40);
    expect(c.trip!.pickup.address, 'Osu, Accra');
  });

  test('a stars of 0, 6 or a negative is refused without a round trip', () async {
    final functions = FakeTripFunctions()..answer = settledBody();
    final c = controllerWith(functions: functions);

    for (final stars in [0, 6, -1, 11]) {
      await c.complete(stars: stars);
      expect(functions.calls, isEmpty, reason: 'stars $stars reached the function');
      expect(c.error, isNotNull, reason: 'stars $stars set no error');
      expect(c.settlement, isNull, reason: 'stars $stars settled something');
    }
  });

  test('stars of 1 to 5 are forwarded with the comment', () async {
    final functions = FakeTripFunctions()..answer = settledBody();
    final c = controllerWith(functions: functions);

    await c.complete(stars: 4, comment: 'Great');

    expect(functions.calls.single.body, {
      'tripId': 't1',
      'rating': {'stars': 4, 'comment': 'Great'},
    });
  });

  test('a call with no stars sends no rating key at all', () async {
    final functions = FakeTripFunctions()..answer = settledBody();
    final c = controllerWith(functions: functions);

    await c.complete();

    // An absent key and a null value are not the same request, and the
    // function's body reader treats an absent rating as "nothing to save".
    expect(functions.calls.single.body.containsKey('rating'), isFalse);
  });

  test('a failed complete sets error and leaves the settlement alone', () async {
    final functions = FakeTripFunctions()..answer = settledBody();
    final c = controllerWith(functions: functions);
    await c.complete();
    expect(c.settlement, isNotNull);

    functions.failure = const TripRequestFailure('ledger write failed');
    await c.complete();

    expect(c.error, 'ledger write failed');
    // Not cleared. A failed second call is not evidence that the money did not
    // move, and blanking the total would tell the rider the trip was unpaid.
    expect(c.settlement, isNotNull);
    expect(c.settlement!.driverPayoutGhs, 17.34);
    expect(c.busy, isFalse);
  });

  test('a transport failure the repository did not shape still says something', () async {
    final functions = FakeTripFunctions()..failure = const FakeTransportException();
    final c = controllerWith(functions: functions);

    await c.complete();

    expect(c.error, 'Could not reach the server');
    expect(c.settlement, isNull);
  });

  test('a response with no settlement in it stores nothing', () async {
    // A 2xx whose body carries neither money nor a payment state. Storing a
    // `GHS NaN` would be worse than storing nothing.
    final functions = FakeTripFunctions()
      ..answer = {
        'settlement': {'fareGhs': 20.4, 'commissionGhs': 'three', 'driverPayoutGhs': 17.34},
        'paymentState': 'nonsense',
      };
    final c = controllerWith(functions: functions);

    await c.complete();

    expect(c.settlement, isNull);
    expect(c.paymentState, isNull);
    expect(c.error, isNull);
  });

  test('a trip row this app cannot read is an error, and keeps the money', () async {
    // `rider_id` deleted from the echoed row. `Trip.fromJson` casts it with
    // `as String`, so this throws a `TypeError`, and a `TypeError` is an `Error`
    // and not an `Exception` -- so a catch on `Exception` does not see it.
    // Measured on this host before the catch was widened: `complete()` threw
    // `_TypeError` out of the method with `error == null` and `settlement == null`,
    // which is an unreadable failure on a method whose whole contract is that
    // the rider can read one. The order in `_apply` is what keeps the money: a
    // bad row costs the row, not the total.
    final body = settledBody();
    final echoed = <String, dynamic>{...body['trip']! as Map<String, dynamic>};
    echoed.remove('rider_id');
    final functions = FakeTripFunctions()
      ..answer = {
        ...body,
        'trip': echoed,
      };
    final c = controllerWith(functions: functions, initialTrip: tripInState(TripState.ongoing));

    await expectLater(c.complete(), completes);

    expect(c.error, isNotNull);
    // Not "Could not reach the server": the response arrived, and telling the
    // rider the server is down when it answered is a lie they cannot act on.
    expect(c.error, isNot('Could not reach the server'));
    expect(c.error, contains('could not be read'));
    // The two facts the receipt exists for survive a row this app cannot parse.
    expect(c.settlement, isNotNull);
    expect(c.settlement!.driverPayoutGhs, 17.34);
    expect(c.paymentState, PaymentState.succeeded);
    // And the trip on screen is the copy the controller already had, not null.
    expect(c.trip, isNotNull);
    expect(c.trip!.state, TripState.ongoing);
    expect(c.busy, isFalse);
  });

  test('a failed rating insert is an error and the settlement still stands', () async {
    // The function answers 200 with `ratingState: 'failed'` on purpose: the money
    // is already written and a rating must not unsettle it. The rider still has
    // to be told the rating did not save.
    final functions = FakeTripFunctions()
      ..answer = {
        ...settledBody(ratingState: 'failed'),
        'ratingError': 'the rating was not saved',
      };
    final c = controllerWith(functions: functions);

    await c.complete(stars: 3, comment: 'ok');

    expect(c.error, 'the rating was not saved');
    expect(c.settlement, isNotNull);
    expect(c.settlement!.fareGhs, 20.40);
    expect(c.paymentState, PaymentState.succeeded);
  });

  test('a duplicate rating is not an error, because the money is what mattered', () async {
    final functions = FakeTripFunctions()..answer = settledBody(ratingState: 'duplicate');
    final c = controllerWith(functions: functions);

    await c.complete(stars: 3, comment: '');

    expect(c.error, isNull);
    expect(c.settlement, isNotNull);
  });

  test('a complete with no trip sets an error and calls nothing', () async {
    final functions = FakeTripFunctions()..answer = settledBody();
    final c = controllerWithNoTrip(functions);

    await c.complete();

    expect(functions.calls, isEmpty);
    expect(c.error, isNotNull);
    expect(c.busy, isFalse);
  });

  // --- pay() --------------------------------------------------------------

  test('pay forwards the method it was given', () async {
    final functions = FakeTripFunctions()
      ..answer = {
        'payment': {
          'id': 'p1',
          'trip_id': 't1',
          'amount_ghs': 20.4,
          'method': 'cash',
          'state': 'pending',
          'is_demo': true,
        },
        'state': 'pending',
      };
    final c = controllerWith(functions: functions);

    await c.pay(method: PayMethod.cash);

    expect(functions.calls.single.name, 'demo-pay');
    expect(functions.calls.single.body, {'tripId': 't1', 'method': 'cash'});
    expect(c.paymentState, PaymentState.pending);
    expect(c.error, isNull);
  });

  test('every PayMethod reaches the function as its own name', () async {
    final functions = FakeTripFunctions()..answer = {'state': 'pending'};
    final c = controllerWith(functions: functions);

    for (final method in PayMethod.values) {
      await c.pay(method: method);
    }

    expect(
      functions.calls.map((call) => call.body['method']),
      PayMethod.values.map((method) => method.name),
    );
  });

  test('a failed pay sets error and does not settle anything', () async {
    final functions = FakeTripFunctions()
      ..failure = const TripRequestFailure('trip is not payable');
    final c = controllerWith(functions: functions);

    await c.pay(method: PayMethod.momo);

    expect(c.error, 'trip is not payable');
    expect(c.settlement, isNull);
    expect(c.busy, isFalse);
  });

  test('a pay with no trip sets an error and calls nothing', () async {
    final functions = FakeTripFunctions();
    final c = controllerWithNoTrip(functions);

    await c.pay(method: PayMethod.momo);

    expect(functions.calls, isEmpty);
    expect(c.error, isNotNull);
  });

  // --- busy ---------------------------------------------------------------

  test('busy is true for the duration of a call and false after it', () async {
    final gate = Completer<void>();
    final functions = FakeTripFunctions()
      ..answer = settledBody()
      ..gate = gate;
    final c = controllerWith(functions: functions);
    final seen = <bool>[];
    c.addListener(() => seen.add(c.busy));

    final pending = c.complete();
    expect(c.busy, isTrue);

    gate.complete();
    await pending;
    expect(c.busy, isFalse);
    // Repainted on the way in and on the way out, and nothing in between: a model
    // that changed without a `notifyListeners` is a screen showing yesterday's
    // state.
    expect(seen, [true, false]);
  });

  test('busy is cleared after a failure too', () async {
    final functions = FakeTripFunctions()..failure = const TripRequestFailure('nope');
    final c = controllerWith(functions: functions);

    await c.pay(method: PayMethod.momo);

    expect(c.busy, isFalse);
  });

  // --- refresh() ----------------------------------------------------------

  test('refresh stores the row the database holds', () async {
    final trips = FakeTripRepository()..active = tripInState(TripState.completed);
    final c = controllerWith(trips: trips, initialTrip: tripInState(TripState.ongoing));

    await c.refresh();

    expect(c.trip!.state, TripState.completed);
    expect(c.error, isNull);
  });

  test('a failed refresh leaves the trip on screen and says why', () async {
    final trips = FakeTripRepository()..refreshFailure = const TripRequestFailure('offline');
    final c = controllerWith(trips: trips, initialTrip: tripInState(TripState.ongoing));

    await c.refresh();

    expect(c.error, 'offline');
    expect(c.trip!.state, TripState.ongoing);
  });
}

/// Stands in for the raw transport exception an HTTP call lets through, so the
/// controller's `on Object` clause is exercised by something that behaves the way
/// the real one does -- an `Exception`, and so routed to "Could not reach the
/// server" rather than to the unreadable-response message. `http` is not a
/// dependency of this package, so its `ClientException` cannot be named here.
class FakeTransportException implements Exception {
  const FakeTransportException();
}
