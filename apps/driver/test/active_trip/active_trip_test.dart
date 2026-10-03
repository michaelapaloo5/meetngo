import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';
import 'package:meetngo_driver/src/active_trip/active_trip_controller.dart';
import 'package:meetngo_driver/src/active_trip/active_trip_screen.dart';
import 'package:meetngo_driver/src/contact/contact_controller.dart';
import 'package:meetngo_driver/src/data/driver_repository.dart';
import 'package:meetngo_driver/src/location/location_controller.dart';
import 'package:meetngo_driver/src/navigation/navigation_controller.dart';
import 'package:meetngo_driver/src/navigation/navigation_host.dart';
import 'package:meetngo_driver/src/navigation/turn_banner.dart';
import 'package:provider/provider.dart';

import '../support/fakes.dart';
import '../support/harness.dart';

/// A route repository that answers immediately with a straight two-point line.
///
/// `NavigationHost.start` returns early when it has no repository, so a host built
/// bare never becomes "running" -- and a test asserting the banner appears would
/// then pass or fail for the wrong reason.
class _StubRoute implements RouteRepository {
  @override
  Future<TripRoute> route(GeoPoint from, GeoPoint to) async => TripRoute(
        distanceM: 2000,
        durationS: 600,
        durationFreeFlowS: 600,
        // GeoJSON order, `[lng, lat]`, not a pair of GeoPoints.
        geometry: [
          [from.lng, from.lat],
          [to.lng, to.lat],
        ],
        steps: const [],
        engine: 'osrm',
        degraded: false,
      );
}

/// The screen now draws the trip on a map, so it needs a
/// [LocationController]. A stub reader with no fix is the case that matters
/// here: the trip's own stops have to render whether or not the driver has a
/// position, and a test that supplied a fix would never prove that.
///
/// The contact controller is the same idea: a stub repository with **no** number
/// is the default, because the case that matters for every other assertion in
/// this file is a trip whose rider has no number on file, and a test that
/// supplied one would stop exercising the disabled-button path. The contact tests
/// pass a real one.
Widget wrap(
  ActiveTripController c, {
  VoidCallback? onFinished,
  LocationController? location,
  ContactRepository? contacts,
  Contact? contact,

  /// Whether to hand the screen a `NavigationHost`.
  ///
  /// True by default, because that is what `driver_shell.dart` does and a harness
  /// that is not the app is not a stricter test. False is the state of a build
  /// without a routing repository, and the screen has to survive it.
  bool withNavigationHost = true,

  /// Whether the screen's location controller has a fix.
  ///
  /// False by default, because most tests here are about the trip and not about
  /// the map, and the screen routes from `location.point`.
  bool withLocation = false,

  /// A specific navigation host, for a test that starts navigation itself and
  /// then needs to see the screen react.
  ///
  /// Taking the host as an argument rather than always building a fresh one is what
  /// makes "the banner appears when navigation starts" testable: the test holds
  /// the same object the screen does, so it can start it the way the controller
  /// does -- from outside the widget tree, with no rebuild in between.
  NavigationHost? navigationHost,
}) {
  // One source of truth, not two. `wrap` took both a repository and a contact,
  // and the controller was built from the repository and then had `contact`
  // adopted over the top of it -- so a test that passed a repository *and* left
  // `contact` null had its answer overwritten with null by `adopt`, and the
  // button stayed disabled with no obvious reason. Only `contact` now seeds it,
  // and `contacts` is a separate escape hatch for a test that wants the lookup
  // path rather than the value.
  final controller = contacts != null
      ? ContactController(contacts)
      : ContactController(_NoNumber());
  if (contacts == null) controller.adopt(contact);
  return appHarness(
    ChangeNotifierProvider<ActiveTripController>.value(
      value: c,
      child: ActiveTripScreen(
        onFinished: onFinished ?? () {},
        location:
            location ??
            LocationController(
              withLocation
                  ? StubLocationReader(point: const GeoPoint(5.6037, -0.1870))
                  : StubLocationReader(pointThrows: 'no fix'),
              StubDriverRepository(),
            ),
        contact: controller,
        navigationHost:
            navigationHost ?? (withNavigationHost ? NavigationHost() : null),
      ),
    ),
  );
}

