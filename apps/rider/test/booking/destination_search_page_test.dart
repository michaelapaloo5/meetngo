import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/booking/destination_search_page.dart';
import 'package:meetngo_rider/src/data/place_service.dart';
import 'package:mng_core/mng_core.dart';

/// The full-screen "where to?" page.
///
/// What matters here is that it is a page and not a panel, that the field is
/// focused on arrival, and that a typed query produces a full list. The old
/// modal asked for four decisions at once over a map the rider could not move,
/// and a rider who wanted to change one of them had to reopen the whole thing.
class _StubPlaces implements PlaceService {
  _StubPlaces({this.matches = const []});

  final List<PlaceSuggestion> matches;

  final List<String> asked = [];

  @override
  Future<PlaceName?> reverse(GeoPoint point) async => null;

  @override
  Future<List<PlaceSuggestion>> search(String query) async {
    asked.add(query);
    return matches;
  }
}

PlaceSuggestion _hit(String label, double lat, double lng) =>
    PlaceSuggestion(label: label, point: GeoPoint(lat, lng));

/// Pumps the page inside a Navigator and records what it pops.
Future<PlaceSuggestion?> pumpPage(
  WidgetTester tester,
  PlaceService places, {
  List<PlaceSuggestion> recent = const [],
  String initialQuery = '',
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  PlaceSuggestion? popped;
  await tester.pumpWidget(
    ScreenUtilInit(
      designSize: const Size(390, 844),
      builder: (_, _) => MaterialApp(
        theme: MngTheme.light,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  popped = await Navigator.of(context).push<PlaceSuggestion>(
                    MaterialPageRoute<PlaceSuggestion>(
                      builder: (_) => DestinationSearchPage(
                        places: places,
                        recent: recent,
                        initialQuery: initialQuery,
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return popped;
}

void main() {
  void useDesignSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  group('it is a page, not a panel over a map', () {
    testWidgets('it fills the screen with white and has its own back button',
        (tester) async {
      useDesignSurface(tester);
      await pumpPage(tester, _StubPlaces());

      expect(find.byKey(const Key('destinationBack')), findsOneWidget);
      expect(find.text('Where to?'), findsOneWidget);
      // Opaque: the sheet it replaced covered the map it was describing, so a
      // rider checking where the pickup was had to dismiss the thing telling
      // them. A scrim would put that back.
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).last);
      expect(scaffold.backgroundColor, MngColors.page);
    });

    testWidgets('back returns nothing rather than a choice', (tester) async {
      useDesignSurface(tester);
      var popped = false;
      PlaceSuggestion? result;
      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(390, 844),
          builder: (_, _) => MaterialApp(
            theme: MngTheme.light,
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () async {
                    result = await Navigator.of(context)
                        .push<PlaceSuggestion>(
                      MaterialPageRoute<PlaceSuggestion>(
                        builder: (_) =>
                            DestinationSearchPage(places: _StubPlaces()),
                      ),
                    );
                    popped = true;
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('destinationBack')));
      await tester.pumpAndSettle();

      expect(popped, isTrue, reason: 'the flow closed rather than hanging');
      expect(result, isNull, reason: 'backing out is not choosing a place');
    });
  });

  group('the field is ready before the rider touches anything', () {
    testWidgets('it is focused when the page appears', (tester) async {
      useDesignSurface(tester);
      await pumpPage(tester, _StubPlaces());

      // A rider arrived here by tapping "where would you go?". Making them tap
      // the field again is a second tap for the same request, and on a
      // keyboard-first screen a page with no keyboard up is a list nobody can
      // fill.
      final field = tester.widget<TextField>(
        find.byKey(const Key('destinationSearchField')),
      );
      expect(field.focusNode?.hasFocus, isTrue);
    });
  });

  group('typing produces a list', () {
    testWidgets('every match is a full-width row', (tester) async {
      useDesignSurface(tester);
      final places = _StubPlaces(
        matches: [
          _hit('Spintex Road, Accra', 5.5833, -0.1400),
          _hit('Spintex Market, Accra', 5.5840, -0.1410),
          _hit('Spintex Taxi Rank, Accra', 5.5850, -0.1390),
        ],
      );
      await pumpPage(tester, places);

      await tester.enterText(
        find.byKey(const Key('destinationSearchField')),
        'Spintex',
      );
      // Past the 450ms debounce, and then the future.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('destinationResults')), findsOneWidget);
      for (final hit in places.matches) {
        expect(
          find.byKey(Key('destinationHit-${hit.label}')),
          findsOneWidget,
          reason: hit.label,
        );
      }
      // All three, and it says so.
      expect(find.text('3 matches'), findsOneWidget);
    });

    testWidgets('a match that is picked comes back as the choice',
        (tester) async {
      useDesignSurface(tester);
      final places = _StubPlaces(
        matches: [_hit('Spintex Road, Accra', 5.5833, -0.1400)],
      );
      PlaceSuggestion? result;
      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(390, 844),
          builder: (_, _) => MaterialApp(
            theme: MngTheme.light,
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () async {
                    result = await Navigator.of(context)
                        .push<PlaceSuggestion>(
                      MaterialPageRoute<PlaceSuggestion>(
                        builder: (_) => DestinationSearchPage(places: places),
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('destinationSearchField')),
        'Spintex',
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('destinationHit-Spintex Road, Accra')),
      );
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.label, 'Spintex Road, Accra');
      // The point travels with it, or the confirm page would show a name and
      // book a ride to a coordinate from a different place.
      expect(result!.point, const GeoPoint(5.5833, -0.1400));
    });

    testWidgets('a short query asks nothing, and says how long to type',
        (tester) async {
      useDesignSurface(tester);
      final places = _StubPlaces();
      await pumpPage(tester, places);

      await tester.enterText(
        find.byKey(const Key('destinationSearchField')),
        'Sp',
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      expect(places.asked, isEmpty,
          reason: 'Nominatim is capped at one request a second and treats '
              'autocomplete traffic as unacceptable');
      expect(find.textContaining('Type at least'), findsOneWidget);
    });

    testWidgets('nothing matched says so, and repeats the query',
        (tester) async {
      useDesignSurface(tester);
      await pumpPage(tester, _StubPlaces());

      await tester.enterText(
        find.byKey(const Key('destinationSearchField')),
        'Kumasi',
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      // "No results" with no query attached reads as a broken search rather
      // than a wrong one.
      expect(find.textContaining('Nothing matched "Kumasi"'), findsOneWidget);
      expect(find.byKey(const Key('destinationResults')), findsNothing);
    });

    testWidgets('typing does not fire a request per keystroke', (tester) async {
      useDesignSurface(tester);
      final places = _StubPlaces();
      await pumpPage(tester, places);

      for (final fragment in ['S', 'Sp', 'Spi', 'Spin', 'Spint', 'Spinte', 'Spintex']) {
        await tester.enterText(
          find.byKey(const Key('destinationSearchField')),
          fragment,
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      // One request for the whole word, not seven for the letters of it.
      expect(places.asked, ['Spintex']);
    });

    testWidgets('clearing the field empties the list', (tester) async {
      useDesignSurface(tester);
      final places = _StubPlaces(
        matches: [_hit('Spintex Road, Accra', 5.5833, -0.1400)],
      );
      await pumpPage(tester, places);
      await tester.enterText(
        find.byKey(const Key('destinationSearchField')),
        'Spintex',
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('destinationResults')), findsOneWidget);

      await tester.tap(find.byKey(const Key('clearDestinationSearch')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('destinationResults')), findsNothing);
      expect(find.byKey(const Key('clearDestinationSearch')), findsNothing);
    });
  });

  group('with nothing typed', () {
    testWidgets('a rider with history sees their real destinations',
        (tester) async {
      // Real trips, deduplicated. The alternative for an empty search is a
      // "popular destinations" list, which in a pilot with a handful of drivers
      // would be places nobody has ever ridden to.
      useDesignSurface(tester);
      await pumpPage(
        tester,
        _StubPlaces(),
        recent: [
          _hit('Spintex Road', 5.5833, -0.14),
          _hit('Airport Residential', 5.6052, -0.166),
        ],
      );

      expect(find.text('Recent destinations'), findsOneWidget);
      expect(
        find.byKey(const Key('destinationHit-Spintex Road')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('destinationHit-Airport Residential')),
        findsOneWidget,
      );
    });

    testWidgets('a rider with none sees a prompt, not an invented list',
        (tester) async {
      useDesignSurface(tester);
      await pumpPage(tester, _StubPlaces());
      expect(find.text('Where are you going?'), findsOneWidget);
      expect(find.byKey(const Key('destinationResults')), findsNothing);
    });
  });

  group('honesty about what is being searched', () {
    testWidgets('a long place name wraps rather than overflowing',
        (tester) async {
      useDesignSurface(tester);
      final long =
          'Patrice Lumumba Road, Airport Residential Area, Ayawaso West '
          'Municipal District, Greater Accra Region, Ghana';
      await pumpPage(tester, _StubPlaces(matches: [_hit(long, 5.60, -0.16)]));

      await tester.enterText(
        find.byKey(const Key('destinationSearchField')),
        'Patrice',
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      // A RenderFlex overflow is thrown, not painted. Nominatim's real
      // `display_name` is this long, so this is not a hypothetical.
      expect(tester.takeException(), isNull);
    });

    testWidgets('the page has no overflow at 200% text scale', (tester) async {
      useDesignSurface(tester);
      tester.view.padding = const FakeViewPadding(top: 90, bottom: 60);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
          child: ScreenUtilInit(
            designSize: const Size(390, 844),
            builder: (_, _) => MaterialApp(
              theme: MngTheme.light,
              home: Scaffold(
                body: DestinationSearchPage(places: _StubPlaces()),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
