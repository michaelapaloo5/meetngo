import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

import 'package:meetngo_rider/src/bookings/bookings_controller.dart';
import 'package:meetngo_rider/src/bookings/bookings_screen.dart';
import 'package:meetngo_rider/src/data/booked_trip.dart';
import 'package:meetngo_rider/src/data/location_service.dart';
import 'package:meetngo_rider/src/data/trip_repository.dart';

BookedTrip _ride(String id, TripState state) => BookedTrip(
  trip: Trip(
    id: id,
    riderId: 'r1',
    driverId: 'd1',
    category: RideCategory.standard,
    state: state,
    pickup: const TripStop(
      'Obibini Street, Tesano',
      GeoPoint(5.60, -0.19),
      'Obibini Street, Tesano, Ghana',
    ),
    dropoff: const TripStop(
      'Dansoman Police Station',
      GeoPoint(5.55, -0.21),
      'Dansoman Police Station, General Acheampong High Street',
    ),
    distanceKm: 6.9,
    fareGhs: 55.41,
    isDemo: false,
  ),
  createdAt: DateTime.utc(2026, 10, 2),
);

/// A repository whose `history` answers whatever the test tells it to, and can
/// be made to answer slowly.
class _FakeTrips implements TripRepository {
  _FakeTrips(this.rows);

  final List<BookedTrip> rows;

  /// Every `states` argument `history` was called with, in order.
  final List<Set<TripState>?> seen = <Set<TripState>?>[];

  /// If set, `history` waits on this before answering.
  Completer<void>? gate;

  @override
  Future<List<BookedTrip>> history({
    int limit = 50,
    Set<TripState>? states,
    DateTime? since,
    String? search,
  }) async {
    seen.add(states);
    if (gate != null) await gate!.future;
    if (states == null) return rows.take(limit).toList();
    return rows
        .where((r) => states.contains(r.trip.state))
        .take(limit)
        .toList();
  }

  @override
  Future<Trip?> activeTrip() async => null;

  @override
  Future<Trip?> tripById(String tripId) async => null;
  @override
  Stream<Trip> watchTrip(String tripId) => const Stream<Trip>.empty();
  @override
  Future<DriverContact> driverContact(String tripId) async =>
      const DriverContact.unavailable();
  @override
  Future<Trip> requestRide({
    required TripStop pickup,
    required TripStop dropoff,
    required RideCategory category,
    DateTime? scheduledFor,
  }) => throw UnimplementedError();
  @override
  Future<void> cancelTrip(String tripId) async {}
  @override
  Future<GeoPoint?> currentLocation() async => null;
  @override
  Future<DeviceLocation> locate() async =>
      const DeviceLocation(LocationOutcome.denied);
  @override
  Future<VehicleFix?> assignedDriverLocation(String? driverId) async => null;
  @override
  Future<void> raiseSos(String tripId, String note) async {}
}