/// A repository that finds nobody. The default for every test here.
///
/// Every test in this file seeds the contact with `adopt` rather than through a
/// repository, because the question these tests answer is what the screen does
/// with a number, not how the number is fetched -- and the fetching has its own
/// suite in `test/contact/`.
class _NoNumber implements ContactRepository {
  @override
  Future<Contact?> contactFor(String tripId) async => null;
}

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
    final cancelled = ActiveTripController(repo)
      ..trip = tripIn(TripState.cancelled);
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
    expect(
      repo.moves,
      isEmpty,
      reason: 'a refused code must not start the trip',
    );
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
  test(
    'a rejected transition is surfaced and the state is not believed',
    () async {
      final rejecting = _RejectingTripRepository();
      final c = ActiveTripController(rejecting)
        ..trip = tripIn(TripState.matched);
      expect(await c.advance(), isFalse);
      expect(c.error, isNotNull);
      expect(c.trip!.state, TripState.matched, reason: 'the row never moved');
    },
  );

  test('nothing to advance is said plainly', () async {
    final c = ActiveTripController(repo);
    expect(await c.advance(), isFalse);
    expect(c.error, 'Nothing to advance');
  });

  testWidgets('the screen shows the state, both stops, and the action', (
    tester,
  ) async {
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
  testWidgets('no text outside the action button repeats the headline', (
    tester,
  ) async {
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

  testWidgets('the primary action is dead when there is nothing to advance', (
    tester,
  ) async {
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

  testWidgets('the OTP sheet only takes digits and four of them', (
    tester,
  ) async {
    useDesignSurface(tester);
    final c = ActiveTripController(repo)..trip = tripIn(TripState.arriving);
    await tester.pumpWidget(wrap(c));
    await tester.tap(find.byKey(const Key('primaryActionButton')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('pickupOtpField')),
      'ab12cd3456',
    );
    final field = tester.widget<TextField>(
      find.byKey(const Key('pickupOtpField')),
    );
    expect(field.controller!.text.length, lessThanOrEqualTo(4));
    expect(field.controller!.text, matches(RegExp(r'^\d*$')));
  });

  testWidgets('a correct OTP closes the sheet and starts the trip', (
    tester,
  ) async {
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

  testWidgets('a wrong OTP keeps the sheet open with the reason', (
    tester,
  ) async {
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

  // `google_maps_flutter` is not a dependency of this app. The plan's
  // `onPressed: () {}` was a live-looking control that did nothing, which is
  // worse than saying what is missing.
  //
  // This used to be one test covering both buttons, asserting that each said
  // "not part of this build". It is two now, because the two buttons no longer
  // share a fate. `url_launcher` is a dependency, the rider's number is fetched
  // and shown, and Call opens a sheet offering the dialler, the clipboard and a
  // full-screen read.
  //
  // Navigate navigates now. What is pinned here is the screen's contract with the
  // navigation host: with no location, or no host, the button says which of those
  // it is rather than doing nothing -- and never throws, because a crash here
  // would take down the screen a driver is running a live trip on.
  group('the Navigate button', () {
    testWidgets('says it needs a location rather than doing nothing', (
      tester,
    ) async {
      useDesignSurface(tester);
      final c = ActiveTripController(repo)..trip = tripIn(TripState.matched);
      await tester.pumpWidget(wrap(c));

      // `wrap` gives the screen a `LocationController` whose reader throws
      // 'no fix', so there is no point to route from.
      await tester.tap(find.byKey(const Key('navigateButton')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Waiting for your location'), findsOneWidget);
    });

    testWidgets('does not throw when no navigation host is wired in', (
      tester,
    ) async {
      useDesignSurface(tester);
      final c = ActiveTripController(repo)..trip = tripIn(TripState.matched);
      await tester.pumpWidget(wrap(c, withNavigationHost: false));
      await tester.tap(find.byKey(const Key('navigateButton')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'the banner appears when navigation starts, without the screen rebuilding',
      (tester) async {
        // The bug, and the second time this screen read a value it did not
        // listen for. `isRunning` was evaluated in `build`, with the
        // `ListenableBuilder` *inside* the guard rather than around it, so
        // starting navigation notified a host nothing was listening to at the top
        // level. The guard kept saying "not running" from a stale read and the
        // banner was never built.
        //
        // On a handset this read as a dead button: press Navigate, nothing.
        // Open the "Something left behind" sheet, dismiss it, and Navigate works --
        // because popping a modal route rebuilds the route underneath.
        useDesignSurface(tester);
        final host = NavigationHost(repository: _StubRoute());
        final c = ActiveTripController(repo)..trip = tripIn(TripState.matched);
        await tester.pumpWidget(wrap(c, navigationHost: host));

        expect(
          find.byKey(const Key('turnBannerMute')),
          findsNothing,
          reason: 'navigation has not started',
        );

        // Start it from outside the widget tree, exactly as the controller does,
        // with no rebuild of the screen in between.
        await host.start(
          at: const GeoPoint(5.6037, -0.1870),
          destination: const GeoPoint(5.6200, -0.1870),
        );
        await tester.pump();

        expect(host.isRunning, isTrue, reason: 'the host really did start');
        expect(
          find.byType(TurnBanner),
          findsOneWidget,
          reason: 'and the screen must show that without being rebuilt',
        );
      },
    );
  });

  group('the Call button', () {
    testWidgets('is disabled when the rider has no number on file', (
      tester,
    ) async {
      useDesignSurface(tester);
      final c = ActiveTripController(repo)..trip = tripIn(TripState.matched);
      await tester.pumpWidget(wrap(c));
      // The default in `wrap` is a repository that finds nobody, which is the
      // state every driver is in until the rider has a number. Disabled rather
      // than absent: a driver needs to see that calling exists and be told it
      // cannot yet, not find a row with one button in it.
      final button = tester.widget<OutlinedButton>(
        find.byKey(const Key('callRiderButton')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('opens the contact sheet when there is a number', (
      tester,
    ) async {
      useDesignSurface(tester);
      final c = ActiveTripController(repo)..trip = tripIn(TripState.matched);
      await tester.pumpWidget(
        wrap(
          c,
          contact: Contact(
            role: ContactRole.rider,
            phone: '0241234567',
            callable: true,
            name: 'Michael Apaloo',
          ),
        ),
      );

      // The label names the rider, not just "Call": a driver about to dial a
      // stranger's number wants to see who.
      expect(find.text('Call Michael'), findsOneWidget);

      await tester.tap(find.byKey(const Key('callRiderButton')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('contactNumber')), findsOneWidget);
      expect(find.text('024 123 4567'), findsOneWidget);
    });

    testWidgets('wakes when the number arrives after the first frame', (
      tester,
    ) async {
      // The bug this catches: the button is built once, with no contact, and
      // stays disabled for the rest of the trip. A driver who presses it then
      // concludes calling is broken -- which is exactly what the button said
      // about itself before this feature existed.
      useDesignSurface(tester);
      final c = ActiveTripController(repo)..trip = tripIn(TripState.matched);
      final controller = ContactController(_NoNumber());
      await tester.pumpWidget(
        appHarness(
          ChangeNotifierProvider<ActiveTripController>.value(
            value: c,
            child: ActiveTripScreen(
              onFinished: () {},
              location: LocationController(
                StubLocationReader(pointThrows: 'no fix'),
                repo,
              ),
              contact: controller,
            ),
          ),
        ),
      );
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('callRiderButton')))
            .onPressed,
        isNull,
      );

      // The answer arrives after the first build, as it always will.
      controller.adopt(
        Contact(
          role: ContactRole.rider,
          phone: '0241234567',
          callable: true,
          name: 'Michael Apaloo',
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('callRiderButton')))
            .onPressed,
        isNotNull,
      );
      expect(find.text('Call Michael'), findsOneWidget);
    });
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
