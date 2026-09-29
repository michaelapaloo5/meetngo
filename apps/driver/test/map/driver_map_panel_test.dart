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

    testWidgets('a driver with a position and a heading gets a map',
        (tester) async {
      await pumpPanel(
        tester,
        driverPoint: const GeoPoint(5.6037, -0.1870),
        driverHeading: 90,
      );
      expect(find.byKey(const Key('driverMapStandIn')), findsOneWidget);
      expect(find.byKey(const Key('mapNoLocation')), findsNothing);
    });

    testWidgets('a driver with a position but no compass still gets a map',
        (tester) async {
      // The panel shows the driver's position either way. The heading only
      // decides whether the car is drawn as a car; withholding the whole map
      // from a driver whose phone has no magnetometer would be a far worse
      // outcome than a map with no car on it.
      await pumpPanel(tester, driverPoint: const GeoPoint(5.6037, -0.1870));
      expect(find.byKey(const Key('driverMapStandIn')), findsOneWidget);
    });

    testWidgets('a driver with no position is told so, not shown a blank',
        (tester) async {
      // A driver who is offline, refused, or still waiting for a satellite has
      // to read which of those it is. A blank grey rectangle says nothing and
      // looks like a broken build.
      await pumpPanel(tester);
      expect(find.byKey(const Key('mapNoLocation')), findsOneWidget);
      expect(find.text('No location to show yet'), findsOneWidget);
    });

    testWidgets('a pickup with no driver is still a map, not a message',
        (tester) async {
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

    testWidgets('the panel has no overflow at 200% text scale',
        (tester) async {
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
}
