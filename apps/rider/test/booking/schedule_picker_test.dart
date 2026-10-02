import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';

import 'package:meetngo_rider/src/app/rider_flow.dart';
import 'package:meetngo_rider/src/booking/route_confirm_page.dart';
import 'package:meetngo_rider/src/booking/schedule_picker.dart';
import 'package:meetngo_rider/src/data/booked_trip.dart';
import 'package:meetngo_rider/src/data/location_service.dart';
import 'package:meetngo_rider/src/data/trip_functions.dart';
import 'package:meetngo_rider/src/data/trip_repository.dart';

/// Records what it was asked for, so "the flow forwarded it" is a fact rather
/// than an absence of complaint.
class _RecordingTrips implements TripRepository {
  DateTime? seenScheduledFor;
  int calls = 0;

  @override
  Future<Trip> requestRide({
    required TripStop pickup,
    required TripStop dropoff,
    required RideCategory category,
    DateTime? scheduledFor,
  }) async {
    calls++;
    seenScheduledFor = scheduledFor;
    return const Trip(
      id: 't1',
      riderId: 'r1',
      driverId: null,
      category: RideCategory.standard,
      state: TripState.requested,
      pickup: TripStop('Pickup', GeoPoint(5.6037, -0.187), 'Osu, Accra'),
      dropoff: TripStop(
        'Dropoff',
        GeoPoint(5.6052, -0.166),
        'Airport Residential, Accra',
      ),
      distanceKm: 6.4,
      fareGhs: 51.2,
      isDemo: false,
    );
  }

  @override
  Future<Trip?> activeTrip() async => null;
  @override
  Stream<Trip> watchTrip(String tripId) => const Stream<Trip>.empty();
  @override
  Future<DriverContact> driverContact(String tripId) async =>
      const DriverContact.unavailable();
  @override
  Future<List<BookedTrip>> history({
    int limit = 50,
    Set<TripState>? states,
    DateTime? since,
    String? search,
  }) async => const [];
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

class _StubFunctions implements TripFunctions {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const pickup = TripStop('Pickup', GeoPoint(5.6037, -0.187), 'Osu, Accra');
  const dropoff = TripStop(
    'Dropoff',
    GeoPoint(5.6052, -0.166),
    'Airport Residential, Accra',
  );

  group('quarterHourFrom', () {
    test('leaves an exact quarter alone', () {
      expect(
        SchedulePicker.quarterHourFrom(DateTime(2026, 10, 2, 9, 15)),
        DateTime(2026, 10, 2, 9, 15),
      );
      expect(
        SchedulePicker.quarterHourFrom(DateTime(2026, 10, 2, 9, 0)),
        DateTime(2026, 10, 2, 9, 0),
      );
    });

    test('rounds UP, so "in 30 minutes" is never shorter than 30', () {
      // Rounding down is the bug: a rider offered 12 minutes and told "15" gets
      // stood on a corner for 12, which is the kind of small lie that makes the
      // whole feature untrustworthy.
      expect(
        SchedulePicker.quarterHourFrom(DateTime(2026, 10, 2, 9, 1)),
        DateTime(2026, 10, 2, 9, 15),
      );
      expect(
        SchedulePicker.quarterHourFrom(DateTime(2026, 10, 2, 9, 14)),
        DateTime(2026, 10, 2, 9, 15),
      );
    });

    test('drops seconds, so two picks a minute apart are the same time', () {
      expect(
        SchedulePicker.quarterHourFrom(DateTime(2026, 10, 2, 9, 15, 42)),
        DateTime(2026, 10, 2, 9, 15),
      );
    });

    test(
      'rolls into the next hour rather than staying on the last quarter',
      () {
        expect(
          SchedulePicker.quarterHourFrom(DateTime(2026, 10, 2, 9, 52)),
          DateTime(2026, 10, 2, 10, 0),
        );
      },
    );
  });

