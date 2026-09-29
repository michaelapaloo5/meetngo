import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/booking/route_entry_sheet.dart';
import 'package:meetngo_rider/src/data/place_service.dart';
import 'package:mng_core/mng_core.dart';

/// A geocoder that answers from a script, so no test touches the network and
/// no test depends on a volunteer service being up.
class _StubPlaces implements PlaceService {
  _StubPlaces({this.matches = const [], this.fail = false});

  final List<PlaceSuggestion> matches;
  final bool fail;
  final List<String> queries = [];

  // `reverse` is not exercised here: the map picker's own tests cover it, and
  // they need to control what it answers, which this stub deliberately does
  // not.
  @override
  Future<PlaceName?> reverse(GeoPoint point) async => null;

  @override
  Future<List<PlaceSuggestion>> search(String query) async {
    queries.add(query);
    if (fail) return const [];
    return matches;
  }
}

PlaceSuggestion _hit(String label, double lat, double lng) =>
    PlaceSuggestion(label: label, point: GeoPoint(lat, lng));

Widget wrap({
  void Function(RouteDraft draft)? onSubmit,
  PlaceService? places,
}) =>
    ScreenUtilInit(
      designSize: const Size(390, 844),
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (_, _) => MaterialApp(
        theme: MngTheme.light,
        home: Scaffold(
          body: RouteEntrySheet(
            calc: FareCalculator(),
            onSubmit: onSubmit ?? (_) {},
            places: places ?? _StubPlaces(),
          ),
        ),
      ),
    );

