import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';

import 'package:meetngo_rider/src/booking/route_confirm_page.dart';
import 'package:meetngo_rider/src/data/place_service.dart';
import 'package:meetngo_rider/src/map/ride_map.dart';
import 'package:meetngo_rider/src/data/saved_place_repository.dart';

class _NoPlaces implements PlaceService {
  @override
  Future<List<PlaceSuggestion>> search(String query) async => const [];

  @override
  Future<PlaceName?> reverse(GeoPoint point) async => null;
}

class _FakeSaved implements SavedPlaceRepository {
  final List<SavedPlace> written = <SavedPlace>[];
  bool failWrite = false;

  @override
  Future<List<SavedPlace>> all() async => const [];

  @override
  Future<SavedPlace?> save(SavedPlace place) async {
    if (failWrite) throw Exception('refused');
    written.add(place);
    return SavedPlace(
      id: 'new',
      label: place.label,
      address: place.address,
      point: place.point,
    );
  }

  @override
  Future<void> remove(String id) async {}
}

/// A destination the rider has actually chosen, so the save control can appear.
const dropoff = TripStop(
  'Dropoff',
  GeoPoint(5.6052, -0.166),
  'Spintex Road, Accra',
);

void main() {
  setUpAll(() => RideMap.disabledForTest = true);
  tearDownAll(() => RideMap.disabledForTest = false);

  Future<SavedPlaceRepository?> pump(
    WidgetTester t, {
    TripStop? to = dropoff,
    SavedPlaceRepository? saved,
    void Function(SavedPlace)? onSaved,
  }) async {
    await t.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(390, 844),
        builder: (_, _) => MaterialApp(
          home: Scaffold(
            body: RouteConfirmPage(
              calc: FareCalculator(),
              onSubmit: (_) {},
              places: _NoPlaces(),
              pickup: const TripStop('Pickup', GeoPoint(5.5639, -0.195), 'Osu'),
              dropoff: to,
              saved: saved,
              onPlaceSaved: onSaved == null ? null : (p) => onSaved(p),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    return saved;
  }

  group('the save control', () {
    testWidgets('is absent with nowhere to save to', (t) async {
      // Null hides it. A bookmark button that opens a dialog and then does
      // nothing is a trap, not a feature.
      await pump(t, saved: null);
      expect(find.byKey(const Key('savePlaceButton')), findsNothing);
    });

    testWidgets('is absent before a destination is chosen', (t) async {
      // Nothing to save yet. Showing it would open a dialog about nothing.
      await pump(t, to: null, saved: _FakeSaved());
      expect(find.byKey(const Key('savePlaceButton')), findsNothing);
    });

    testWidgets('is there once there is a destination', (t) async {
      await pump(t, saved: _FakeSaved());
      expect(find.byKey(const Key('savePlaceButton')), findsOneWidget);
    });
  });

  group('saving', () {
    testWidgets('stores the address and the name the rider typed', (t) async {
      final repo = _FakeSaved();
      await pump(t, saved: repo);

      await t.tap(find.byKey(const Key('savePlaceButton')));
      await t.pumpAndSettle();

      // The dialog opens pre-filled with the address, so tapping straight
      // through still gets something useful.
      final field = find.byKey(const Key('savedPlaceNameField'));
      expect(field, findsOneWidget);
      await t.enterText(field, 'Home');
      await t.tap(find.byKey(const Key('confirmSavePlace')));
      await t.pumpAndSettle();

      expect(repo.written, hasLength(1));
      final saved = repo.written.single;
      expect(
        saved.label,
        'Home',
        reason: 'the name is what the rider calls it',
      );
      expect(
        saved.address,
        'Spintex Road, Accra',
        reason: 'the address is what the chip must send a car to',
      );
      expect(
        saved.point.lat,
        5.6052,
        reason: 'the point has to be the real one',
      );
    });

    testWidgets('the default name is the place, not an empty field', (t) async {
      final repo = _FakeSaved();
      await pump(t, saved: repo);
      await t.tap(find.byKey(const Key('savePlaceButton')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('confirmSavePlace')));
      await t.pumpAndSettle();

      expect(repo.written.single.label, 'Spintex Road, Accra');
    });

    testWidgets('cancelling writes nothing', (t) async {
      final repo = _FakeSaved();
      await pump(t, saved: repo);
      await t.tap(find.byKey(const Key('savePlaceButton')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('cancelSavePlace')));
      await t.pumpAndSettle();

      expect(repo.written, isEmpty);
      expect(find.byKey(const Key('savedPlaceNameField')), findsNothing);
    });

    testWidgets('an empty name writes nothing', (t) async {
      final repo = _FakeSaved();
      await pump(t, saved: repo);
      await t.tap(find.byKey(const Key('savePlaceButton')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('savedPlaceNameField')), '   ');
      await t.tap(find.byKey(const Key('confirmSavePlace')));
      await t.pumpAndSettle();

      expect(repo.written, isEmpty, reason: 'a blank name is not a place');
    });

    testWidgets('tells the caller, so the destination screen is not stale', (
      t,
    ) async {
      SavedPlace? announced;
      await pump(t, saved: _FakeSaved(), onSaved: (p) => announced = p);
      await t.tap(find.byKey(const Key('savePlaceButton')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('confirmSavePlace')));
      await t.pumpAndSettle();

      expect(announced, isNotNull);
      expect(announced!.address, 'Spintex Road, Accra');
    });

    testWidgets('says so when it worked', (t) async {
      await pump(t, saved: _FakeSaved());
      await t.tap(find.byKey(const Key('savePlaceButton')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('savedPlaceNameField')), 'Home');
      await t.tap(find.byKey(const Key('confirmSavePlace')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('placeSavedSnack')), findsOneWidget);
    });

    testWidgets('a refused write says so and does not throw', (tester) async {
      // The failure the rider can cause is a database one, and swallowing it
      // silently would leave them tapping Save again for no reason.
      final repo = _FakeSaved()..failWrite = true;
      await pump(tester, saved: repo);
      await tester.tap(find.byKey(const Key('savePlaceButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirmSavePlace')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('placeSaveFailedSnack')), findsOneWidget);
      expect(
        tester.takeException(),
        isNull,
        reason: 'a failed save is a message, not a crash',
      );
    });
  });
}
