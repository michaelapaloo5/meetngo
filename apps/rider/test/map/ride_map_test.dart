// The GeoJSON the rider's map hands to MapLibre, asserted without a map.
//
// `RideMap.disabledForTest` exists because MapLibre draws through a native
// platform view and there is no such view under `flutter test`, so the map's
// own drawing is not covered by the suite — that loss is stated in the widget's
// own docs and in `HANDOFF.md`. What *is* testable without the engine is the
// data that goes into it, and the data is where this feature actually breaks:
// a bearing written as a string, or a coordinate pair in the wrong order, both
// produce a car that is silently wrong rather than a car that is missing.
//
// So the GeoJSON builder is reached directly and checked here. The style's own
// contract with this data is asserted in
// `packages/mng_core/test/premium_map_style_test.dart`, which reads the real
// bundled style; these tests check this side of the handshake.
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/data/location_service.dart';
import 'package:meetngo_rider/src/map/ride_map.dart';
import 'package:mng_core/mng_core.dart';

void main() {
  // A `VehicleFix` at Accra heading east: the case that exposes any bug here.
  // A car pointing north on a map where the driver is travelling east is not
  // obviously broken, it is just wrong.
  const fix = VehicleFix(GeoPoint(5.6037, -0.1870), 90);

  Map<String, dynamic>? feature(VehicleFix f) {
    final collection = vehicleGeoJson(f);
    if (collection == null) return null;
    return (collection['features'] as List).first as Map<String, dynamic>;
  }

  group('the vehicle GeoJSON the style rotates the car by', () {
    test('a feature carries the point as GeoJSON [lng, lat]', () {
      final coords = (feature(fix)!['geometry'] as Map)['coordinates'] as List;
      // Order, not just presence. GeoJSON is longitude-first and this app uses
      // latitude first everywhere else, so a swap puts the car in the sea off
      // Ghana and still looks like a position.
      expect(coords, [-0.1870, 5.6037]);
    });

    test('a feature carries the bearing as a number, not a string', () {
      // MapLibre's `icon-rotate` is handed this value and adds it to the icon
      // angle. A string goes to the CSS parser, fails to parse, and leaves the
      // car pointing north with no error anywhere — exactly the failure this
      // feature exists to remove.
      final properties = feature(fix)!['properties'] as Map;
      expect(properties[kVehicleBearingProperty], isA<num>());
      expect(properties[kVehicleBearingProperty], 90.0);
    });

    test('the bearing property is named what the style reads', () {
      // The two names live in two different files and nothing else connects
      // them. If either is renamed alone the car stops rotating and the style
      // still looks right.
      expect(
        (feature(fix)!['properties'] as Map).containsKey(kVehicleBearingProperty),
        isTrue,
      );
    });

    test('a fix with no bearing still produces a car, pointing north', () {
      // Not an absent property: that would make `icon-rotate` null, and a null
      // rotation draws nothing at all. A driver with no compass would make the
      // car vanish from the rider's map, which is worse than a car pointing an
      // arbitrary way.
      final properties =
          feature(const VehicleFix(GeoPoint(5.6037, -0.1870)))!['properties']
              as Map;
      expect(properties[kVehicleBearingProperty], 0.0);
    });

    test('a heading of 360 is sent as 0, not 360', () {
      // A compass reports 360 as readily as 0, and rotating by 360 is a car
      // spun all the way round for no reason.
      final properties = feature(
        const VehicleFix(GeoPoint(5.6037, -0.1870), 360),
      )!['properties'] as Map;
      expect(properties[kVehicleBearingProperty], 0.0);
    });

    test('a fix in the Gulf of Guinea produces nothing at all', () {
      // `(0, 0)` is what a `request-ride` row with an unparsed pickup looks
      // like, and a car drawn there is a car in the ocean with nothing to say
      // the data is wrong. Null means "leave the last one alone" rather than
      // "empty the source", so the car does not blink out either.
      expect(vehicleGeoJson(const VehicleFix(GeoPoint(0, 0), 90)), isNull);
    });

    test('no driver at all produces nothing', () {
      expect(vehicleGeoJson(null), isNull);
    });
  });

  group('isPlottable', () {
    test('Accra is a place', () {
      expect(RideMap.isPlottable(const GeoPoint(5.6037, -0.1870)), isTrue);
    });

    test('the origin is not', () {
      expect(RideMap.isPlottable(const GeoPoint(0, 0)), isFalse);
    });

    test('an out-of-range latitude is not', () {
      expect(RideMap.isPlottable(const GeoPoint(95, -0.1870)), isFalse);
      expect(RideMap.isPlottable(const GeoPoint(-95, -0.1870)), isFalse);
    });

    test('an out-of-range longitude is not', () {
      expect(RideMap.isPlottable(const GeoPoint(5.6037, 200)), isFalse);
      expect(RideMap.isPlottable(const GeoPoint(5.6037, -200)), isFalse);
    });

    test('the extremes themselves are still places', () {
      // Boundaries, not exceptions. A fix at the pole is real, and a strict
      // `>=` would blank the map at exactly the places it is most obviously
      // right about.
      expect(RideMap.isPlottable(const GeoPoint(90, 180)), isTrue);
      expect(RideMap.isPlottable(const GeoPoint(-90, -180)), isTrue);
    });
  });

  group('what the map says about itself', () {
    setUpAll(() => RideMap.disabledForTest = true);
    tearDownAll(() => RideMap.disabledForTest = false);

    Future<void> pumpMap(WidgetTester tester, {DeviceLocation? location}) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(390, 844),
          builder: (_, _) => MaterialApp(
            theme: MngTheme.light,
            home: Scaffold(
              body: RideMap(
                pickup: const GeoPoint(5.6037, -0.1870),
                location: location,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('a rider who refused is told so on the map itself',
        (tester) async {
      // The map is full-bleed on the tracking screen, so a message about the
      // position has to be drawn on the map to be seen at all.
      await pumpMap(
        tester,
        location: const DeviceLocation(LocationOutcome.denied),
      );
      expect(find.byKey(const Key('locationNote')), findsOneWidget);
      expect(
        find.textContaining('not allowed to use your location'),
        findsOneWidget,
      );
    });

    testWidgets('a rider with a fix is not shown a note about not having one',
        (tester) async {
      await pumpMap(
        tester,
        location: const DeviceLocation(
          LocationOutcome.granted,
          GeoPoint(5.6037, -0.1870),
        ),
      );
      expect(find.byKey(const Key('locationNote')), findsNothing);
    });

    testWidgets('the OSM credit is on the map at all times', (tester) async {
      // The tile usage policy requires it visible rather than behind a tap, and
      // `logoEnabled: false` means MapLibre's own badge is not standing in.
      await pumpMap(tester);
      expect(find.byKey(const Key('osmAttribution')), findsOneWidget);
      expect(find.textContaining('OpenStreetMap'), findsOneWidget);
    });

    testWidgets('a trip with no usable pickup says so instead of guessing',
        (tester) async {
      // A pickup at the origin is unparsed data. Drawing a map centred on it
      // would be a map of the Atlantic with a confident pin in it.
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(390, 844),
          builder: (_, _) => MaterialApp(
            theme: MngTheme.light,
            home: const Scaffold(
              body: RideMap(pickup: GeoPoint(0, 0)),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('mapFallback')), findsOneWidget);
      expect(find.textContaining('not known yet'), findsOneWidget);
    });
  });
}