void main() {
  group('BookingsFilters', () {
    test('Live covers every state the enum calls active', () {
      // Not a tautology: the point is that the chip list is exhaustive. A new
      // state added to TripState that is `isActive` has to be under "Live"
      // without anybody editing this file, because it is derived from the enum.
      final live = BookingsFilters.live.states!;
      for (final s in TripState.values.where((s) => s.isActive)) {
        expect(live, contains(s), reason: '$s is active but not under Live');
      }
      expect(live, isNot(contains(TripState.completed)));
    });

    test('all asks for no state filter at all', () {
      // Null means "no filter" in the repository. An empty set would mean "no
      // rides", so All must not be the one that accidentally asks for none.
      expect(BookingsFilters.all.states, isNull);
    });

    test('every trip state is reachable from a chip', () {
      // The complement of the test above, and the one that matters. A state that
      // is neither active nor terminal would be a ride that exists and that this
      // app cannot find, and neither test on its own would notice -- so this
      // walks the whole enum against the union of every chip.
      final reachable = <TripState>{
        for (final f in BookingsFilters.offered) ...?f.states,
      };
      for (final s in TripState.values) {
        expect(reachable, contains(s), reason: '$s has no chip');
      }
    });

    test('the chip list has no duplicates', () {
      // Two identically-worded chips ask the same question twice and the rider
      // cannot tell which is which. This exact bug shipped once: the row was
      // built as [all, live, ...chips] with `chips` itself also containing `all`.
      final labels = BookingsFilters.offered.map((f) => f.label).toList();
      expect(labels.toSet().length, labels.length);
    });

    test('only a completed ride is badged "Done"', () {
      // The bug this catches: `state.isActive ? 'Live' : 'Done'` badged a
      // **cancelled** ride "Done", on the same card whose own heading read "Trip
      // cancelled". Two labels in one row disagreeing, and a rider has to pick
      // which to believe.
      //
      // Stated over the whole enum rather than over `cancelled` alone: the
      // invariant is that "Done" means the ride happened, and a state added
      // later must not be able to break it by being quietly terminal.
      for (final s in TripState.values.where((s) => s != TripState.completed)) {
        expect(
          TripStateBadge.labelFor(s),
          isNot(equals('Done')),
          reason: '$s is badged "Done" but the ride did not complete',
        );
      }
      expect(TripStateBadge.labelFor(TripState.completed), 'Done');
      expect(TripStateBadge.labelFor(TripState.cancelled), 'Cancelled');
      for (final s in TripState.values.where((s) => s.isActive)) {
        expect(TripStateBadge.labelFor(s), 'Live', reason: '$s is running');
      }
    });

    test('a cancelled ride does not read as if it were under the Done chip', () {
      // "Done" means two things a few centimetres apart: on the chip it is "show
      // me completed rides", on a badge it is "this ride is over". Only
      // `completed` may wear the word -- which the test above walks the whole
      // enum for. This is the same claim from the other side, so that a future
      // change to the chip labels cannot quietly reintroduce the collision
      // without one of the two failing.
      expect(
        TripStateBadge.labelFor(TripState.cancelled).toLowerCase(),
        isNot(equals('done')),
        reason: 'a cancelled ride badged "Done" looks like it is in the Done filter',
      );
      expect(
        TripStateBadge.labelFor(TripState.cancelled).toLowerCase(),
        anyOf(
          equals('cancelled'),
          // Or it says something that is not a chip label at all, which is fine.
          isNot(anyOf(equals('all'), equals('live'), equals('done'))),
        ),
      );
    });

    test('sameAs compares the question, not the label', () {
      // Two chips could be worded differently and ask the same thing; skipping
      // the reload then is right. Equal questions with different labels must
      // compare equal or the selected chip would be wrong.
      expect(
        const BookingsFilter(
          label: 'Done',
          states: {TripState.completed},
        ).sameAs(BookingsFilters.completed),
        isTrue,
      );
      expect(BookingsFilters.all.sameAs(BookingsFilters.cancelled), isFalse);
    });
  });

  group('BookingsController filtering', () {
    test('passes the chip states to the repository', () async {
      final trips = _FakeTrips([_ride('a', TripState.completed)]);
      final c = BookingsController(trips);

      await c.load();
      expect(trips.seen.single, isNull);

      await c.setFilter(BookingsFilters.cancelled);
      expect(trips.seen.last, {TripState.cancelled});
    });

    test('re-tapping the selected chip does not re-read', () async {
      final trips = _FakeTrips(const []);
      final c = BookingsController(trips);
      await c.load();
      await c.setFilter(BookingsFilters.completed);
      expect(trips.seen.length, 2);
      await c.setFilter(BookingsFilters.completed);
      expect(
        trips.seen.length,
        2,
        reason: 'the same question twice should not be asked twice',
      );
    });

    test('a slow read cannot overwrite a newer one', () async {
      // The shape that produced the frozen tracking screen: two reads in
      // flight, the first released second. If the first won, the list would show
      // the filter the rider has already moved off, with the chip on something
      // else.
      //
      // This also pins down something the first version of the test got wrong,
      // and the wrong answer was the bug: the controller used to coalesce *every*
      // overlapping load, so the second chip tap's read was dropped outright and
      // the rider was left holding the first filter's rows under the second
      // chip's label. `seen` has to grow.
      final trips = _FakeTrips([_ride('a', TripState.completed)]);
      final c = BookingsController(trips);
      await c.load();

      final slow = Completer<void>();
      trips.gate = slow;
      final first = c.setFilter(BookingsFilters.completed);
      await Future<void>.delayed(Duration.zero);
      trips.gate = null;
      final second = c.setFilter(BookingsFilters.cancelled);

      // The stale read lands *after* the fresh one.
      slow.complete();
      await Future.wait([first, second]);

      expect(c.filter.label, 'Cancelled');
      expect(
        trips.seen.length,
        3,
        reason: 'both reads ran; the loser must not overwrite the winner',
      );
      expect(trips.seen.last, {TripState.cancelled});
    });

    test('the list ends up matching the chip, not the last read to start', () async {
      // The point of the generation guard, stated as an outcome rather than as a
      // call count: after two overlapping filter changes the rows on screen are
      // the ones the *newest* filter asked for.
      final trips = _FakeTrips([
        _ride('a', TripState.completed),
        _ride('b', TripState.cancelled),
      ]);
      final c = BookingsController(trips);
      await c.load();

      final slow = Completer<void>();
      trips.gate = slow;
      final first = c.setFilter(BookingsFilters.completed);
      await Future<void>.delayed(Duration.zero);
      trips.gate = null;
      final second = c.setFilter(BookingsFilters.cancelled);

      // The stale read resolves last, so it has every chance to win by writing
      // its rows after the fresh one has already answered.
      slow.complete();
      await Future.wait([first, second]);

      expect(
        c.trips.map((r) => r.trip.id).toList(),
        ['b'],
        reason: "the completed ride must not survive under the Cancelled chip",
      );
    });

    test('an overtaken read leaves the controller able to load again', () async {
      // The `_loading` flag is only cleared by the newest request. If the losing
      // read cleared it too the flag would be wrong; if it cleared it while the
      // winner was still running, a later load would be dropped silently.
      final trips = _FakeTrips(const []);
      final c = BookingsController(trips);
      await c.load();
      expect(c.loading, isFalse);

      final slow = Completer<void>();
      trips.gate = slow;
      final first = c.setFilter(BookingsFilters.completed);
      await Future<void>.delayed(Duration.zero);
      // Released, or the second read would block on the same gate.
      trips.gate = null;
      final second = c.setFilter(BookingsFilters.cancelled);
      // A tick, so `second` gets as far as starting its own read before the
      // first one is answered. `second` deliberately waits on `first`, so
      // completing the gate before that point would be a deadlock, not a race.
      await Future<void>.delayed(Duration.zero);
      slow.complete();
      await Future.wait([first, second]);

      expect(c.loading, isFalse, reason: 'no request is running any more');
      await c.load();
      expect(c.loading, isFalse);
    });
  });

  group('BookingsScreen chips', () {
    Future<void> pumpScreen(WidgetTester t, _FakeTrips trips) async {
      // `ScreenUtilInit` is not optional here: the chips are sized with `.h` and
      // `.w`, and outside the init those extensions throw a `LateError` naming
      // an uninitialised field rather than a usable size. It has to be sized the
      // way the handset is, or the chip row would lay out at a size nothing in
      // the app ever uses.
      await t.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(390, 844),
          builder: (_, _) => ChangeNotifierProvider<BookingsController>(
            create: (_) => BookingsController(trips),
            child: const MaterialApp(home: BookingsScreen()),
          ),
        ),
      );
      await t.pumpAndSettle();
    }

    testWidgets('shows one chip per filter and applies the tap', (t) async {
      final trips = _FakeTrips([
        _ride('a', TripState.completed),
        _ride('b', TripState.cancelled),
      ]);
      await pumpScreen(t, trips);

      for (final f in [BookingsFilters.all, BookingsFilters.live]) {
        expect(
          find.byKey(Key('filterChip-${f.label}')),
          findsOneWidget,
          reason: '${f.label} has no chip',
        );
      }

      await t.tap(find.byKey(const Key('filterChip-Cancelled')));
      await t.pumpAndSettle();

      expect(find.byKey(const Key('tripRow-a')), findsNothing);
      expect(find.byKey(const Key('tripRow-b')), findsOneWidget);
    });

    testWidgets(
      'an empty filtered list does not claim the rider has no rides',
      (t) async {
        // The sentence matters: "No rides yet" to somebody with 24 rides is
        // something they would act on. A filter that matched nothing has to say
        // so, and offer the way back.
        final trips = _FakeTrips([_ride('a', TripState.completed)]);
        await pumpScreen(t, trips);

        await t.tap(find.byKey(const Key('filterChip-Cancelled')));
        await t.pumpAndSettle();

        expect(find.text('No rides yet'), findsNothing);
        expect(find.textContaining('cancelled'), findsWidgets);
        expect(find.byKey(const Key('emptyStateAction')), findsOneWidget);

        await t.tap(find.byKey(const Key('emptyStateAction')));
        await t.pumpAndSettle();
        expect(find.byKey(const Key('tripRow-a')), findsOneWidget);
      },
    );

    testWidgets('Live shows a ride that is arriving, not just assigned', (
      t,
    ) async {
      // The reason "Live" is a set. A single-state filter would show a rider
      // whose car is two minutes away an empty list.
      final trips = _FakeTrips([
        _ride('a', TripState.completed),
        _ride('b', TripState.arriving),
      ]);
      await pumpScreen(t, trips);

      await t.tap(find.byKey(const Key('filterChip-Live')));
      await t.pumpAndSettle();

      expect(find.byKey(const Key('tripRow-b')), findsOneWidget);
      expect(find.byKey(const Key('tripRow-a')), findsNothing);
    });
  });
}
