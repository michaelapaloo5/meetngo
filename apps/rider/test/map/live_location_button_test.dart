import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/map/live_location_button.dart';
import 'package:meetngo_rider/src/map/ride_map.dart';
import 'package:mng_core/mng_core.dart';

/// The live-location button.
///
/// The thing worth testing is not that a button draws. It is that the button is
/// *absent* when there is no fix, that it becomes pressable once the map
/// underneath has registered, and that pressing it asks the map for the right
/// point — because the failure mode of a recenter control is silent. A button
/// that draws when there is nothing to centre on invites a tap that does
/// nothing, and the rider cannot tell that from a map that lost them.
void main() {
  // The stand-in is required: MapLibre needs a native platform view and
  // `flutter test` has none, so the map cannot be built at all without it.
  setUpAll(() => RideMap.disabledForTest = true);
  tearDownAll(() => RideMap.disabledForTest = false);

  TestWidgetsFlutterBinding.ensureInitialized();

  /// A real `RideMap` under a `GlobalKey`, with the button on top of it, so the
  /// button resolves the key exactly as it does on a screen.
  Future<GlobalKey<RideMapState>> pumpButton(
    WidgetTester tester, {
    GeoPoint? point = const GeoPoint(5.6037, -0.1870),
    bool withMap = true,
  }) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final mapKey = GlobalKey<RideMapState>();
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(390, 844),
        builder: (_, _) => MaterialApp(
          theme: MngTheme.light,
          home: Scaffold(
            body: Stack(
              children: [
                if (withMap)
                  Positioned.fill(
                    child: KeyedSubtree(
                      key: const Key('testMap'),
                      child: RideMap(
                        key: mapKey,
                        pickup: const GeoPoint(5.6037, -0.1870),
                        fill: true,
                      ),
                    ),
                  ),
                Positioned.fill(
                  child: LiveLocationButton(mapKey: withMap ? mapKey : null,
                      point: point),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // A few frames, because the button asks for one more each time the map has
    // not registered yet. If it never settles, that is the bug under test.
    for (var i = 0; i < 8; i++) {
      await tester.pump();
    }
    return mapKey;
  }

  group('whether it is drawn at all', () {
    testWidgets('with a fix, it is there', (tester) async {
      await pumpButton(tester);
      expect(find.byKey(const Key('liveLocationButton')), findsOneWidget);
    });

    testWidgets('with no fix, nothing is drawn', (tester) async {
      // Not a disabled button. A greyed-out control tells a rider it exists
      // and cannot be used, which invites a second tap and then a support
      // question. The map's own note already explains the absence.
      await pumpButton(tester, point: null);
      expect(find.byKey(const Key('liveLocationButton')), findsNothing);
      expect(find.byIcon(Icons.my_location), findsNothing);
    });
  });

  group('binding to the map underneath it', () {
    testWidgets('it becomes pressable once the map has registered',
        (tester) async {
      // The whole reason the button takes a `GlobalKey` rather than a state.
      // A parent builds before its children, so `currentState` is null on the
      // first frame; a button that took the state directly would be handed
      // null and, with nothing else changing, would never rebuild and would
      // stay dead for the rest of the ride.
      await pumpButton(tester);
      expect(tester.takeException(), isNull);

      final ink = tester.widget<InkWell>(
        find.byKey(const Key('liveLocationButton')),
      );
      expect(ink.onTap, isNotNull,
          reason: 'the button never bound to the map below it');
    });

    testWidgets('with no map at all it is drawn but not pressable',
        (tester) async {
      // Still drawn, so a rider who has just arrived sees the control rather
      // than watching it appear. It must not look pressable, because pressing
      // it could do nothing.
      await pumpButton(tester, withMap: false);

      expect(find.byKey(const Key('liveLocationButton')), findsOneWidget);
      final ink = tester.widget<InkWell>(
        find.byKey(const Key('liveLocationButton')),
      );
      expect(ink.onTap, isNull);
    });

    testWidgets('it does not rebuild itself forever waiting for the map',
        (tester) async {
      // The retry is bounded. An unbounded one is an infinite frame loop, and
      // the bound is also what stops a rider's battery being spent on a screen
      // with no map under the button.
      await pumpButton(tester, withMap: false);
      final before = tester.binding.transientCallbackCount;
      for (var i = 0; i < 20; i++) {
        await tester.pump();
      }
      final after = tester.binding.transientCallbackCount;
      expect(after - before, lessThan(20),
          reason: 'the button is still asking for frames long after it gave up');
    });
  });

  group('pressing it', () {
    testWidgets('it asks the map to centre on the rider', (tester) async {
      // The camera move itself is not observable without MapLibre, but what was
      // asked for is, and that is where the bug would be: a button that
      // recentres on the pickup, or on (0,0), looks identical until you read
      // the point.
      const here = GeoPoint(5.6037, -0.1870);
      final mapKey = await pumpButton(tester, point: here);

      await tester.tap(find.byKey(const Key('liveLocationButton')));
      await tester.pump();

      expect(mapKey.currentState!.lastRecentredOn, here);
    });

    testWidgets('it says something when the map cannot move yet',
        (tester) async {
      // A press that silently does nothing is the worst version of this
      // feature, because the rider is trying to find themselves.
      await pumpButton(tester, withMap: false);

      // Not pressable, so the tap is refused outright and nothing is claimed.
      // The label is what tells the rider why.
      await tester.tap(
        find.byKey(const Key('liveLocationButton')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(
        find.bySemanticsLabel(
          'Centre the map on your location. The map is still loading.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('it is announced to a screen reader as a button',
        (tester) async {
      await pumpButton(tester);
      expect(
        find.bySemanticsLabel('Centre the map on your location'),
        findsOneWidget,
      );
    });

    testWidgets('the button does not overflow at 200% text scale',
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
              home: const Scaffold(
                body: Stack(
                  children: [
                    LiveLocationButton(
                      mapKey: null,
                      point: GeoPoint(5.6037, -0.1870),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      // A RenderFlex overflow is thrown, not painted, so reaching here is the
      // assertion.
      expect(tester.takeException(), isNull);
    });
  });
}
