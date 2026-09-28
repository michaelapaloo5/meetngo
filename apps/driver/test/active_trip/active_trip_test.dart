import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';
import 'package:meetngo_driver/src/active_trip/active_trip_controller.dart';
import 'package:meetngo_driver/src/active_trip/active_trip_screen.dart';
import 'package:meetngo_driver/src/data/driver_repository.dart';
import 'package:meetngo_driver/src/location/location_controller.dart';
import 'package:provider/provider.dart';

import '../support/fakes.dart';
import '../support/harness.dart';

/// The screen now draws the trip on a map, so it needs a
/// [LocationController]. A stub reader with no fix is the case that matters
/// here: the trip's own stops have to render whether or not the driver has a
/// position, and a test that supplied a fix would never prove that.
Widget wrap(
  ActiveTripController c, {
  VoidCallback? onFinished,
  LocationController? location,
}) =>
    appHarness(
      ChangeNotifierProvider<ActiveTripController>.value(
        value: c,
        child: ActiveTripScreen(
          onFinished: onFinished ?? () {},
          location: location ??
              LocationController(
                StubLocationReader(pointThrows: 'no fix'),
                StubDriverRepository(),
              ),
        ),
      ),
    );

void main() {
  late StubDriverRepository repo;

  setUp(() => repo = StubDriverRepository());

  test('each state exposes the next legal action', () {
    const expectations = {
      TripState.matched: 'Start navigation',
      TripState.arriving: 'Arrived at pickup',
      TripState.ongoing: 'Complete the trip',
      TripState.completed: 'Trip finished',
    };
    for (final entry in expectations.entries) {
      final c = ActiveTripController(repo)..trip = tripIn(entry.key);
      expect(c.primaryActionLabel, entry.value, reason: entry.key.name);
    }
  });

  test('no trip and a terminal trip both say there is nothing to do', () {
    expect(ActiveTripController(repo).primaryActionLabel, 'No action');
    expect(ActiveTripController(repo).headline, 'No active trip');
    final cancelled = ActiveTripController(repo)..trip = tripIn(TripState.cancelled);
    expect(cancelled.primaryActionLabel, 'No action');
    expect(cancelled.canAdvance, isFalse);
  });

  test('the headline names the phase the driver is in', () {
    const headlines = {
      TripState.matched: 'New trip assigned',
      TripState.arriving: 'Collect your rider',
      TripState.ongoing: 'On the way',
      TripState.completed: 'Trip finished',
    };
    for (final entry in headlines.entries) {
      final c = ActiveTripController(repo)..trip = tripIn(entry.key);
      expect(c.headline, entry.value, reason: entry.key.name);
    }
  });

  test('matched advances to arriving', () async {
    final c = ActiveTripController(repo)..trip = tripIn(TripState.matched);
    expect(await c.advance(), isTrue);
    expect(repo.moves, ['t1->arriving']);
    expect(c.trip!.state, TripState.arriving);
  });

  // The OTP is the only thing standing between a driver and a trip they have
  // not reached the rider for, so `arriving` has no other way out.
  test('arriving cannot be advanced without the pickup OTP', () async {
    final c = ActiveTripController(repo)..trip = tripIn(TripState.arriving);
    expect(await c.advance(), isFalse);
    expect(repo.moves, isEmpty);
    expect(c.error, contains('pickup code'));
  });

  test('a correct pickup OTP advances arriving to ongoing', () async {
    final c = ActiveTripController(repo)..trip = tripIn(TripState.arriving);
    expect(await c.submitPickupOtp('4821'), isTrue);
    expect(repo.otpAttempts, 1);
    expect(repo.moves, ['t1->ongoing']);
    expect(c.trip!.state, TripState.ongoing);
  });

  test('the OTP is trimmed before it is checked', () async {
    final c = ActiveTripController(repo)..trip = tripIn(TripState.arriving);
    expect(await c.submitPickupOtp(' 4821 '), isTrue);
  });

  test('a wrong pickup OTP surfaces an error and holds the state', () async {
    repo.otpPasses = false;
    final c = ActiveTripController(repo)..trip = tripIn(TripState.arriving);
    expect(await c.submitPickupOtp('0000'), isFalse);
    expect(c.trip!.state, TripState.arriving);
    expect(c.error, 'That code is not right');
    expect(repo.moves, isEmpty, reason: 'a refused code must not start the trip');
  });

  test('a short OTP is rejected before the network call', () async {
    final c = ActiveTripController(repo)..trip = tripIn(TripState.arriving);
    expect(await c.submitPickupOtp('12'), isFalse);
    expect(repo.otpAttempts, 0);
    expect(c.error, contains('4 digits'));
  });

  test('an OTP is only accepted in the arriving state', () async {
    for (final state in [
      TripState.matched,
      TripState.ongoing,
      TripState.completed,
      TripState.cancelled,
    ]) {
      final c = ActiveTripController(repo)..trip = tripIn(state);
      expect(await c.submitPickupOtp('4821'), isFalse, reason: state.name);
      expect(repo.otpAttempts, 0, reason: state.name);
    }
  });

  test('ongoing advances to completed and then stops', () async {
    final c = ActiveTripController(repo)..trip = tripIn(TripState.ongoing);
    expect(await c.advance(), isTrue);
    expect(c.trip!.state, TripState.completed);
    expect(c.canAdvance, isFalse);
    expect(await c.advance(), isFalse);
    expect(repo.moves, ['t1->completed']);
  });

  test('a completed trip is finished, which canAdvance cannot express', () {
    final c = ActiveTripController(repo)..trip = tripIn(TripState.completed);
    expect(c.canAdvance, isFalse);
    expect(c.isFinished, isTrue);
  });

  // `enforce_trip_transition` refuses an illegal move at the database, so this
  // is the transition rule answering, not a network fault, and it has to reach
  // the driver rather than being swallowed.
  test('a rejected transition is surfaced and the state is not believed',
      () async {
    final rejecting = _RejectingTripRepository();
    final c = ActiveTripController(rejecting)..trip = tripIn(TripState.matched);
    expect(await c.advance(), isFalse);
    expect(c.error, isNotNull);
    expect(c.trip!.state, TripState.matched, reason: 'the row never moved');
  });

  test('nothing to advance is said plainly', () async {
    final c = ActiveTripController(repo);
    expect(await c.advance(), isFalse);
    expect(c.error, 'Nothing to advance');
  });

  testWidgets('the screen shows the state, both stops, and the action',
      (tester) async {
    useDesignSurface(tester);
    final c = ActiveTripController(repo)..trip = tripIn(TripState.arriving);
    await tester.pumpWidget(wrap(c));

    expect(find.byKey(const Key('tripStateChip')), findsOneWidget);
    expect(find.text('arriving'), findsOneWidget);
    expect(find.text('Osu Junction'), findsOneWidget);
    expect(find.text('Oxford Street, Osu, Accra'), findsOneWidget);
    expect(find.text('Airport Residential'), findsOneWidget);
    expect(find.text('Airport Residential, Accra'), findsOneWidget);
    expect(find.text('Arrived at pickup'), findsOneWidget);
    expect(find.text('GHS 12.50'), findsOneWidget);
    expect(find.byKey(const Key('navigateButton')), findsOneWidget);
    expect(find.byKey(const Key('callRiderButton')), findsOneWidget);
  });

  testWidgets('a screen with no trip says so, once', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap(ActiveTripController(repo)));
    expect(find.text('No active trip'), findsOneWidget, reason: 'the app bar');
    expect(
      find.text('There is no trip on this account to show.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('primaryActionButton')), findsNothing);
  });

  // The plan's `_headlines` map is the step's title in the app bar, and the plan
  // also put the same string in the body of its `approved` step, so
  // `find.text('You are verified')` with `findsOneWidget` was unsatisfiable
  // against the plan's own screen. Pinned here so the same duplication cannot
  // come back: apart from the action button -- whose label is a different piece
  // of information, and legitimately repeats the headline for `completed` -- no
  // other text on the screen may equal the app bar's headline.
  testWidgets('no text outside the action button repeats the headline',
      (tester) async {
    useDesignSurface(tester);
    for (final state in [
      TripState.matched,
      TripState.arriving,
      TripState.ongoing,
      TripState.completed,
    ]) {
      final c = ActiveTripController(repo)..trip = tripIn(state);
      await tester.pumpWidget(wrap(c));
      final outsideButton = find.byType(Text).evaluate().where((element) {
        final inButton = find
            .descendant(
              of: find.byKey(const Key('primaryActionButton')),
              matching: find.byType(Text),
            )
            .evaluate();
        return !inButton.any((b) => identical(b, element));
      });
      final repeats = outsideButton
          .map((e) => (e.widget as Text).data ?? '')
          .where((s) => s == c.headline)
          .length;
      expect(
        repeats,
        1,
        reason: '${state.name}: "${c.headline}" is repeated outside the button',
      );
    }
  });

  // The plan derived the button's enabled state from `canAdvance`, which is
  // false at `completed`, so the one button that ends a trip could never be
  // pressed -- and it then compared the state off a `trip` local captured before
  // the await, so `onFinished` was unreachable even if it could. Two independent
  // dead ends, and no plan test touched either.
  testWidgets('a finished trip can be handed back', (tester) async {
    useDesignSurface(tester);
    var finished = 0;
    final c = ActiveTripController(repo)..trip = tripIn(TripState.ongoing);
    await tester.pumpWidget(wrap(c, onFinished: () => finished++));

    await tester.tap(find.byKey(const Key('primaryActionButton')));
    await tester.pumpAndSettle();

    expect(repo.moves, ['t1->completed']);
    expect(finished, 1, reason: 'the trip has to be able to end');
  });

  testWidgets('the button on a completed trip is still live', (tester) async {
    useDesignSurface(tester);
    final c = ActiveTripController(repo)..trip = tripIn(TripState.completed);
    await tester.pumpWidget(wrap(c));
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('primaryActionButton')),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('the primary action is dead when there is nothing to advance',
      (tester) async {
    useDesignSurface(tester);
    final c = ActiveTripController(repo)..trip = tripIn(TripState.cancelled);
    await tester.pumpWidget(wrap(c));
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('primaryActionButton')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('arriving opens the pickup OTP sheet', (tester) async {
    useDesignSurface(tester);
    final c = ActiveTripController(repo)..trip = tripIn(TripState.arriving);
    await tester.pumpWidget(wrap(c));

    await tester.tap(find.byKey(const Key('primaryActionButton')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pickupOtpField')), findsOneWidget);
    expect(find.byKey(const Key('pickupOtpConfirmButton')), findsOneWidget);
  });

  testWidgets('the OTP sheet only takes digits and four of them',
      (tester) async {
    useDesignSurface(tester);
    final c = ActiveTripController(repo)..trip = tripIn(TripState.arriving);
    await tester.pumpWidget(wrap(c));
    await tester.tap(find.byKey(const Key('primaryActionButton')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('pickupOtpField')), 'ab12cd3456');
    final field = tester.widget<TextField>(find.byKey(const Key('pickupOtpField')));
    expect(field.controller!.text.length, lessThanOrEqualTo(4));
    expect(field.controller!.text, matches(RegExp(r'^\d*$')));
  });

  testWidgets('a correct OTP closes the sheet and starts the trip',
      (tester) async {
    useDesignSurface(tester);
    final c = ActiveTripController(repo)..trip = tripIn(TripState.arriving);
    await tester.pumpWidget(wrap(c));
    await tester.tap(find.byKey(const Key('primaryActionButton')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('pickupOtpField')), '4821');
    await tester.tap(find.byKey(const Key('pickupOtpConfirmButton')));
    await tester.pumpAndSettle();

    expect(repo.moves, ['t1->ongoing']);
    expect(find.byKey(const Key('pickupOtpField')), findsNothing);
    expect(find.text('On the way'), findsOneWidget);
  });

  testWidgets('a wrong OTP keeps the sheet open with the reason', (tester) async {
    useDesignSurface(tester);
    repo.otpPasses = false;
    final c = ActiveTripController(repo)..trip = tripIn(TripState.arriving);
    await tester.pumpWidget(wrap(c));
    await tester.tap(find.byKey(const Key('primaryActionButton')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('pickupOtpField')), '0000');
    await tester.tap(find.byKey(const Key('pickupOtpConfirmButton')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pickupOtpField')), findsOneWidget);
    expect(find.byKey(const Key('pickupOtpError')), findsOneWidget);
    // On the sheet and on the screen behind it, which is where it also has to
    // survive the sheet being dismissed.
    expect(find.text('That code is not right'), findsNWidgets(2));
    expect(find.byKey(const Key('activeTripError')), findsOneWidget);
  });

  testWidgets('a refused transition is shown on the screen', (tester) async {
    useDesignSurface(tester);
    final c = ActiveTripController(_RejectingTripRepository())
      ..trip = tripIn(TripState.matched);
    await tester.pumpWidget(wrap(c));

    await tester.tap(find.byKey(const Key('primaryActionButton')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('activeTripError')), findsOneWidget);
    expect(find.text('Start navigation'), findsOneWidget);
  });

  // `google_maps_flutter` and `url_launcher` are not dependencies of this app.
  // The plan's `onPressed: () {}` was a live-looking control that did nothing;
  // what is here says what is missing.
  testWidgets('the two buttons say what is missing rather than doing nothing',
      (tester) async {
    useDesignSurface(tester);
    final c = ActiveTripController(repo)..trip = tripIn(TripState.matched);
    await tester.pumpWidget(wrap(c));

    await tester.tap(find.byKey(const Key('navigateButton')));
    await tester.pumpAndSettle();
    expect(find.textContaining('not part of this build'), findsOneWidget);

    // Let the SnackBar finish before the second tap. Both buttons share one
    // row low on a 390x844 screen, and the SnackBar is laid out over the
    // bottom of the Scaffold, so while the first message is up it is the thing
    // under the `Call` button: the tap resolved to an offset inside the
    // SnackBar and Flutter warned that the hit test missed. The second
    // message then never appeared and the test failed on an assertion about
    // the second button rather than about the overlay.
    //
    // `pumpAndSettle` is not enough on its own -- it settles the entrance
    // animation but not the dismiss timer, which is a timer rather than a
    // frame -- so the duration is advanced explicitly past the default 4s.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(
      find.byType(SnackBar),
      findsNothing,
      reason: 'the first message must be gone before the second button is tapped',
    );

    await tester.tap(find.byKey(const Key('callRiderButton')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Calling from the app'), findsOneWidget);
  });
}

class _RejectingTripRepository extends StubDriverRepository {
  @override
  Future<void> advanceTripState(String tripId, TripState to) async {
    throw const DriverAuthFailure(
      'This trip moved from matched to completed without you',
    );
  }
}