  group('formatScheduledMoment', () {
    // Pinned to a day, because "today" is a moving word and a test that runs at
    // midnight must not become a test about tomorrow.
    final now = DateTime.now();

    test('names today and tomorrow rather than dating them', () {
      final todayAt = DateTime(now.year, now.month, now.day, 18, 30);
      expect(formatScheduledMoment(todayAt), 'today, 18:30');
      // Same wall-clock moment the next day, which is what a rider means by
      // "tomorrow at half six".
      expect(
        formatScheduledMoment(todayAt.add(const Duration(days: 1))),
        'tomorrow, 18:30',
      );
      expect(
        formatScheduledMoment(DateTime(now.year, now.month, now.day, 7, 30)),
        'today, 07:30',
      );
    });

    test('always prints a clock time, never a bare date', () {
      // "3 Oct" on a booking made on 2 Oct says nothing about *when*, and a
      // rider who has to work it out is the rider picked up at the wrong time.
      for (final d in <Duration>[
        Duration.zero,
        const Duration(days: 1),
        const Duration(days: 3),
        const Duration(days: 40),
      ]) {
        expect(
          formatScheduledMoment(now.add(d)),
          contains(RegExp(r'\d{2}:\d{2}')),
          reason: '${d.inDays} days out has no time on it',
        );
      }
    });

    test('a week out is dated, because "in 8 days" stops meaning anything', () {
      expect(
        formatScheduledMoment(now.add(const Duration(days: 40))),
        contains(RegExp(r'\d{1,2} [A-Z][a-z]{2}, \d{2}:\d{2}')),
      );
    });

    test('uses a 24-hour clock', () {
      // A rider reading "6:30" next to a Ghanaian phone in 12-hour mode has to
      // work out whether that is morning.
      expect(
        formatScheduledMoment(DateTime(now.year, now.month, now.day, 18, 30)),
        contains('18:30'),
      );
    });
  });

  group('RouteDraft', () {
    test('null means now, and asNow drops the schedule', () {
      const now = RouteDraft(
        pickup: pickup,
        dropoff: dropoff,
        category: RideCategory.standard,
      );
      expect(now.isScheduled, isFalse);
      expect(now.scheduledFor, isNull);

      final later = RouteDraft(
        pickup: pickup,
        dropoff: dropoff,
        category: RideCategory.standard,
        scheduledFor: DateTime(2026, 10, 3, 7, 30),
      );
      expect(later.isScheduled, isTrue);
      expect(later.asNow().scheduledFor, isNull);
      expect(
        later.asNow().dropoff,
        dropoff,
        reason: 'only the time is dropped',
      );
    });
  });

  group('RiderFlow', () {
    test('forwards the scheduled time to the repository', () async {
      // The failure this guards: a draft carrying a schedule that the flow
      // ignored would confirm a time the rider chose and book a car for now.
      final trips = _RecordingTrips();
      final flow = RiderFlow(trips: trips, functions: _StubFunctions());
      addTearDown(flow.dispose);

      final when = DateTime(2026, 10, 3, 7, 30);
      await flow.requestRide(
        RouteDraft(
          pickup: pickup,
          dropoff: dropoff,
          category: RideCategory.standard,
          scheduledFor: when,
        ),
      );
      expect(trips.seenScheduledFor, when);
    });

    test('sends null for an ordinary booking', () async {
      // Null and not "15 minutes from now": an immediate booking has to take the
      // path it always took.
      final trips = _RecordingTrips();
      final flow = RiderFlow(trips: trips, functions: _StubFunctions());
      addTearDown(flow.dispose);

      await flow.requestRide(
        const RouteDraft(
          pickup: pickup,
          dropoff: dropoff,
          category: RideCategory.standard,
        ),
      );
      expect(trips.seenScheduledFor, isNull);
    });
  });

