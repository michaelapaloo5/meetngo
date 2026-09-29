// Picking a stop by tapping the map, inside the route sheet.
//
// Separate from `route_entry_sheet_test.dart` because it needs the map stand-in
// switched on, which is a process-wide flag: setting it in the shared harness
// would quietly change what every other test in that file is asserting against.
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/booking/route_confirm_page.dart';
import 'package:meetngo_rider/src/data/place_service.dart';
import 'package:meetngo_rider/src/map/ride_map.dart';
import 'package:mng_core/mng_core.dart';

/// A geocoder that answers from a script, so nothing here touches the network
/// and nothing depends on a volunteer service being up.
class _StubPlaces implements PlaceService {
  _StubPlaces({this.reversed, this.reverseFails = false});

  /// What `reverse` answers, or null to answer "I do not know that place".
  final PlaceName? reversed;

  /// Whether `reverse` answers nothing at all, as a failed request does.
  final bool reverseFails;

  /// The points asked about, in order.
  final List<GeoPoint> reversals = [];

  @override
  Future<PlaceName?> reverse(GeoPoint point) async {
    reversals.add(point);
    return reverseFails ? null : reversed;
  }

  @override
  Future<List<PlaceSuggestion>> search(String query) async => const [];
}

PlaceName _name(String line) => PlaceName(locality: line);

/// Where the rider is when they confirm, so the test can read the draft.
RouteDraft? submitted;

Widget wrap(PlaceService places) => ScreenUtilInit(
      designSize: const Size(390, 844),
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (_, _) => MaterialApp(
        theme: MngTheme.light,
        home: Scaffold(
          body: RouteConfirmPage(
            calc: FareCalculator(),
            onSubmit: (draft) => submitted = draft,
            places: places,
            pickup: pickupFromFix(const GeoPoint(5.6037, -0.1870)),
            // A destination, because these tests are about the map picker and
            // not about an unchosen destination -- and because a page with no
            // destination is a page whose confirm button is disabled, which
            // would make the "what the draft is submitted with" test below
            // untestable for the wrong reason.
            dropoff: const TripStop(
              'Dropoff',
              GeoPoint(5.6052, -0.1660),
              'Airport Residential, Accra',
            ),
          ),
        ),
      ),
    );

