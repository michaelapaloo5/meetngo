import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/booking/route_confirm_page.dart';
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

/// With a destination already chosen, as the search page always supplies.
TripStop _dest() => const TripStop(
  'Dropoff',
  GeoPoint(5.6052, -0.1660),
  'Airport Residential, Accra',
);

Widget wrapWithDestination({
  void Function(RouteDraft draft)? onSubmit,
  PlaceService? places,
}) => wrap(
  onSubmit: onSubmit,
  places: places,
  dropoff: _dest(),
);

Widget wrap({
  void Function(RouteDraft draft)? onSubmit,
  PlaceService? places,
  TripStop? dropoff,
}) => ScreenUtilInit(
  designSize: const Size(390, 844),
  minTextAdapt: true,
  splitScreenMode: true,
  builder: (_, _) => MaterialApp(
    theme: MngTheme.light,
    home: Scaffold(
      body: RouteConfirmPage(
        calc: FareCalculator(),
        onSubmit: onSubmit ?? (_) {},
        places: places ?? _StubPlaces(),
        dropoff: dropoff,
      ),
    ),
  ),
);

Widget openHarness({
  void Function(RouteDraft draft)? onSubmit,
  PlaceService? places,
  TripStop? dropoff,
}) => ScreenUtilInit(
  designSize: const Size(390, 844),
  minTextAdapt: true,
  splitScreenMode: true,
  builder: (_, _) => MaterialApp(
    theme: MngTheme.light,
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () => pushRouteConfirmPage(
              context,
              calc: FareCalculator(),
              onSubmit: onSubmit ?? (_) {},
              places: places ?? _StubPlaces(),
              dropoff: dropoff,
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
  testWidgets('shows the pickup and the dropoff, not the distance twice', (
    tester,
  ) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrapWithDestination());
    expect(find.text('Osu, Accra'), findsOneWidget);
    expect(find.text('Airport Residential, Accra'), findsOneWidget);
  });

  testWidgets('summarises the measured distance, drive time and fare', (
    tester,
  ) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrapWithDestination());
    // Haversine over the two Accra constants, R = 6371.0088: 2.3299 km.
    // 8 * 2.3299 = 18.64, floored to the standard minimum of 23.00.
    // (5.00 + 1.80 * 2.3299) + 1.00, before the base fare and booking fee went.
    expect(find.text('2.3 km  ·  ~6 min drive'), findsOneWidget);
        // 8 * 2.3299 = 18.64, floored to the standard minimum of 23.00. Under the
    // old 0.35/km scale this was 0.82.
    expect(find.text('GHS 23.00'), findsOneWidget);
  });

  testWidgets('changing the category requotes the fare', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrapWithDestination());
    await tester.tap(find.byKey(const Key('chip-lite')));
    await tester.pump();
    // 6 * 2.3299 = 13.98, floored to the lite minimum of 17.00. lite is the
    // *cheaper* tier and has the *lowest* floor, so tapping it has to lower the
    // quote -- which is only meaningful because of both of those.
    expect(find.text('GHS 17.00'), findsOneWidget);
    expect(find.text('GHS 23.00'), findsNothing);
  });

  testWidgets('confirm submits the draft with the chosen stops', (
    tester,
  ) async {
    useDesignSurface(tester);
    RouteDraft? draft;
    await tester.pumpWidget(wrapWithDestination(onSubmit: (d) => draft = d));
    await tester.tap(find.byKey(const Key('chip-lite')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('confirmRouteButton')));
    await tester.pump();
    expect(draft, isNotNull);
    expect(draft!.pickup.address, kDefaultPickup.address);
    expect(draft!.pickup.point, kDefaultPickup.point);
    expect(draft!.dropoff.address, _dest().address);
    expect(draft!.category, RideCategory.lite);
  });

  group('with no destination chosen', () {
    // The page used to start on a fixed Accra destination, which meant a rider
    // who never touched the second field got a ride to the same airport every
    // single time. The destination is now chosen on the search page and arrives
    // here, so "not chosen" is a state this page has to survive.

    testWidgets('there is no demo destination to confirm', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap());
      expect(find.text('Airport Residential, Accra'), findsNothing);
      expect(find.text(kDefaultDropoff.address), findsNothing);
    });

    testWidgets('the fare is absent, not zero', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap());
      // "GHS 0.00" is a price, and a wrong one. A rider would book it.
      expect(find.textContaining('GHS'), findsNothing);
      expect(find.textContaining('km  ·  ~'), findsNothing);
    });

    testWidgets('it says what is missing instead', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap());
      expect(find.byKey(const Key('noDestinationYet')), findsOneWidget);
      expect(find.textContaining('Choose where you are going'), findsOneWidget);
    });

    testWidgets('confirm is disabled, and pressing it submits nothing', (
      tester,
    ) async {
      useDesignSurface(tester);
      var submits = 0;
      await tester.pumpWidget(wrap(onSubmit: (_) => submits++));
      final button = tester.widget<FilledButton>(
        find.byKey(const Key('confirmRouteButton')),
      );
      expect(
        button.onPressed,
        isNull,
        reason: 'there is no route to book, so there is nothing to press',
      );

      await tester.tap(
        find.byKey(const Key('confirmRouteButton')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(submits, 0);
    });

    testWidgets('it does not crash, which is the whole point', (tester) async {
      // A null force-unwrap in the distance getter used to take down the build
      // of this page for every rider who arrived without a destination --
      // which, with the destination now chosen on the search page, is a state
      // the page can genuinely be in.
      useDesignSurface(tester);
      await tester.pumpWidget(wrap());
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('pickupField')), findsOneWidget);
    });

    testWidgets('a destination typed here fills the fare in', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(
        wrap(places: _StubPlaces(matches: [_hit('Spintex Road', 5.58, -0.14)])),
      );

      await tester.tap(find.byKey(const Key('dropoffField')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('dropoffField')), 'Spintex');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('placeHit-Spintex Road')));
      await tester.pump();

      expect(find.text('Spintex Road'), findsOneWidget);
      expect(find.textContaining('GHS'), findsOneWidget);
      expect(find.byKey(const Key('noDestinationYet')), findsNothing);
    });
  });

  testWidgets('the sheet keeps its button clear of the bottom inset', (
    tester,
  ) async {
    useDesignSurface(tester);
    tester.view.padding = const FakeViewPadding(bottom: 102);
    await tester.pumpWidget(openHarness());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final button = tester.getBottomRight(
      find.byKey(const Key('confirmRouteButton')),
    );
    expect(button.dy, lessThanOrEqualTo(844 - 34));
  });

  testWidgets('pushRouteConfirmPage opens the page and submits its draft', (
    tester,
  ) async {
    useDesignSurface(tester);
    RouteDraft? draft;
    await tester.pumpWidget(
      openHarness(onSubmit: (d) => draft = d, dropoff: _dest()),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // A pushed page, not a scrim over a map: there is a title bar and a back
    // button, and nothing behind it to dismiss.
    expect(find.byType(BackButton), findsOneWidget);
    expect(find.text('Confirm your ride'), findsOneWidget);
    expect(find.byKey(const Key('confirmRouteButton')), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirmRouteButton')));
    await tester.pumpAndSettle();
    expect(draft, isNotNull);
    expect(draft!.pickup.address, kDefaultPickup.address);
    expect(draft!.dropoff.address, _dest().address);
  });

  testWidgets('the route sheet has no overflow at 200% text scale', (
    tester,
  ) async {
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
    final places = _StubPlaces(
      matches: [_hit('Kumasi, Ghana', 6.6885, -1.6244)],
    );
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
    final places = _StubPlaces(
      matches: [_hit('Kumasi, Ghana', 6.6885, -1.6244)],
    );
    await tester.pumpWidget(wrap(places: places));
    await tester.enterText(find.byKey(const Key('dropoffField')), 'Kumasi');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    await tester.tap(find.byKey(const Key('placeHit-Kumasi, Ghana')));
    await tester.pumpAndSettle();

    // GHS 0.82 is the fare for the 2.3 km demo route. Accra to Kumasi is about
    // 200 km, so this must not be it.
    expect(find.text('GHS 23.00'), findsNothing);
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

  // The demo-route warning now only fires when a rider has explicitly arrived
  // with the demo destination -- which the search page no longer does, but the
  // constant is still exported and a caller may still pass it. What matters is
  // that an *unchosen* destination produces no fare at all rather than the demo
  // one, and that is asserted in the "with no destination chosen" group above.
  testWidgets('a page with the demo destination still warns about it', (
    tester,
  ) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap(dropoff: kDefaultDropoff));
    expect(find.textContaining('demo route'), findsOneWidget);
  });

  testWidgets('choosing a real destination drops the demo-route warning', (
    tester,
  ) async {
    useDesignSurface(tester);
    final places = _StubPlaces(
      matches: [_hit('Kumasi, Ghana', 6.6885, -1.6244)],
    );
    await tester.pumpWidget(wrap(places: places, dropoff: kDefaultDropoff));
    await tester.enterText(find.byKey(const Key('dropoffField')), 'Kumasi');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    await tester.tap(find.byKey(const Key('placeHit-Kumasi, Ghana')));
    await tester.pumpAndSettle();
    expect(find.textContaining('demo route'), findsNothing);
  });
}
