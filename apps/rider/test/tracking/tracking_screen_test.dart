import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/data/booked_trip.dart';
import 'package:meetngo_rider/src/data/location_service.dart';
import 'package:meetngo_rider/src/data/trip_repository.dart';
import 'package:meetngo_rider/src/map/ride_map.dart';
import 'package:meetngo_rider/src/tracking/finding_driver_screen.dart';
import 'package:meetngo_rider/src/tracking/tracking_controller.dart';
import 'package:meetngo_rider/src/tracking/tracking_screen.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

void useDesignSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  // The tracking screen draws a real 3D map, and the engine behind it is a
  // native view: under `flutter test` there is no platform view to create, so
  // the widget cannot be built at all. `RideMap.disabledForTest` swaps in an
  // inert stand-in that keeps the framing and the layout around it real, which
  // is what the tests in this file are about.
  //
  // This is a weaker seam than the one it replaces and the difference is worth
  // stating: the old `flutter_map` version could be rendered in a test with only
  // its tile source swapped, so the map's own drawing was covered. Nothing
  // under `flutter test` can assert on what MapLibre draws. The map is now
  // verified by compiling and by looking at it on a phone, not by this suite.
  RideMap.disabledForTest = true;
  addTearDown(tester.view.reset);
  addTearDown(() => RideMap.disabledForTest = false);
}