Widget openHarness({
  void Function(RouteDraft draft)? onSubmit,
  PlaceService? places,
}) =>
    ScreenUtilInit(
      designSize: const Size(390, 844),
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (_, _) => MaterialApp(
        theme: MngTheme.light,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showRouteEntrySheet(
                  context,
                  calc: FareCalculator(),
                  onSubmit: onSubmit ?? (_) {},
                  places: places ?? _StubPlaces(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

void useDesignSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('shows the pickup and the dropoff, not the distance twice',
      (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    expect(find.text('Osu, Accra'), findsOneWidget);
    expect(find.text('Airport Residential, Accra'), findsOneWidget);
  });

  testWidgets('summarises the measured distance, drive time and fare',
      (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    // Haversine over the two Accra constants, R = 6371.0088: 2.3299 km.
    // (5.00 + 1.80 * 2.3299) * 1.0 + 1.00 = 10.1938 -> GHS 10.19.
    expect(find.text('2.3 km  ·  ~6 min drive'), findsOneWidget);
    expect(find.text('GHS 10.19'), findsOneWidget);
  });

  testWidgets('changing the category requotes the fare', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    await tester.tap(find.byKey(const Key('chip-van')));
    await tester.pump();
    // (5.00 + 2.20 * 2.3299) * 1.0 + 1.00 = 11.1258 -> GHS 11.13.
    expect(find.text('GHS 11.13'), findsOneWidget);
  });

  testWidgets('confirm submits the draft with the chosen stops', (tester) async {
    useDesignSurface(tester);
    RouteDraft? draft;
    await tester.pumpWidget(wrap(onSubmit: (d) => draft = d));
    await tester.tap(find.byKey(const Key('chip-van')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('confirmRouteButton')));
    await tester.pump();
    expect(draft, isNotNull);
    expect(draft!.pickup.address, kDefaultPickup.address);
    expect(draft!.pickup.point, kDefaultPickup.point);
    expect(draft!.dropoff.address, kDefaultDropoff.address);
    expect(draft!.category, RideCategory.van);
  });

  testWidgets('the sheet keeps its button clear of the bottom inset',
      (tester) async {
    useDesignSurface(tester);
    tester.view.padding = const FakeViewPadding(bottom: 102);
    await tester.pumpWidget(openHarness());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final button =
        tester.getBottomRight(find.byKey(const Key('confirmRouteButton')));
    expect(button.dy, lessThanOrEqualTo(844 - 34));
  });

  testWidgets('showRouteEntrySheet opens the sheet and submits its draft',
      (tester) async {
    useDesignSurface(tester);
    RouteDraft? draft;
    await tester.pumpWidget(openHarness(onSubmit: (d) => draft = d));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('confirmRouteButton')), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirmRouteButton')));
    await tester.pumpAndSettle();
    expect(draft, isNotNull);
    expect(draft!.pickup.address, kDefaultPickup.address);
    expect(draft!.dropoff.address, kDefaultDropoff.address);
  });

  testWidgets('the route sheet has no overflow at 200% text scale',
      (tester) async {
    useDesignSurface(tester);
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(wrap());
    expect(tester.takeException(), isNull);
  });

  // --- the dropoff is a field, not a constant -------------------------------
  //
  // It was a `final` field set to kDefaultDropoff with no way to change it, so
  // every ride this build produced went to the same airport regardless of what
  // the rider wanted, and the fare on screen was for a trip nobody had asked
  // for. These cover the fix.

  testWidgets('both stops are editable text fields', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    expect(find.byKey(const Key('pickupField')), findsOneWidget);
    expect(find.byKey(const Key('dropoffField')), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
  });

  testWidgets('typing a destination and picking a result changes the trip', (
    tester,
  ) async {
    useDesignSurface(tester);
    final places = _StubPlaces(matches: [
      _hit('Kumasi, Ghana', 6.6885, -1.6244),
    ]);
    RouteDraft? draft;
    await tester.pumpWidget(wrap(places: places, onSubmit: (d) => draft = d));

    await tester.enterText(find.byKey(const Key('dropoffField')), 'Kumasi');
    // The search is debounced, so results cannot be there on the first frame.
    // Pumping past the delay is what a rider experiences as typing.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    expect(find.byKey(const Key('placeResults')), findsOneWidget);
    expect(find.text('Kumasi, Ghana'), findsOneWidget);

    await tester.tap(find.byKey(const Key('placeHit-Kumasi, Ghana')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirmRouteButton')));
    await tester.pump();

    expect(draft!.dropoff.address, 'Kumasi, Ghana');
    expect(draft!.dropoff.point.lat, closeTo(6.6885, 1e-6));
    // The pickup was not touched, so it must still be the device fallback.
    expect(draft!.pickup.address, kDefaultPickup.address);
  });

  testWidgets('picking a result requotes the fare over the real distance', (
    tester,
  ) async {
    useDesignSurface(tester);
    // Accra to Kumasi is about 200 km, so the fare cannot still be the 10.19
    // of the 2.3 km demo route. A quote that did not move would mean the
    // distance came from the default rather than from the choice.
    final places = _StubPlaces(matches: [
      _hit('Kumasi, Ghana', 6.6885, -1.6244),
    ]);
    await tester.pumpWidget(wrap(places: places));
    await tester.enterText(find.byKey(const Key('dropoffField')), 'Kumasi');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    await tester.tap(find.byKey(const Key('placeHit-Kumasi, Ghana')));
    await tester.pumpAndSettle();

    expect(find.text('GHS 10.19'), findsNothing);
    expect(find.textContaining('km'), findsOneWidget);
  });

  // One request per pause in typing, not one per keystroke: the geocoder is a
  // shared volunteer service whose policy caps it at one request a second.
  testWidgets('typing does not fire a request per keystroke', (tester) async {
    useDesignSurface(tester);
    final places = _StubPlaces();
    await tester.pumpWidget(wrap(places: places));
    await tester.enterText(find.byKey(const Key('dropoffField')), 'Kumasi');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(places.queries, ['Kumasi']);
  });

  testWidgets('a query shorter than the minimum asks nothing', (tester) async {
    useDesignSurface(tester);
    final places = _StubPlaces();
    await tester.pumpWidget(wrap(places: places));
    await tester.enterText(find.byKey(const Key('dropoffField')), 'Ku');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(places.queries, isEmpty);
    expect(find.textContaining('Type at least'), findsOneWidget);
  });

  // A geocoder that is down must not leave the rider at a spinner forever, and
  // must not invent a result.
  testWidgets('a geocoder that fails says so and offers nothing', (
    tester,
  ) async {
    useDesignSurface(tester);
    final places = _StubPlaces(fail: true);
    await tester.pumpWidget(wrap(places: places));
    await tester.enterText(find.byKey(const Key('dropoffField')), 'Kumasi');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(find.textContaining('Nothing matched'), findsOneWidget);
  });

  // Both defaults sit in the same part of Accra, so an untouched sheet produces
  // a plausible fare for a trip nobody asked for. Say so on the sheet.
  testWidgets('an untouched route says it is still the demo route', (
    tester,
  ) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    expect(find.textContaining('demo route'), findsOneWidget);
  });

  testWidgets('choosing a real destination drops the demo-route warning', (
    tester,
  ) async {
    useDesignSurface(tester);
    final places = _StubPlaces(matches: [
      _hit('Kumasi, Ghana', 6.6885, -1.6244),
    ]);
    await tester.pumpWidget(wrap(places: places));
    await tester.enterText(find.byKey(const Key('dropoffField')), 'Kumasi');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    await tester.tap(find.byKey(const Key('placeHit-Kumasi, Ghana')));
    await tester.pumpAndSettle();
    expect(find.textContaining('demo route'), findsNothing);
  });
}