  group('SchedulePicker', () {
    Future<void> pump(
      WidgetTester t, {
      required ValueChanged<DateTime?> onChanged,
      DateTime? value,
      DateTime? now,
    }) async {
      await t.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(390, 844),
          builder: (_, _) => MaterialApp(
            home: Scaffold(
              body: SchedulePicker(
                value: value,
                onChanged: onChanged,
                now: now,
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
    }

    testWidgets('offers Now, three offsets and a custom time', (t) async {
      await pump(t, onChanged: (_) {}, now: DateTime(2026, 10, 2, 9, 0));
      expect(find.byKey(const Key('scheduleChip-0')), findsOneWidget);
      expect(find.byKey(const Key('scheduleChip-30')), findsOneWidget);
      expect(find.byKey(const Key('scheduleChip-60')), findsOneWidget);
      expect(find.byKey(const Key('scheduleChip-240')), findsOneWidget);
      expect(find.byKey(const Key('scheduleCustom')), findsOneWidget);
    });

    testWidgets('starts on Now, meaning no schedule', (t) async {
      await pump(t, onChanged: (_) {}, now: DateTime(2026, 10, 2, 9, 0));
      final chip = t.widget<ChoiceChip>(
        find.byKey(const Key('scheduleChip-0')),
      );
      expect(chip.selected, isTrue, reason: 'immediate is the default');
      // And no "book now" escape hatch, because there is nothing to escape.
      expect(find.byKey(const Key('scheduleClear')), findsNothing);
    });

    testWidgets('tapping an offset reports a snapped time', (t) async {
      DateTime? got;
      await pump(
        t,
        onChanged: (v) => got = v,
        now: DateTime(2026, 10, 2, 9, 7),
      );
      await t.tap(find.byKey(const Key('scheduleChip-30')));
      // 09:07 + 30 = 09:37, ceiled to 09:45. Never 09:30, which is 23 minutes.
      expect(got, DateTime(2026, 10, 2, 9, 45));
    });

    testWidgets('tapping Now again reports null, not a moment', (t) async {
      DateTime? got;
      var called = false;
      await pump(
        t,
        onChanged: (v) {
          got = v;
          called = true;
        },
        value: DateTime(2026, 10, 2, 15, 0),
        now: DateTime(2026, 10, 2, 9, 0),
      );

      expect(find.byKey(const Key('scheduleClear')), findsOneWidget);
      await t.tap(find.byKey(const Key('scheduleClear')));
      expect(called, isTrue);
      expect(got, isNull, reason: 'null is "now", not the current value again');
    });

    testWidgets('the chip matching the value is the one lit', (t) async {
      // Otherwise a rider who picked 09:45 from the custom picker sees no chip
      // selected and cannot tell whether anything was chosen.
      //
      // "In 30 min" from 09:15 is 09:45 once snapped, so 09:45 is that chip and
      // the comparison has to be on the snapped moment. Comparing on the raw
      // offset is the same bug as comparing on a formatted string.
      await pump(
        t,
        onChanged: (_) {},
        value: DateTime(2026, 10, 2, 9, 45),
        now: DateTime(2026, 10, 2, 9, 15),
      );
      expect(
        t.widget<ChoiceChip>(find.byKey(const Key('scheduleChip-30'))).selected,
        isTrue,
      );
      expect(
        t.widget<ChoiceChip>(find.byKey(const Key('scheduleChip-0'))).selected,
        isFalse,
      );
    });

    testWidgets('a time that is not a suggestion lights nothing', (t) async {
      // And that is correct: "In 30 min" from 09:00 is 09:30, so 09:45 is not
      // it. Claiming it is would light a chip that does not mean what it says.
      await pump(
        t,
        onChanged: (_) {},
        value: DateTime(2026, 10, 2, 9, 45),
        now: DateTime(2026, 10, 2, 9, 0),
      );
      for (final chip in ['0', '30', '60', '240']) {
        expect(
          t.widget<ChoiceChip>(find.byKey(Key('scheduleChip-$chip'))).selected,
          isFalse,
          reason: 'chip $chip does not mean 09:45 from 09:00',
        );
      }
    });
  });
}