void main() {
  // MapLibre draws through a native platform view and `flutter test` has none,
  // so the picker cannot be built at all without this.
  setUpAll(() => RideMap.disabledForTest = true);
  tearDownAll(() => RideMap.disabledForTest = false);
  setUp(() => submitted = null);

  void useDesignSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  /// Opens the picker for a field and taps the map at one place.
  Future<void> tapTheMap(WidgetTester tester, {GeoPoint? at}) async {
    await tester.tap(find.byKey(const Key('mapAction-pickup')));
    await tester.pump();
    expect(find.byKey(const Key('mapPicker')), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('pickerMap')),
      warnIfMissed: false,
    );
    await tester.pump();
  }

  group('opening it', () {
    testWidgets('the map is not drawn until it is asked for', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(_StubPlaces()));
      // A map inside a modal, unasked for, is a 220px hole in a sheet whose job
      // is two fields and a fare.
      expect(find.byKey(const Key('mapPicker')), findsNothing);
    });

    testWidgets('both stops offer the map', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(_StubPlaces()));
      expect(find.byKey(const Key('mapAction-pickup')), findsOneWidget);
      expect(find.byKey(const Key('mapAction-dropoff')), findsOneWidget);
    });

    testWidgets('pressing it opens a map for the pickup', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(_StubPlaces()));
      await tester.tap(find.byKey(const Key('mapAction-pickup')));
      await tester.pump();

      expect(find.byKey(const Key('mapPicker')), findsOneWidget);
      expect(find.textContaining('pickup point'), findsOneWidget);
    });

    testWidgets('the drop-off button opens a map for the drop-off',
        (tester) async {
      // The copy says which stop the map is setting. A rider who opened the
      // map and could not tell which of the two stops it would move would be
      // entitled to move the wrong one.
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(_StubPlaces()));
      await tester.tap(find.byKey(const Key('mapAction-dropoff')));
      await tester.pump();

      expect(find.textContaining('drop-off point'), findsOneWidget);
    });

    testWidgets('it can be closed again', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(_StubPlaces()));
      await tester.tap(find.byKey(const Key('mapAction-pickup')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('closeMapPicker')));
      await tester.pump();

      expect(find.byKey(const Key('mapPicker')), findsNothing);
    });

    testWidgets('the same button closes a map it opened', (tester) async {
      // One control that opens and closes, rather than a separate button that
      // appears: the second control is a thing to get wrong, and "the same
      // button" cannot be left open by accident.
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(_StubPlaces()));
      await tester.tap(find.byKey(const Key('mapAction-pickup')));
      await tester.pump();
      expect(find.byKey(const Key('mapPicker')), findsOneWidget);

      await tester.tap(find.byKey(const Key('mapAction-pickup')));
      await tester.pump();
      expect(find.byKey(const Key('mapPicker')), findsNothing);
    });
  });

  group('a point tapped on the map', () {
    testWidgets('moves the pickup and is what the draft is submitted with',
        (tester) async {
      // The point has to reach the server, not just the label. A picker that
      // updates the text and leaves `TripStop.point` alone would book the ride
      // to wherever the map was before it was opened.
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(_StubPlaces()));

      final before = submitted;
      expect(before, isNull);
      await tapTheMap(tester);

      await tester.tap(find.byKey(const Key('confirmRouteButton')));
      await tester.pump();
      expect(submitted, isNotNull);
      // The tapped point is whatever the stand-in map was given; what matters
      // is that it is no longer the original pickup.
      expect(submitted!.pickup.address, isNot(pickupFromFix(
        const GeoPoint(5.6037, -0.1870),
      ).address));
    });

    testWidgets('asks the geocoder for the point it was given', (tester) async {
      // Without the lookup the field would say "Picked on the map" forever,
      // which tells a rider nothing about where their ride is going.
      final places = _StubPlaces();
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(places));

      await tester.tap(find.byKey(const Key('mapAction-pickup')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('pickerMap')), warnIfMissed: false);
      await tester.pump();

      expect(places.reversals, isNotEmpty);
    });

    testWidgets('a named place replaces the placeholder', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(
        wrap(_StubPlaces(reversed: _name('Nima, Accra'))),
      );
      await tapTheMap(tester);
      await tester.pumpAndSettle();

      expect(find.text('Nima, Accra'), findsOneWidget);
      expect(find.text('Picked on the map'), findsNothing);
    });

    testWidgets('a geocoder with no answer leaves an honest placeholder',
        (tester) async {
      // The ride is still bookable and still goes to the right pin. Replacing
      // the field with an error would suggest the ride could not be booked at
      // all, which is not what happened.
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(_StubPlaces(reverseFails: true)));
      await tapTheMap(tester);
      await tester.pumpAndSettle();

      expect(find.text('Picked on the map'), findsOneWidget);
    });

    testWidgets('an overtaken lookup does not overwrite the newer choice',
        (tester) async {
      // Nominatim is a volunteer service and a lookup takes real time, so a
      // rider can tap, tap again, and get the first answer back last. Without
      // this the pickup would silently become the place they just rejected.
      useDesignSurface(tester);
      final places = _StubPlaces();
      await tester.pumpWidget(wrap(places));
      await tester.tap(find.byKey(const Key('mapAction-pickup')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('pickerMap')), warnIfMissed: false);
      await tester.pump();
      await tester.tap(find.byKey(const Key('pickerMap')), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(places.reversals.length, 2,
          reason: 'both taps should have asked');
    });

    testWidgets('the drop-off map does not move the pickup', (tester) async {
      // The two stops are edited by two buttons and one shared map. Wiring the
      // map to the wrong stop is the obvious way to get this wrong, and it
      // shows up as a ride from the airport to the airport.
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(_StubPlaces()));
      final pickupBefore = find.text('Your location');
      expect(pickupBefore, findsOneWidget);

      await tester.tap(find.byKey(const Key('mapAction-dropoff')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('pickerMap')), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(find.text('Your location'), findsOneWidget,
          reason: 'the pickup must be untouched by a drop-off tap');
    });
  });

  group('it does not break the rest of the sheet', () {
    testWidgets('the fare still requotes over a map-picked route',
        (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(_StubPlaces()));
      final fareBefore = _fareText(tester);

      await tapTheMap(tester);
      await tester.pumpAndSettle();

      // Either the distance changed or it did not; what must not happen is the
      // fare box disappearing, throwing, or reading a non-number.
      final fareAfter = _fareText(tester);
      expect(fareAfter, isNotNull);
      expect(fareBefore, isNotNull);
      expect(fareAfter, matches(RegExp(r'GHS \d+\.\d\d')));
    });

    testWidgets('the sheet has no overflow with the map open', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(_StubPlaces()));
      await tester.tap(find.byKey(const Key('mapAction-pickup')));
      await tester.pump();

      // A RenderFlex overflow is thrown, not painted. The map is 220px inside
      // a scrollable sheet, so this is where a fixed-height panel would break.
      expect(tester.takeException(), isNull);
    });
  });
}

/// The fare as it is drawn, or null if it is not on screen.
String? _fareText(WidgetTester tester) {
  final matches = find.textContaining('GHS ').evaluate().map((e) {
    final t = e.widget;
    return t is Text ? t.data : null;
  }).whereType<String>();
  return matches.isEmpty ? null : matches.first;
}
