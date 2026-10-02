import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';

import 'package:meetngo_rider/src/booking/destination_search_page.dart';
import 'package:meetngo_rider/src/data/place_service.dart';
import 'package:meetngo_rider/src/data/saved_place_repository.dart';

SavedPlace _place(
  String id,
  String label, {
  String? address,
  double lat = 5.56,
}) => SavedPlace(
  id: id,
  label: label,
  address: address ?? '$label, Accra',
  point: GeoPoint(lat, -0.19),
);

class _FakeSaved implements SavedPlaceRepository {
  _FakeSaved([List<SavedPlace>? rows]) : rows = rows ?? const [];

  List<SavedPlace> rows;
  final List<String> removed = [];

  @override
  Future<List<SavedPlace>> all() async => rows;

  @override
  Future<void> remove(String id) async => removed.add(id);

  @override
  Future<SavedPlace?> save(SavedPlace place) async => place;
}

class _NoPlaces implements PlaceService {
  @override
  Future<List<PlaceSuggestion>> search(String query) async => const [];

  @override
  Future<PlaceName?> reverse(GeoPoint point) async => null;
}

void main() {
  /// Builds the page and reports what it popped, if anything.
  Future<PlaceSuggestion?> pump(
    WidgetTester t,
    SavedPlaceRepository? saved, {
    List<PlaceSuggestion> recent = const [],
  }) async {
    PlaceSuggestion? popped;
    await t.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(390, 844),
        builder: (_, _) => MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: DestinationSearchPage(
                places: _NoPlaces(),
                recent: recent,
                saved: saved,
              ),
            ),
          ),
        ),
      ),
    );
    // The page pops with `Navigator.pop`, so the route has to be able to.
    await t.pumpAndSettle();
    return popped;
  }

  group('saved places row', () {
    testWidgets('is absent when there is no repository', (t) async {
      // Null hides the section rather than showing an empty heading. A rider who
      // has never saved a place should not be shown a place to put one.
      await pump(t, null);
      expect(find.byKey(const Key('savedPlacesRow')), findsNothing);
    });

    testWidgets('is absent when the rider has saved nothing', (t) async {
      await pump(t, _FakeSaved(const []));
      expect(find.byKey(const Key('savedPlacesRow')), findsNothing);
    });

    testWidgets('lists one chip per saved place', (t) async {
      await pump(t, _FakeSaved([_place('a', 'Home'), _place('b', 'Work')]));
      expect(find.byKey(const Key('savedPlacesRow')), findsOneWidget);
      expect(find.byKey(const Key('savedPlace-a')), findsOneWidget);
      expect(find.byKey(const Key('savedPlace-b')), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Work'), findsOneWidget);
    });

    testWidgets('the chip says the label the rider gave it', (t) async {
      // Not the address. The chip is how the rider recognises their own place;
      // showing "Spintex Road, Accra" where they wrote "Home" makes two places
      // they recognise and neither of them is this one.
      await pump(
        t,
        _FakeSaved([_place('a', 'Home', address: 'Spintex Rd, Accra')]),
      );
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Spintex Rd, Accra'), findsNothing);
    });

    testWidgets('a place with no readable point is not offered', (t) async {
      // `GeoPoint(0, 0)` is the sea off Ghana and is what a malformed row
      // decodes to. Offering it would let a rider select a destination no car
      // can be sent to.
      await pump(
        t,
        _FakeSaved([
          const SavedPlace(
            id: 'broken',
            label: 'Broken',
            address: 'Broken, Accra',
            point: GeoPoint(0, 0),
          ),
          _place('a', 'Home'),
        ]),
      );
      expect(find.byKey(const Key('savedPlace-broken')), findsNothing);
      expect(find.byKey(const Key('savedPlace-a')), findsOneWidget);
    });

    testWidgets('a failed load hides the row and leaves search working', (
      t,
    ) async {
      // Not an error state. This screen's job is search, and search does not need
      // saved places.
      final broken = _BrokenSaved();
      await pump(t, broken);
      expect(find.byKey(const Key('savedPlacesRow')), findsNothing);
      expect(find.byKey(const Key('destinationSearchField')), findsOneWidget);
    });

    testWidgets('the results list is still there underneath', (t) async {
      // The saved row is a convenience above the list, not a replacement for it.
      // This is the bug the first version of this had.
      await pump(
        t,
        _FakeSaved([_place('a', 'Home')]),
        recent: [
          const PlaceSuggestion(
            label: 'Recent place',
            point: GeoPoint(5.5, -0.2),
          ),
        ],
      );
      expect(find.byKey(const Key('savedPlacesRow')), findsOneWidget);
      expect(find.text('Recent destinations'), findsOneWidget);
      expect(find.text('Recent place'), findsOneWidget);
    });

    testWidgets('typing hides them, because the matches are the answer', (
      t,
    ) async {
      await pump(
        t,
        _FakeSaved([_place('a', 'Home')]),
        recent: [
          const PlaceSuggestion(
            label: 'Recent place',
            point: GeoPoint(5.5, -0.2),
          ),
        ],
      );
      await t.enterText(
        find.byKey(const Key('destinationSearchField')),
        'Spintex',
      );
      await t.pumpAndSettle();
      expect(find.byKey(const Key('savedPlacesRow')), findsNothing);
    });
  });

  group('choosing a saved place', () {
    testWidgets('pops the address, not the label the rider gave it', (t) async {
      // This is what the confirm screen prints as the destination, on the pin,
      // on the trip row and on the receipt. "Home" is not a place.
      PlaceSuggestion? popped;
      await t.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(390, 844),
          builder: (_, _) => MaterialApp(
            home: Navigator(
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (context) => Scaffold(
                  body: Center(
                    child: ElevatedButton(
                      onPressed: () async {
                        popped = await Navigator.of(context)
                            .push<PlaceSuggestion>(
                              MaterialPageRoute<PlaceSuggestion>(
                                builder: (_) => DestinationSearchPage(
                                  places: _NoPlaces(),
                                  saved: _FakeSaved([
                                    _place(
                                      'a',
                                      'Home',
                                      address: 'Spintex Road, Accra',
                                    ),
                                  ]),
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
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();

      await t.tap(find.byKey(const Key('savedPlace-a')));
      await t.pumpAndSettle();

      expect(popped, isNotNull, reason: 'the page must return a destination');
      expect(popped!.label, 'Spintex Road, Accra');
      expect(popped!.point.lat, 5.56);
    });

    testWidgets('falls back to the label when there is no address', (t) async {
      // Better a bare "Home" on the map than an empty pin the rider cannot
      // read at all, and the point is still right.
      PlaceSuggestion? popped;
      await t.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(390, 844),
          builder: (_, _) => MaterialApp(
            home: Navigator(
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (context) => Scaffold(
                  body: Center(
                    child: ElevatedButton(
                      onPressed: () async {
                        popped = await Navigator.of(context)
                            .push<PlaceSuggestion>(
                              MaterialPageRoute<PlaceSuggestion>(
                                builder: (_) => DestinationSearchPage(
                                  places: _NoPlaces(),
                                  saved: _FakeSaved([
                                    _place('a', 'Home', address: '   '),
                                  ]),
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
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('savedPlace-a')));
      await t.pumpAndSettle();

      expect(popped!.label, 'Home');
    });
  });

  group('removing a saved place', () {
    testWidgets('the chip disappears and the row is deleted', (t) async {
      final repo = _FakeSaved([_place('a', 'Home'), _place('b', 'Work')]);
      await pump(t, repo);

      await t.tap(find.byIcon(Icons.close).first);
      await t.pumpAndSettle();

      expect(repo.removed, ['a']);
      expect(find.byKey(const Key('savedPlace-a')), findsNothing);
      expect(find.byKey(const Key('savedPlace-b')), findsOneWidget);
    });

    testWidgets('the row vanishes when the last place goes', (t) async {
      // An empty row of nothing is a heading over no content, which is the thing
      // this feature is meant to avoid.
      final repo = _FakeSaved([_place('a', 'Home')]);
      await pump(t, repo);
      await t.tap(find.byIcon(Icons.close).first);
      await t.pumpAndSettle();
      expect(find.byKey(const Key('savedPlacesRow')), findsNothing);
    });

    testWidgets('it disappears even when the delete does not land', (t) async {
      // A row that stays until the page is reopened reads as "the delete failed",
      // and the rider taps it again. `remove` swallows its own errors, so the
      // worst case is that it comes back on the next open -- recoverable. A row
      // that never goes is not.
      final repo = _FailingSaved([_place('a', 'Home')]);
      await pump(t, repo);
      await t.tap(find.byIcon(Icons.close).first);
      await t.pumpAndSettle();
      expect(find.byKey(const Key('savedPlace-a')), findsNothing);
    });
  });
}

class _BrokenSaved implements SavedPlaceRepository {
  @override
  Future<List<SavedPlace>> all() async => throw Exception('network down');

  @override
  Future<void> remove(String id) async {}

  @override
  Future<SavedPlace?> save(SavedPlace place) async => null;
}

class _FailingSaved implements SavedPlaceRepository {
  _FailingSaved(this.rows);

  final List<SavedPlace> rows;

  @override
  Future<List<SavedPlace>> all() async => rows;

  @override
  Future<void> remove(String id) async => throw Exception('write refused');

  @override
  Future<SavedPlace?> save(SavedPlace place) async => null;
}