/// `etaMinutes` is a parameter and not a fixed 4 because a fixture that pins
/// every ETA to the same number cannot tell a mirrored `eta_minutes` from a
/// hardcoded one. `TripStop` has no `operator ==`, so nothing here asserts on a
/// `TripStop` — only on `.address` and `.point`.
Trip tripInState(
  TripState state, {
  int? etaMinutes,
  RideCategory? category,
  String? pickupOtp,
}) => Trip(
  id: 't1',
  riderId: 'r1',
  driverId: 'd1',
  category: category ?? RideCategory.standard,
  state: state,
  pickup: const TripStop('P', GeoPoint(5.6037, -0.1870), 'Osu, Accra'),
  dropoff: const TripStop(
    'D',
    GeoPoint(5.6052, -0.1660),
    'Airport Residential',
  ),
  distanceKm: 2.4,
  fareGhs: 12.50,
  isDemo: true,
  etaMinutes: etaMinutes,
  pickupOtp: pickupOtp,
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
  @override
  Future<List<BookedTrip>> history({int limit = 50}) async => const [];

  @override
  Future<DeviceLocation> locate() async =>
      const DeviceLocation(LocationOutcome.denied);
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

  /// Where the assigned driver is, for the tests that draw the car.
  VehicleFix? driverPoint;

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
  }) async => tripInState(TripState.requested);

  @override
  Future<GeoPoint?> currentLocation() async => null;

  @override
  Future<VehicleFix?> assignedDriverLocation(String? driverId) async =>
      driverPoint;
  @override
  Future<void> cancelTrip(String tripId) async {
    // Counted before the failure check, exactly as `sosCalls` is: the count is
    // "how many times was the function called", and the controller's own guard
    // is asserted by this never becoming 1. Counting only successful calls
    // would let a refused call read as zero and make that assertion vacuous.
    cancelCalls++;
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
  /// `initialTrip` is a parameter because the controller seeds `etaMinutes` from
  /// it, and a test that cannot hand the constructor a trip carrying a
  /// particular `eta_minutes` cannot pin the seeding at all.
  FakeTrackingController(this.state, [Trip? initialTrip])
    : super(
        trips: FakeTripRepository(),
        initialTrip: initialTrip ?? tripInState(state),
      ) {
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
///
/// `ensureVisible` first, because the tracking screen is a scroll view and the
/// arrival panel pushes the buttons below the fold: at 390x844 the SOS button
/// sits at y=881 with a 844-high viewport, so a bare `tap` misses it and warns.
/// Scrolling to it is what a rider does anyway, and the screen was already
/// scrollable for exactly this reason (the 200% text-scale test).
Future<void> tapSos(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('sosButton')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('sosButton')));
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('matched state shows the ride-confirmed headline', (
    tester,
  ) async {
    useDesignSurface(tester);
    await tester.pumpWidget(
      wrapTracking(FakeTrackingController(TripState.matched)),
    );
    expect(find.text('Ride confirmed'), findsOneWidget);
  });

  testWidgets(
    'arriving state shows the ride-confirmed headline with the ETA badge',
    (tester) async {
      useDesignSurface(tester);
      // 7, not the 4 the previous implementation hardcoded and not the 4 this test
      // used to set by hand, so both the constructor seeding and the refresh mirror
      // are distinguishable from a literal. Driving the badge through the
      // constructor is also the only way to reach the seeding at all: nothing in
      // `apps/rider/lib/` constructs this controller yet, so there is no
      // production path that would set the field for it.
      final c = FakeTrackingController(
        TripState.arriving,
        tripInState(TripState.arriving, etaMinutes: 7),
      );
      expect(c.etaMinutes, 7);
      await tester.pumpWidget(wrapTracking(c));
      expect(find.text('Arriving soon'), findsOneWidget);
      expect(find.byKey(const Key('etaBadge')), findsOneWidget);
      expect(find.text('7 min'), findsOneWidget);
    },
  );

  testWidgets('driver name, rating and car are summarised', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(
      wrapTracking(FakeTrackingController(TripState.arriving)),
    );
    expect(find.text('Jane Cooper'), findsOneWidget);
    expect(find.text('4.8'), findsOneWidget);
  });

  testWidgets('call, message and cancel actions are all present', (
    tester,
  ) async {
    useDesignSurface(tester);
    await tester.pumpWidget(
      wrapTracking(FakeTrackingController(TripState.arriving)),
    );
    expect(find.byKey(const Key('callButton')), findsOneWidget);
    expect(find.byKey(const Key('messageButton')), findsOneWidget);
    expect(find.byKey(const Key('cancelButton')), findsOneWidget);
  });

  testWidgets('cancel delegates to the repository with the trip id', (
    tester,
  ) async {
    useDesignSurface(tester);
    final c = FakeTrackingController(TripState.arriving);
    await tester.pumpWidget(wrapTracking(c));
    await tester.tap(find.byKey(const Key('cancelButton')));
    await tester.pump();
    expect(c.repo.cancelled, isTrue);
    expect(c.repo.cancelledTripId, 't1');
    // The positive half of the pair. `cancel refuses a trip it may not cancel`
    // below asserts this counter is still 0, which only means something because
    // a call that did reach the repository moves it to 1.
    expect(c.repo.cancelCalls, 1);
  });

  testWidgets('ongoing state hides the cancel action', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(
      wrapTracking(FakeTrackingController(TripState.ongoing)),
    );
    expect(find.byKey(const Key('cancelButton')), findsNothing);
  });

  testWidgets('SOS raises once and shows the confirmation copy', (
    tester,
  ) async {
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

  testWidgets('driver car and plate render when a vehicle is attached', (
    tester,
  ) async {
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

  testWidgets('finding-driver screen shows the search copy and cancel', (
    tester,
  ) async {
    useDesignSurface(tester);
    bool cancelled = false;
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(390, 844),
        builder: (_, _) => MaterialApp(
          theme: MngTheme.light,
          home: FindingDriverScreen(
            trip: tripInState(TripState.requested),
            onCancelSearch: () => cancelled = true,
          ),
        ),
      ),
    );
    expect(find.text('Asking Standard drivers near you'), findsOneWidget);
    // No headcount. "3 drivers found" was invented: the client is never told
    // how many drivers were matched, only that one of them accepted, so a
    // number on this screen was fiction -- and three coloured avatars next to
    // it made it look like three identifiable people were on the way.
    expect(find.textContaining('drivers found'), findsNothing);
    expect(find.byType(CircleAvatar), findsNothing);
    expect(find.byIcon(Icons.person), findsNothing);
    // What it can honestly claim: a search is running.
    expect(find.text('Searching'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.byKey(const Key('cancelSearchButton')));
    await tester.pump();
    expect(cancelled, isTrue);
  });

  group('the finding-driver map can be moved and can be got back from', () {
    // The map is full-bleed here and nothing else on the screen scrolls, so
    // the gestures cost nothing and used to be off -- which made the map look
    // broken: a rider who panned it could not get back and nothing said it was
    // even movable. With the gestures on, a recenter control is not a nicety,
    // it is the only way back.
    late bool cancelled;

    Future<void> pumpFinding(
      WidgetTester tester, {
      DeviceLocation? location,
    }) async {
      useDesignSurface(tester);
      cancelled = false;
      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(390, 844),
          builder: (_, _) => MaterialApp(
            theme: MngTheme.light,
            home: FindingDriverScreen(
              trip: tripInState(TripState.requested),
              onCancelSearch: () => cancelled = true,
              location: location,
            ),
          ),
        ),
      );
      // Several frames: the recenter button asks for one more while the map
      // underneath it has not registered, and a test that only pumped once
      // would be testing the binding rather than the behaviour.
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
    }

    testWidgets('a rider with a fix gets a recenter button', (tester) async {
      await pumpFinding(
        tester,
        location: const DeviceLocation(
          LocationOutcome.granted,
          GeoPoint(5.6037, -0.1870),
        ),
      );
      expect(find.byKey(const Key('liveLocationButton')), findsOneWidget);
    });

    testWidgets('a rider without one is told why, and gets no button', (
      tester,
    ) async {
      // No fix, no button. A greyed-out one would invite a tap that does
      // nothing; the map's own note is the one message that explains it.
      await pumpFinding(
        tester,
        location: const DeviceLocation(LocationOutcome.denied),
      );
      expect(find.byKey(const Key('liveLocationButton')), findsNothing);
      expect(find.byKey(const Key('locationNote')), findsOneWidget);
    });

    testWidgets('pressing it does not break the search', (tester) async {
      // The obvious regression: a recenter control that swallows the tap, or
      // that cancels the search. The search copy must survive a press.
      await pumpFinding(
        tester,
        location: const DeviceLocation(
          LocationOutcome.granted,
          GeoPoint(5.6037, -0.1870),
        ),
      );
      await tester.tap(find.byKey(const Key('liveLocationButton')));
      await tester.pump();

      expect(find.text('Searching'), findsOneWidget);
      expect(cancelled, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the cancel button still works with the map interactive', (
      tester,
    ) async {
      // The other direction: the map's gestures must not have eaten the one
      // control on the screen.
      await pumpFinding(
        tester,
        location: const DeviceLocation(
          LocationOutcome.granted,
          GeoPoint(5.6037, -0.1870),
        ),
      );
      await tester.tap(find.byKey(const Key('cancelSearchButton')));
      await tester.pump();
      expect(cancelled, isTrue);
    });
  });

  testWidgets(
    'cancelling takes the trip to cancelled and releases the driver',
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
    },
  );

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

  testWidgets('a refused SOS write takes the banner back down and shows why', (
    tester,
  ) async {
    useDesignSurface(tester);
    final c = FakeTrackingController(TripState.arriving)
      ..repo.sosFailure = const TripRequestFailure('Not signed in');
    await tester.pumpWidget(wrapTracking(c));
    await tapSos(tester);
    // The brief set `sosRaised = true` and never unset it, so a refused write
    // left the screen reading "Help is on the way" with no row in `sos_events`.
    expect(c.sosRaised, isFalse);
    expect(c.error, 'Not signed in');
    expect(
      find.text('Help is on the way. Our team has your trip.'),
      findsNothing,
    );
    expect(find.text('Not signed in'), findsOneWidget);
  });

  testWidgets('a dropped connection on SOS says the server was unreachable', (
    tester,
  ) async {
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
    expect(
      find.text('Help is on the way. Our team has your trip.'),
      findsNothing,
    );
  });

  testWidgets(
    'a second SOS press after a failed write reaches the repository',
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
      expect(
        find.text('Help is on the way. Our team has your trip.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('a failed cancel leaves the trip live and reports the reason', (
    tester,
  ) async {
    useDesignSurface(tester);
    final c = FakeTrackingController(TripState.arriving)
      ..repo.cancelFailure = const TripRequestFailure(
        'This trip can no longer be cancelled',
      );
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

  testWidgets(
    'a failed refresh keeps the trip on screen and reports the reason',
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
    },
  );

  testWidgets(
    'a successful refresh takes the trip forward and clears the error',
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
    },
  );

  testWidgets('the tracking screen has no overflow at 200% text scale', (
    tester,
  ) async {
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

  // --- the ETA is the row's number, never a constant ------------------------

  testWidgets('refresh takes the ETA from the row it just read', (
    tester,
  ) async {
    useDesignSurface(tester);
    final c = FakeTrackingController(
      TripState.arriving,
      tripInState(TripState.arriving, etaMinutes: 9),
    )..repo.active = tripInState(TripState.arriving, etaMinutes: 1);
    await tester.pumpWidget(wrapTracking(c));
    await c.refresh();
    await tester.pump();
    // The old code only assigned for `arriving` when `etaMinutes` was still null,
    // so a seeded 9 survived every refresh and the pill never moved.
    expect(c.etaMinutes, 1);
    expect(find.text('1 min'), findsOneWidget);
  });

  testWidgets('a row that stops carrying an ETA takes the badge away', (
    tester,
  ) async {
    useDesignSurface(tester);
    final c = FakeTrackingController(
      TripState.arriving,
      tripInState(TripState.arriving, etaMinutes: 9),
    )..repo.active = tripInState(TripState.arriving);
    await tester.pumpWidget(wrapTracking(c));
    expect(find.byKey(const Key('etaBadge')), findsOneWidget);
    await c.refresh();
    await tester.pump();
    expect(c.etaMinutes, isNull);
    expect(find.byKey(const Key('etaBadge')), findsNothing);
  });

  // --- the controller's own copy of the cancel guard ------------------------

  testWidgets(
    'cancel refuses a trip it may not cancel without calling the function',
    (tester) async {
      useDesignSurface(tester);
      // Called directly rather than through the button, because `TrackingScreen`
      // hides the button for this state, so the screen test can never reach the
      // controller's own `canTransition` check. It is a second copy of the same
      // rule, and a second copy is only defence in depth while both are pinned.
      final c = FakeTrackingController(TripState.ongoing);
      await c.cancel();
      expect(c.error, 'This trip can no longer be cancelled');
      expect(c.repo.cancelCalls, 0);
      expect(c.repo.cancelled, isFalse);
      expect(c.trip!.state, TripState.ongoing);
      expect(c.trip!.hasDriver, isTrue);
    },
  );

  // --- headlines and the route line ----------------------------------------

  testWidgets('requested state shows the finding-a-driver headline', (
    tester,
  ) async {
    useDesignSurface(tester);
    await tester.pumpWidget(
      wrapTracking(FakeTrackingController(TripState.requested)),
    );
    expect(find.text('Finding your driver'), findsOneWidget);
  });

  testWidgets('completed state shows the trip-complete headline', (
    tester,
  ) async {
    useDesignSurface(tester);
    await tester.pumpWidget(
      wrapTracking(FakeTrackingController(TripState.completed)),
    );
    expect(find.text('Trip complete'), findsOneWidget);
  });

  testWidgets('the route line reads both addresses', (tester) async {
    useDesignSurface(tester);
    // Built from the fixture's own `.address` values rather than a literal, so
    // this tracks the fixture and not a copy of it, and never asserts on a
    // `TripStop` -- the model has no `operator ==` and compares by identity.
    final trip = tripInState(TripState.arriving);
    await tester.pumpWidget(
      wrapTracking(FakeTrackingController(TripState.arriving, trip)),
    );
    expect(
      find.text('${trip.pickup.address} to ${trip.dropoff.address}'),
      findsOneWidget,
    );
  });

  // --- the null active trip still repaints ---------------------------------

  testWidgets(
    'a refresh with no active trip clears a stale error and repaints',
    (tester) async {
      useDesignSurface(tester);
      final c = FakeTrackingController(TripState.arriving)
        ..error = 'Could not reach the server';
      await tester.pumpWidget(wrapTracking(c));
      expect(find.text('Could not reach the server'), findsOneWidget);
      // `activeTrip()` answers null, which is the path that used to `return`
      // before `notifyListeners`.
      await c.refresh();
      await tester.pump();
      expect(c.error, isNull);
      expect(c.trip!.state, TripState.arriving);
      expect(find.text('Could not reach the server'), findsNothing);
      expect(find.text('Arriving soon'), findsOneWidget);
    },
  );

  // --- the category label in the search copy -------------------------------

  testWidgets('the finding-driver copy names the category the trip was booked as', (
    tester,
  ) async {
    useDesignSurface(tester);
    // `RideCategory.lite`'s label is `Lite`, capitalised
    // (`mng_core/lib/src/models/category.dart`) — read off the enum, not
    // assumed. A standard-trip-only assertion cannot tell this line from a
    // hardcoded string, because the hardcoded string was Standard's. That is
    // exactly what went stale when the tier was renamed from `van`: the comment
    // above still said the label was `Van` while the assertion beside it had
    // been updated, and nothing caught it because the loop passed either way.
    for (final category in RideCategory.values) {
      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(390, 844),
          builder: (_, _) => MaterialApp(
            theme: MngTheme.light,
            home: FindingDriverScreen(
              trip: tripInState(TripState.requested, category: category),
              onCancelSearch: () {},
            ),
          ),
        ),
      );
      // One pump per iteration. `ScreenUtilInit` has to initialise before the
      // `.h`/`.w` extensions return real numbers, and the loop previously got
      // away with no pump only because the first category it happened to try
      // was Standard. Renaming `van` to `lite` moved `lite` to the front of
      // the enum, so the first iteration is now a different one and the
      // missing pump surfaced as "found 0 widgets" on a category that is
      // demonstrably in the string on the line under the test's own comment.
      await tester.pump();
      expect(
        find.text('Asking ${category.label} drivers near you'),
        findsOneWidget,
        reason: category.name,
      );
    }

    // These two lines sat *after* the loop and asserted the screen still showed
    // `lite`, on the reasoning that the last iteration left it there. The last
    // iteration is `premium`, so this asserted a screen showing Premium drivers
    // contained the text "Asking Lite drivers near you" -- and it passed only
    // while `lite` happened to be the last category in the enum. Renaming `van`
    // to `lite` made `lite` the *first* instead, and the leftover assertion
    // failed while the loop above it, the part that actually tests the
    // behaviour, passed for all three.
    //
    // Asserted inside the loop instead: exactly one of the three strings is on
    // screen, and it is the one for the category just pumped. That cannot
    // depend on enum order and cannot be satisfied by a stale tree.
    expect(
      find.textContaining('drivers near you'),
      findsOneWidget,
      reason: 'exactly one category name is on screen after the loop',
    );
    expect(
      find.text('Asking ${RideCategory.values.last.label} drivers near you'),
      findsOneWidget,
      reason: 'the screen shows the last category pumped, not a leftover',
    );
  });

  testWidgets('while arriving the rider sees the pickup code from the trip', (
    tester,
  ) async {
    useDesignSurface(tester);
    await tester.pumpWidget(
      wrapTracking(
        FakeTrackingController(
          TripState.arriving,
          tripInState(TripState.arriving, pickupOtp: '4821'),
        ),
      ),
    );
    expect(find.byKey(const Key('pickupCodePanel')), findsOneWidget);
    expect(
      find.text('4821'),
      findsOneWidget,
      reason: 'the code on screen must be the code on the trip, not a literal',
    );
  });

  testWidgets('the pickup code is not shown before the driver arrives', (
    tester,
  ) async {
    useDesignSurface(tester);
    for (final state in [
      TripState.matched,
      TripState.ongoing,
      TripState.completed,
    ]) {
      await tester.pumpWidget(
        wrapTracking(
          FakeTrackingController(state, tripInState(state, pickupOtp: '4821')),
        ),
      );
      expect(
        find.byKey(const Key('pickupCodePanel')),
        findsNothing,
        reason: state.name,
      );
    }
  });

  testWidgets('a missing code is shown rather than hidden', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(
      wrapTracking(
        FakeTrackingController(
          TripState.arriving,
          tripInState(TripState.arriving),
        ),
      ),
    );
    // Null is a real state: a trip row written before `request-ride` started
    // minting codes has none, and a panel that silently does not appear is
    // indistinguishable from a bug.
    expect(find.byKey(const Key('pickupCodePanel')), findsOneWidget);
    expect(find.text('Not available'), findsOneWidget);
  });
}
