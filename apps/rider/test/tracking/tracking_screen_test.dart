import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/data/trip_repository.dart';
import 'package:meetngo_rider/src/tracking/finding_driver_screen.dart';
import 'package:meetngo_rider/src/tracking/tracking_controller.dart';
import 'package:meetngo_rider/src/tracking/tracking_screen.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

void useDesignSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

Trip tripInState(TripState state) => Trip(
      id: 't1',
      riderId: 'r1',
      driverId: 'd1',
      category: RideCategory.standard,
      state: state,
      pickup: const TripStop('P', GeoPoint(5.6037, -0.1870), 'Osu, Accra'),
      dropoff:
          const TripStop('D', GeoPoint(5.6052, -0.1660), 'Airport Residential'),
      distanceKm: 2.4,
      fareGhs: 12.50,
      isDemo: true,
    );

/// Stands in for the raw `http.ClientException` a direct PostgREST call lets
/// through, so the controller's `on Exception` clause is exercised by
/// something that behaves the way the real one does — `http` declares
/// `class ClientException implements Exception`
/// (`http-1.6.0/lib/src/exception.dart:6`) — without importing `package:http`,
/// which this package does not depend on.
class FakeTransportException implements Exception {
  const FakeTransportException();
}

class FakeTripRepository implements TripRepository {
  bool cancelled = false;
  bool sosRaised = false;
  String? cancelledTripId;
  String? sosTripId;
  int sosCalls = 0;
  int cancelCalls = 0;

  /// Thrown by the next `sosCalls` writes, then the repository behaves.
  Object? sosFailure;

  /// Thrown by `cancelTrip` when set.
  Object? cancelFailure;

  /// Thrown by `activeTrip` when set.
  Object? refreshFailure;

  /// The row `activeTrip` answers with. Null by default, so `refresh` takes its
  /// early return and the trip on screen is not replaced.
  Trip? active;

  @override
  Future<Trip?> activeTrip() async {
    final failure = refreshFailure;
    if (failure != null) throw failure;
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
  Future<GeoPoint?> currentLocation() async => null;

  @override
  Future<void> cancelTrip(String tripId) async {
    final failure = cancelFailure;
    if (failure != null) throw failure;
    cancelled = true;
    cancelledTripId = tripId;
  }

  @override
  Future<void> raiseSos(String tripId, String note) async {
    sosCalls++;
    final failure = sosFailure;
    if (failure != null) {
      if (sosFailureCount > 0) sosFailureCount--;
      if (sosFailureCount == 0) sosFailure = null;
      throw failure;
    }
    sosRaised = true;
    sosTripId = tripId;
  }

  /// How many more `raiseSos` calls fail. Zero means the next one succeeds,
  /// which is what the retry test needs.
  int sosFailureCount = 0;
}

class FakeTrackingController extends TrackingController {
  FakeTrackingController(this.state)
      : super(trips: FakeTripRepository(), initialTrip: tripInState(state)) {
    driver = const DriverProfile(
      id: 'd1',
      fullName: 'Jane Cooper',
      phone: '0240000000',
      photoUrl: '',
      rating: 4.8,
      tripCount: 148,
      kyc: KycStatus.approved,
      availability: DriverAvailability.onTrip,
    );
  }

  final TripState state;

