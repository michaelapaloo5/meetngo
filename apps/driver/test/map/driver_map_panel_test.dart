// The driver's own car, on the driver's own map.
//
// `DriverMapPanel.disabledForTest` exists for the same reason as the rider's
// `RideMap.disabledForTest`: MapLibre draws through a native platform view and
// there is none under `flutter test`. These tests cover what can be reached
// without the engine, which is the part with a decision in it — whether a car
// is drawn at all.
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_driver/src/map/driver_map_panel.dart';
import 'package:mng_core/mng_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the panel on screen', () {
    setUpAll(() => DriverMapPanel.disabledForTest = true);
    tearDownAll(() => DriverMapPanel.disabledForTest = false);

    Future<void> pumpPanel(
      WidgetTester tester, {
      GeoPoint? driverPoint,
      double? driverHeading,
      GeoPoint? pickup,
      GeoPoint? dropoff,
      bool drawRoute = true,
    }) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(390, 844),
          builder: (_, _) => MaterialApp(
            theme: MngTheme.light,
            home: Scaffold(
              body: DriverMapPanel(
                driverPoint: driverPoint,
                driverHeading: driverHeading,
                pickup: pickup,
                dropoff: dropoff,
                drawRoute: drawRoute,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('a driver with a position and a heading gets a map', (
      tester,
    ) async {
      await pumpPanel(
        tester,
        driverPoint: const GeoPoint(5.6037, -0.1870),
        driverHeading: 90,
      );
      expect(find.byKey(const Key('driverMapStandIn')), findsOneWidget);
      expect(find.byKey(const Key('mapNoLocation')), findsNothing);
    });

    testWidgets('a driver with a position but no compass still gets a map', (
      tester,
    ) async {
      // The panel shows the driver's position either way. The heading only
      // decides whether the car is drawn as a car; withholding the whole map
      // from a driver whose phone has no magnetometer would be a far worse
      // outcome than a map with no car on it.
      await pumpPanel(tester, driverPoint: const GeoPoint(5.6037, -0.1870));
      expect(find.byKey(const Key('driverMapStandIn')), findsOneWidget);
    });

    testWidgets('a driver with no position is told so, not shown a blank', (
      tester,
    ) async {
      // A driver who is offline, refused, or still waiting for a satellite has
      // to read which of those it is. A blank grey rectangle says nothing and
      // looks like a broken build.
      await pumpPanel(tester);
      expect(find.byKey(const Key('mapNoLocation')), findsOneWidget);
      expect(find.text('No location to show yet'), findsOneWidget);
    });

    testWidgets('a pickup with no driver is still a map, not a message', (
      tester,
    ) async {
      // The trip detail screen shows the route of a trip that is not live. A
      // driver reading that route is not waiting for their own position.
      await pumpPanel(
        tester,
        pickup: const GeoPoint(5.6037, -0.1870),
        dropoff: const GeoPoint(5.62, -0.20),
      );
      expect(find.byKey(const Key('driverMapStandIn')), findsOneWidget);
    });

    testWidgets('the credit is on the panel', (tester) async {
      // Required visible by the OSM tile usage policy, and MapLibre's own badge
      // is switched off because it would be a false claim about who drew it.
      await pumpPanel(tester, driverPoint: const GeoPoint(5.6037, -0.1870));
      expect(find.byKey(const Key('osmAttribution')), findsOneWidget);
    });

    testWidgets('the panel has no overflow at 200% text scale', (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
          child: ScreenUtilInit(
            designSize: const Size(390, 844),
            builder: (_, _) => MaterialApp(
              theme: MngTheme.light,
              home: const Scaffold(body: DriverMapPanel()),
            ),
          ),
        ),
      );
      await tester.pump();
      // A RenderFlex overflow is thrown, not painted, so reaching here is the
      // assertion.
      expect(tester.takeException(), isNull);
    });
  });

  // Follow-until-the-driver-looks-elsewhere, then a button to come back.
  //
  // MapLibre draws through a native view, so `onCameraIdle` can never fire under
  // `flutter test` and the panel can only be exercised through its stand-in. The
  // decision itself is therefore static and pure, and that is what these pin.
  group('following the driver', () {
    // Its own `setUpAll`, because the one in the group above is scoped to that
    // group and does not reach here. Without it this group builds a real
    // MapLibreMap, and tearing one down under `flutter test` throws
    // `LateInitializationError: Field '_channel' has not been initialized` from the
    // plugin's platform interface -- which has nothing to do with what is being
    // tested here and reads like a failure of the follow logic.
    setUpAll(() => DriverMapPanel.disabledForTest = true);
    tearDownAll(() => DriverMapPanel.disabledForTest = false);

    const driver = GeoPoint(5.6037, -0.1870);

    test('a camera resting on the driver keeps following', () {
      expect(
        DriverMapPanel.stillFollowing(cameraTarget: driver, driver: driver),
        isTrue,
      );
    });

    test('a camera a little off the driver still follows', () {
      // GPS noise and a pinch while stationary must not switch following off, or
      // the button appears for no reason and the driver learns to ignore it.
      // 50 m north.
      final nearby = GeoPoint(driver.lat + 0.00045, driver.lng);
      expect(
        DriverMapPanel.stillFollowing(cameraTarget: nearby, driver: driver),
        isTrue,
        reason: 'about 50 m is within the slack',
      );
    });

    test('a camera the driver panned away stops following', () {
      // About 1.2 km north, roughly a third of the way off a zoom-14 screen.
      final panned = GeoPoint(driver.lat + 0.0108, driver.lng);
      expect(
        DriverMapPanel.stillFollowing(cameraTarget: panned, driver: driver),
        isFalse,
        reason: 'this is somebody deliberately looking somewhere else',
      );
    });

    testWidgets('the recentre button appears only once following is off', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(390, 844),
          builder: (_, _) => MaterialApp(
            theme: MngTheme.light,
            home: Scaffold(
              body: DriverMapPanel(driverPoint: driver, driverHeading: 90),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const Key('recentreMapButton')),
        findsNothing,
        reason: 'a driver who has not touched the map needs no button',
      );

      // Stand in for the driver panning the map: the camera has come to rest far
      // from them, which is the condition `onCameraIdle` acts on. That callback
      // cannot run here -- MapLibre is a native view and there is none -- so the
      // state it would leave behind is seeded through `startFollowing` instead.
      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(390, 844),
          builder: (_, _) => MaterialApp(
            theme: MngTheme.light,
            home: Scaffold(
              body: DriverMapPanel(
                // A different key, so this is a new State and `initState` runs.
                // Pumping a same-keyed widget of the same type into the same slot
                // reuses the element, and the seed would be ignored.
                key: const Key('notFollowing'),
                driverPoint: driver,
                driverHeading: 90,
                startFollowing: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('recentreMapButton')), findsOneWidget);
    });
  });
}
