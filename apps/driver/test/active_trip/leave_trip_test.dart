import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';
import 'package:meetngo_driver/src/active_trip/leave_trip_controller.dart';
import 'package:meetngo_driver/src/active_trip/leave_trip_sheet.dart';
import 'package:meetngo_driver/src/active_trip/return_trip_banner.dart';

import '../support/harness.dart';

/// Leaving a trip, and being told on return that you still have one.
///
/// Two rules here are safety rules rather than preferences, and both are asserted
/// more than once because both are the kind of thing a later change breaks
/// silently:
///
/// - a driver may withdraw while `arriving` and may not while `ongoing`, because
///   `ongoing` means somebody is in the vehicle;
/// - the server refuses the same thing, so a client that lost the check does not
///   become a way to strand a passenger. That half is `verify-leave-trip.mjs`.

/// A repository the test drives. Top level: Dart will not declare a class inside a
/// function.
class FakeLeave implements LeaveTripRepository {
  Object? error;
  final List<({String tripId, String reason})> calls = [];

  @override
  Future<void> leave({required String tripId, required String reason}) async {
    calls.add((tripId: tripId, reason: reason));
    final e = error;
    if (e != null) throw e;
  }
}

void main() {
  LeaveTripController controller({FakeLeave? repo}) =>
      LeaveTripController(tripId: 't1')..repository = repo ?? FakeLeave();

  group('when a trip may be left', () {
    test('arriving, because the rider is not in the car yet', () {
      expect(LeaveTripController.canLeave(TripState.arriving), isTrue);
      expect(LeaveTripController.refusalFor(TripState.arriving), isNull);
    });

    test('not ongoing, and it says why', () {
      // The one that matters. A rider is in the vehicle; "leaving" is stranding
      // them, and the driver is owed the reason rather than a disabled button.
      expect(LeaveTripController.canLeave(TripState.ongoing), isFalse);
      expect(LeaveTripController.refusalFor(TripState.ongoing), contains('in the car'));
    });

    test('not before the trip is theirs', () {
      // `requested`/`matched` is where `offers/decline` applies, not this.
      expect(LeaveTripController.canLeave(TripState.matched), isFalse);
      expect(LeaveTripController.refusalFor(TripState.matched), contains('Decline the offer'));
    });

    test('not after it finished', () {
      for (final state in [TripState.completed, TripState.cancelled]) {
        expect(LeaveTripController.canLeave(state), isFalse, reason: '$state');
      }
    });
  });

  group('the reason', () {
    test('stores a slug, not the prompt, so a queue stays filterable', () {
      // The prompt is copy that will be reworded; a queue somebody filters on must
      // not break when it is.
      expect(LeaveReason.riderNotAtPickup.slug, 'rider_absent');
      for (final reason in LeaveReason.values) {
        expect(reason.slug, isNot(contains(' ')), reason: reason.name);
      }
    });

    test('every slug is distinct, so filtering by one means something', () {
      final slugs = LeaveReason.values.map((r) => r.slug).toSet();
      expect(slugs.length, LeaveReason.values.length);
    });

    test('every prompt is a sentence a driver would recognise', () {
      for (final reason in LeaveReason.values) {
        expect(reason.prompt, contains(' '), reason: reason.name);
      }
    });

    test('the detail is kept, capped to fit beside the slug', () {
      // The driver's own words are what will help whoever reads the queue; a
      // column of six identical slugs helps nobody.
      final repo = FakeLeave();
      final c = LeaveTripController(tripId: 't1')..repository = repo;
      c.leave(LeaveReason.other, detail: 'The gate is locked, no answer');
      expect(repo.calls.single.reason, contains('The gate is locked, no answer'));
      expect(repo.calls.single.reason, startsWith('other'), reason: 'the slug leads, so it is greppable');
    });

    test('a very long detail is truncated rather than refused', () {
      final repo = FakeLeave();
      final c = LeaveTripController(tripId: 't1')..repository = repo;
      c.leave(LeaveReason.other, detail: 'x' * 900);
      // The column allows 300 and the slug has to fit inside it.
      expect(repo.calls.single.reason.length, lessThanOrEqualTo(300));
    });
  });

  group('leaving', () {
    test('sends the trip id and the reason', () async {
      final repo = FakeLeave();
      final c = LeaveTripController(tripId: 'trip-9')..repository = repo;
      expect(await c.leave(LeaveReason.riderNotAtPickup), isTrue);
      expect(repo.calls.single.tripId, 'trip-9');
    });

    test('a refusal is the server own sentence, verbatim', () async {
      // The 409 case is where the server knows the trip changed under us and this
      // does not. Rewording it here would only lose the explanation.
      final repo = FakeLeave()
        ..error = const LeaveTripFailure(
          'this trip changed while you were leaving it',
        );
      final c = LeaveTripController(tripId: 't1')..repository = repo;
      expect(await c.leave(LeaveReason.other), isFalse);
      expect(c.problem, 'this trip changed while you were leaving it');
    });

    test('no repository is a fault, not a silent success', () async {
      final c = LeaveTripController(tripId: 't1');
      // The shell treats a true as "the driver is free", so a silent true here
      // would put them on the home screen still holding a live trip.
      expect(await c.leave(LeaveReason.other), isFalse);
      expect(c.problem, isNotNull);
    });

    test('clears a previous failure on the next attempt', () async {
      final repo = FakeLeave()..error = const LeaveTripFailure('no');
      final c = LeaveTripController(tripId: 't1')..repository = repo;
      await c.leave(LeaveReason.other);
      expect(c.problem, isNotNull);
      repo.error = null;
      await c.leave(LeaveReason.other);
      expect(c.problem, isNull);
    });
  });

  group('the return banner', () {
    Trip held({
      TripState state = TripState.arriving,
      String pickup = 'Osu Junction',
      String dropoff = 'Airport Residential',
    }) => tripIn(state, pickupLabel: pickup, dropoffLabel: dropoff);

    Widget wrap(Trip t, {String? riderName, VoidCallback? onOpen}) => appHarness(
      Scaffold(
        body: ReturnTripBanner(
          trip: t,
          riderName: riderName,
          onOpen: onOpen ?? () {},
        ),
      ),
    );

    testWidgets('says there is a trip, and which one', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(held()));
      expect(find.byKey(const Key('returnTripBanner')), findsOneWidget);
      expect(find.text('You still have a trip'), findsOneWidget);
      // The pickup, not a trip id. A driver who has just reopened the app knows
      // nothing about uuids.
      expect(find.textContaining('Osu Junction'), findsOneWidget);
    });

    testWidgets('says the rider is in the car when one is', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(held(state: TripState.ongoing)));
      // Different news, and the difference is the whole point of the banner rather
      // than its styling: being driven somewhere is not the same as going to
      // collect somebody.
      expect(find.text('Your rider is in the car'), findsOneWidget);
      expect(find.textContaining('Airport Residential'), findsOneWidget);
    });

    testWidgets('names the rider when it knows one', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(held(state: TripState.ongoing), riderName: 'Ama'));
      expect(find.textContaining('Ama'), findsOneWidget);
    });

    testWidgets('falls back to "your rider" rather than showing a blank', (
      tester,
    ) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(held(state: TripState.ongoing)));
      // `Trip` carries only a `rider_id`, and the driver app cannot read another
      // user's profile -- so the lookup may not have landed and a blank would look
      // like a bug.
      expect(find.textContaining('your rider'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });

    testWidgets('opens the trip', (tester) async {
      var opened = 0;
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(held(), onOpen: () => opened++));
      await tester.tap(find.byKey(const Key('returnTripOpenButton')));
      expect(opened, 1);
    });

    testWidgets('the two states have different button labels', (tester) async {
      // "View trip" and "Continue" say different things, and a driver who has just
      // reopened the app with a passenger aboard should not be asked to "view"
      // something they are already in.
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(held()));
      expect(find.text('View trip'), findsOneWidget);
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(held(state: TripState.ongoing)));
      expect(find.text('Continue'), findsOneWidget);
    });
  });

  group('the leave sheet', () {
    Future<bool?> open(WidgetTester tester, LeaveTripController c) async {
      bool? result;
      await tester.pumpWidget(
        appHarness(
          Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await LeaveTripSheet.show(context, c);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      return result;
    }

    testWidgets('offers a short list of reasons', (tester) async {
      useDesignSurface(tester);
      await open(tester, controller());
      for (final reason in LeaveReason.values) {
        expect(
          find.byKey(Key('leaveReason_${reason.slug}')),
          findsOneWidget,
          reason: reason.slug,
        );
      }
    });

    testWidgets('says what will happen to the rider, before it happens', (
      tester,
    ) async {
      useDesignSurface(tester);
      await open(tester, controller());
      // A driver who does not know the rider goes back into the pool is being asked
      // to decide twice.
      expect(find.textContaining('another driver'), findsOneWidget);
    });

    testWidgets('will not leave until a reason is chosen', (tester) async {
      useDesignSurface(tester);
      final repo = FakeLeave();
      await open(tester, controller(repo: repo));

      expect(
        tester.widget<FilledButton>(find.byKey(const Key('leaveConfirmButton'))).onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('leaveReason_rider_absent')));
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('leaveConfirmButton'))).onPressed,
        isNotNull,
      );
      expect(repo.calls, isEmpty);
    });

    testWidgets('leaving closes the sheet and reports that it happened', (
      tester,
    ) async {
      useDesignSurface(tester);
      final repo = FakeLeave();
      final result = await open(tester, controller(repo: repo));
      // `open` captured null because the sheet is still up; the send happens here.
      expect(result, isNull);

      await tester.tap(find.byKey(const Key('leaveReason_rider_absent')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('leaveConfirmButton')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(repo.calls, hasLength(1));
      expect(find.byKey(const Key('leaveConfirmButton')), findsNothing);
    });

    testWidgets('a refusal keeps the sheet open with the reason', (tester) async {
      useDesignSurface(tester);
      final repo = FakeLeave()..error = const LeaveTripFailure('The rider is in the car.');
      await open(tester, controller(repo: repo));

      await tester.tap(find.byKey(const Key('leaveReason_rider_absent')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('leaveConfirmButton')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byKey(const Key('leaveProblem')), findsOneWidget);
      expect(find.byKey(const Key('leaveConfirmButton')), findsOneWidget);
    });

    testWidgets('"keep driving" is the way out, and it is there', (tester) async {
      useDesignSurface(tester);
      await open(tester, controller());
      // Not a back arrow. A sheet opened by accident over a live trip needs a
      // button whose label says what pressing it does.
      expect(find.byKey(const Key('leaveCancelButton')), findsOneWidget);
      expect(find.text('Keep driving'), findsOneWidget);
    });

    testWidgets('"other" is not a dead end -- it offers a box', (tester) async {
      useDesignSurface(tester);
      final repo = FakeLeave();
      await open(tester, controller(repo: repo));

      expect(find.byKey(const Key('leaveDetailField')), findsNothing);
      await tester.tap(find.byKey(const Key('leaveReason_other')));
      await tester.pump();
      // The failure mode of a fixed list is a driver with a genuinely unusual
      // problem picking the nearest wrong answer.
      expect(find.byKey(const Key('leaveDetailField')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('leaveDetailField')),
        'The gate is locked and nobody answered',
      );
      await tester.tap(find.byKey(const Key('leaveConfirmButton')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(repo.calls.single.reason, contains('The gate is locked'));
    });
  });
}