  /// The one repository instance, read back off the base class rather than
  /// declared as a second field. A second `FakeTripRepository()` here would be
  /// the instance the assertions read while the controller wrote to the one
  /// handed to `super`, so `cancelled` would never move.
  FakeTripRepository get repo => trips as FakeTripRepository;
}

Widget wrapTracking(TrackingController c) => ScreenUtilInit(
      designSize: const Size(390, 844),
      builder: (_, _) => ChangeNotifierProvider<TrackingController>.value(
        value: c,
        child: MaterialApp(theme: MngTheme.light, home: const TrackingScreen()),
      ),
    );

/// Presses the SOS button and settles the frame the press started.
Future<void> tapSos(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('sosButton')));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('matched state shows the ride-confirmed headline', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrapTracking(FakeTrackingController(TripState.matched)));
    expect(find.text('Ride confirmed'), findsOneWidget);
  });

  testWidgets('arriving state shows the ETA badge with minutes', (tester) async {
    useDesignSurface(tester);
    final c = FakeTrackingController(TripState.arriving)..etaMinutes = 4;
    await tester.pumpWidget(wrapTracking(c));
    expect(find.text('Arriving soon'), findsOneWidget);
    expect(find.byKey(const Key('etaBadge')), findsOneWidget);
    expect(find.text('4 min'), findsOneWidget);
  });

  testWidgets('driver name, rating and car are summarised', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrapTracking(FakeTrackingController(TripState.arriving)));
    expect(find.text('Jane Cooper'), findsOneWidget);
    expect(find.text('4.8'), findsOneWidget);
  });

  testWidgets('call, message and cancel actions are all present', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrapTracking(FakeTrackingController(TripState.arriving)));
    expect(find.byKey(const Key('callButton')), findsOneWidget);
    expect(find.byKey(const Key('messageButton')), findsOneWidget);
    expect(find.byKey(const Key('cancelButton')), findsOneWidget);
  });

  testWidgets('cancel delegates to the repository with the trip id', (tester) async {
    useDesignSurface(tester);
    final c = FakeTrackingController(TripState.arriving);
    await tester.pumpWidget(wrapTracking(c));
    await tester.tap(find.byKey(const Key('cancelButton')));
    await tester.pump();
    expect(c.repo.cancelled, isTrue);
    expect(c.repo.cancelledTripId, 't1');
  });

  testWidgets('ongoing state hides the cancel action', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrapTracking(FakeTrackingController(TripState.ongoing)));
    expect(find.byKey(const Key('cancelButton')), findsNothing);
  });

  testWidgets('SOS raises once and shows the confirmation copy', (tester) async {
    useDesignSurface(tester);
    final c = FakeTrackingController(TripState.arriving);
    await tester.pumpWidget(wrapTracking(c));
    await tapSos(tester);
    expect(c.repo.sosRaised, isTrue);
    expect(c.repo.sosTripId, 't1');
    expect(c.sosRaised, isTrue);
    expect(
      find.text('Help is on the way. Our team has your trip.'),
      findsOneWidget,
    );
  });

  testWidgets('a second SOS tap does not raise another event', (tester) async {
    useDesignSurface(tester);
    final c = FakeTrackingController(TripState.arriving);
    await tester.pumpWidget(wrapTracking(c));
    await tapSos(tester);
    await tapSos(tester);
    // The call count, not the flag. `sosRaised` is true after one write and after
    // two, so asserting on it pins nothing.
    expect(c.repo.sosCalls, 1);
  });

  testWidgets('driver car and plate render when a vehicle is attached', (tester) async {
    useDesignSurface(tester);
    final c = FakeTrackingController(TripState.arriving)
      ..driverVehicle = const Vehicle(
        id: 'v1',
        ownerId: 'd1',
        category: VehicleCategory.sedan,
        make: 'Toyota',
        model: 'Corolla',
        plate: 'GR-1234-22',
        seats: 4,
        photoUrl: '',
        rideCategory: RideCategory.standard,
      );
    await tester.pumpWidget(wrapTracking(c));
    expect(find.text('Toyota Corolla'), findsOneWidget);
    expect(find.text('GR-1234-22'), findsOneWidget);
  });

  testWidgets('finding-driver screen shows the search copy and cancel', (tester) async {
    useDesignSurface(tester);
    bool cancelled = false;
    await tester.pumpWidget(ScreenUtilInit(
      designSize: const Size(390, 844),
      builder: (_, _) => MaterialApp(
        theme: MngTheme.light,
        home: FindingDriverScreen(
          trip: tripInState(TripState.requested),
          onCancelSearch: () => cancelled = true,
        ),
      ),
    ));
    expect(find.text('3 drivers found'), findsOneWidget);
    expect(
      find.text('Asking Standard drivers near you'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('cancelSearchButton')));
    await tester.pump();
    expect(cancelled, isTrue);
  });

  testWidgets('cancelling takes the trip to cancelled and releases the driver',
      (tester) async {
    useDesignSurface(tester);
    final c = FakeTrackingController(TripState.arriving);
    await tester.pumpWidget(wrapTracking(c));
    expect(c.trip!.hasDriver, isTrue);
    await tester.tap(find.byKey(const Key('cancelButton')));
    await tester.pump();
    expect(c.trip!.state, TripState.cancelled);
    // The other half of the release. A cancelled trip that still names its
    // driver is a trip a driver-side screen would offer to act on, and the
    // controller is the only place this trip is cleared.
    expect(c.trip!.hasDriver, isFalse);
    expect(c.trip!.driverId, isNull);
    expect(find.text('Trip cancelled'), findsOneWidget);
    expect(find.byKey(const Key('cancelButton')), findsNothing);
  });

  test('copyWith keeps the driver unless clearDriver is set', () {
    // The distinction `cancel()` depends on. `copyWith` reads a null `driverId`
    // as "unchanged", because null is also what clearing would mean, so
    // `copyWith(state: ..., driverId: null)` silently keeps the driver and only
    // `clearDriver: true` drops it.
    final matched = tripInState(TripState.matched);
    expect(matched.copyWith(state: TripState.cancelled).driverId, 'd1');
    expect(matched.copyWith(state: TripState.cancelled).hasDriver, isTrue);
    expect(matched.copyWith(driverId: null).driverId, 'd1');
    expect(matched.copyWith(clearDriver: true).driverId, isNull);
    expect(matched.copyWith(clearDriver: true).hasDriver, isFalse);
  });

  testWidgets('a refused SOS write takes the banner back down and shows why',
      (tester) async {
    useDesignSurface(tester);
    final c = FakeTrackingController(TripState.arriving)
      ..repo.sosFailure = const TripRequestFailure('Not signed in');
    await tester.pumpWidget(wrapTracking(c));
    await tapSos(tester);
    // The brief set `sosRaised = true` and never unset it, so a refused write
    // left the screen reading "Help is on the way" with no row in `sos_events`.
    expect(c.sosRaised, isFalse);
    expect(c.error, 'Not signed in');
    expect(find.text('Help is on the way. Our team has your trip.'), findsNothing);
    expect(find.text('Not signed in'), findsOneWidget);
  });

  testWidgets('a dropped connection on SOS says the server was unreachable',
      (tester) async {
    useDesignSurface(tester);
    final c = FakeTrackingController(TripState.arriving)
      ..repo.sosFailure = const FakeTransportException();
    await tester.pumpWidget(wrapTracking(c));
    await tapSos(tester);
    expect(c.sosRaised, isFalse);
    // Not `ClientException: ...`. The repository's own types carry a message
    // written for a rider; a transport exception does not, and the transport
    // one is the only case where the cause is the network rather than a refusal.
    expect(c.error, 'Could not reach the server');
    expect(find.text('Help is on the way. Our team has your trip.'), findsNothing);
  });

  testWidgets('a second SOS press after a failed write reaches the repository',
      (tester) async {
    useDesignSurface(tester);
    final c = FakeTrackingController(TripState.arriving)
      ..repo.sosFailure = const TripRequestFailure('Not signed in')
      ..repo.sosFailureCount = 1;
    await tester.pumpWidget(wrapTracking(c));
    await tapSos(tester);
    expect(c.sosRaised, isFalse);
    await tapSos(tester);
    expect(c.repo.sosCalls, 2);
    expect(c.repo.sosRaised, isTrue);
    expect(c.sosRaised, isTrue);
    // The failed attempt's message does not outlive the retry.
    expect(c.error, isNull);
    expect(find.text('Help is on the way. Our team has your trip.'), findsOneWidget);
  });

  testWidgets('a failed cancel leaves the trip live and reports the reason',
      (tester) async {
    useDesignSurface(tester);
    final c = FakeTrackingController(TripState.arriving)
      ..repo.cancelFailure = const TripRequestFailure('This trip can no longer be cancelled');
    await tester.pumpWidget(wrapTracking(c));
    await tester.tap(find.byKey(const Key('cancelButton')));
    await tester.pump();
    // `cancelTrip` is a `functions.invoke`, so a 409 arrives as a
    // `FunctionException` that Task 8's repository rethrows as a
    // `TripRequestFailure`; the controller catches it here rather than letting
    // it reach the framework as an unhandled async error.
    expect(c.trip!.state, TripState.arriving);
    expect(c.trip!.hasDriver, isTrue);
    expect(c.error, 'This trip can no longer be cancelled');
    expect(find.byKey(const Key('cancelButton')), findsOneWidget);
  });

  testWidgets('a failed refresh keeps the trip on screen and reports the reason',
      (tester) async {
    useDesignSurface(tester);
    final c = FakeTrackingController(TripState.arriving);
    await tester.pumpWidget(wrapTracking(c));
    c.repo.refreshFailure = const FakeTransportException();
    await c.refresh();
    await tester.pump();
    expect(c.trip!.state, TripState.arriving);
    expect(c.error, 'Could not reach the server');
    expect(find.text('Arriving soon'), findsOneWidget);
  });

  testWidgets('a successful refresh takes the trip forward and clears the error',
      (tester) async {
    useDesignSurface(tester);
    final c = FakeTrackingController(TripState.matched)
      ..error = 'Could not reach the server'
      ..repo.active = tripInState(TripState.ongoing);
    await tester.pumpWidget(wrapTracking(c));
    await c.refresh();
    await tester.pump();
    expect(c.trip!.state, TripState.ongoing);
    expect(c.error, isNull);
    expect(find.text('On the way'), findsOneWidget);
  });

  testWidgets('the tracking screen has no overflow at 200% text scale',
      (tester) async {
    useDesignSurface(tester);
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final c = FakeTrackingController(TripState.arriving)
      ..etaMinutes = 4
      ..driverVehicle = const Vehicle(
        id: 'v1',
        ownerId: 'd1',
        category: VehicleCategory.sedan,
        make: 'Toyota',
        model: 'Corolla',
        plate: 'GR-1234-22',
        seats: 4,
        photoUrl: '',
        rideCategory: RideCategory.standard,
      );
    await tester.pumpWidget(wrapTracking(c));
    expect(tester.takeException(), isNull);
  });
}
