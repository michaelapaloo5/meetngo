import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';
import 'package:meetngo_driver/src/location/location_controller.dart';
import 'package:meetngo_driver/src/offers/availability_controller.dart';
import 'package:meetngo_driver/src/offers/driver_home_screen.dart';
import 'package:meetngo_driver/src/offers/offer_queue_controller.dart';

import '../support/fakes.dart';
import '../support/harness.dart';

/// The home tab now carries the map, so it needs a [LocationController]. The
/// stub reader is asked for no fix: what these tests are about is the toggle,
/// and a location panel that quietly reported a fix would be a second thing
/// being asserted by accident.
Widget home(AvailabilityController availability, StubDriverRepository repo) =>
    DriverHomeScreen(
      availability: availability,
      offers: OfferQueueController(repo),
      profile: driverProfile(),
      location: LocationController(
        StubLocationReader(pointThrows: 'no fix'),
        repo,
      ),
    );

void main() {
  late StubDriverRepository repo;

  setUp(() => repo = StubDriverRepository());

  test('goes online when no trip is active', () async {
    final c = AvailabilityController(repo, online: false);
    final ok = await c.setOnline(true);
    expect(ok, isTrue);
    expect(repo.availability, DriverAvailability.online);
    expect(c.online, isTrue);
  });

  test('going offline with no trip is allowed', () async {
    final c = AvailabilityController(repo, online: true);
    expect(await c.setOnline(false), isTrue);
    expect(repo.availability, DriverAvailability.offline);
  });

  // The plan named this one. It is the refusal that stops a driver leaving the
  // queue mid-ride, so it is the one test in the file that has to be right.
  //
  // The plan's version asserted two things that cannot both hold:
  // `repo.stored == DriverAvailability.online` with the reason "repository must
  // not be touched", and `repo.setAvailabilityCalls == 0`. `stored` starts at
  // `offline` and only `setAvailability` ever writes it, so on the branch under
  // test it is still `offline`. Extracted and run, it fails with
  // `Expected: DriverAvailability.online  Actual: DriverAvailability.offline`.
  // The call count is the assertion that carries the meaning; the toggle state
  // is read from the controller and not from the fake's copy of a value the
  // refused write never delivered.
  test('go_offline_refused_during_active_trip_test', () async {
    repo.active = tripIn(TripState.arriving);
    final c = AvailabilityController(repo, online: true);

    final ok = await c.setOnline(false);

    expect(ok, isFalse, reason: 'a driver with a live trip must not go offline');
    expect(
      repo.setAvailabilityCalls,
      0,
      reason: 'repository must not be touched',
    );
    expect(c.online, isTrue, reason: 'toggle springs back');
    expect(
      c.refusalReason,
      contains('Finish or cancel your current trip'),
    );
  });

  test('going online is never refused by a live trip', () async {
    repo.active = tripIn(TripState.ongoing);
    final c = AvailabilityController(repo, online: false);
    expect(await c.setOnline(true), isTrue);
    expect(c.refusalReason, isNull);
  });

  test('a completed trip does not block going offline', () async {
    repo.active = tripIn(TripState.completed);
    final c = AvailabilityController(repo, online: true);
    expect(await c.setOnline(false), isTrue);
    expect(repo.availability, DriverAvailability.offline);
  });

  test('a cancelled trip does not block going offline', () async {
    repo.active = tripIn(TripState.cancelled);
    final c = AvailabilityController(repo, online: true);
    expect(await c.setOnline(false), isTrue);
  });

  test('all four active states block going offline', () async {
    for (final state in [
      TripState.requested,
      TripState.matched,
      TripState.arriving,
      TripState.ongoing,
    ]) {
      repo.active = tripIn(state);
      final c = AvailabilityController(repo, online: true);
      expect(
        await c.setOnline(false),
        isFalse,
        reason: '$state must block going offline',
      );
      expect(repo.setAvailabilityCalls, 0, reason: state.name);
    }
  });

  test('a repository failure surfaces an error and keeps the old value',
      () async {
    repo.availabilityFails = true;
    final c = AvailabilityController(repo, online: false);
    expect(await c.setOnline(true), isFalse);
    expect(c.error, isNotNull);
    expect(c.online, isFalse);
  });

  test('a failed trip read refuses rather than going offline blind', () async {
    repo.activeTripFails = true;
    final c = AvailabilityController(repo, online: true);
    expect(await c.setOnline(false), isFalse);
    expect(c.error, contains('Could not check your current trip'));
    expect(repo.setAvailabilityCalls, 0);
    expect(c.online, isTrue);
  });

  // `match_offers_for_trip` requires a row in `driver_locations`, and nothing
  // else in this app ever writes one, so a driver who goes online without a
  // position is online and invisible at the same time.
  test('going online publishes a position so the matcher can see the driver',
      () async {
    final c = AvailabilityController(repo, online: false);
    expect(await c.setOnline(true), isTrue);
    expect(repo.updateLocationCalls, 1);
    expect(repo.lastLocation, const GeoPoint(5.6037, -0.1870));
  });

  test('an unavailable position does not undo going online', () async {
    repo.locationAvailable = false;
    final c = AvailabilityController(repo, online: false);
    expect(await c.setOnline(true), isTrue);
    expect(c.online, isTrue);
    expect(repo.updateLocationCalls, 0);
    expect(c.error, contains('location is not available'));
  });

  test('adopting a stored onTrip value leaves the toggle off', () {
    final c = AvailabilityController(repo)
      ..adoptStored(DriverAvailability.onTrip);
    expect(c.online, isFalse, reason: 'onTrip is not on the queue');
  });

  test('adopting a stored online value shows the toggle on', () {
    final c = AvailabilityController(repo)
      ..adoptStored(DriverAvailability.online);
    expect(c.online, isTrue);
  });

  // `onTrip` is the third value of the enum and the plan never wrote it, so a
  // driver who accepted an offer still read `online` -- the exact value
  // `match_offers_for_trip` filters on, and the same driver could be offered a
  // second trip while already driving the first.
  test('accepting an offer takes the driver off the queue', () async {
    final c = AvailabilityController(repo, online: true);
    await c.beginTrip();
    expect(c.online, isFalse);
    expect(repo.availability, DriverAvailability.onTrip);
  });

  test('a trip started while offline does not invent an onTrip write', () async {
    final c = AvailabilityController(repo, online: false);
    await c.beginTrip();
    expect(repo.setAvailabilityCalls, 0);
  });

  test('finishing a trip puts an online driver back on the queue', () async {
    final c = AvailabilityController(repo)
      ..adoptStored(DriverAvailability.online);
    await c.beginTrip();
    await c.endTrip();
    expect(c.online, isTrue);
    expect(repo.availability, DriverAvailability.online);
  });

  test('finishing a trip does not put an offline driver online', () async {
    final c = AvailabilityController(repo, online: false);
    await c.endTrip();
    expect(c.online, isFalse);
    expect(repo.setAvailabilityCalls, 0);
  });

  test('the toggle is not offered while a write is in flight', () async {
    final c = AvailabilityController(repo, online: false);
    expect(c.canToggle, isTrue);
    final pending = c.setOnline(true);
    expect(c.canToggle, isFalse);
    await pending;
    expect(c.canToggle, isTrue);
  });

  test('a state change tells the screen about it', () async {
    final c = AvailabilityController(repo, online: false);
    var notifications = 0;
    c.addListener(() => notifications++);
    await c.setOnline(true);
    expect(notifications, greaterThan(0));
  });

  testWidgets('the home screen refuses to go offline mid-trip', (tester) async {
    useDesignSurface(tester);
    repo.active = tripIn(TripState.ongoing);
    final availability = AvailabilityController(repo, online: true);
    await tester.pumpWidget(appHarness(home(availability, repo)));

    expect(find.text('You are online'), findsOneWidget);
    await tester.tap(find.byKey(const Key('onlineToggle')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Finish or cancel'), findsOneWidget);
    expect(repo.setAvailabilityCalls, 0);
    expect(find.text('You are online'), findsOneWidget);
  });

  testWidgets('the home screen names the error when the write fails',
      (tester) async {
    useDesignSurface(tester);
    repo.availabilityFails = true;
    final availability = AvailabilityController(repo, online: false);
    await tester.pumpWidget(appHarness(home(availability, repo)));

    await tester.tap(find.byKey(const Key('onlineToggle')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('availabilityError')), findsOneWidget);
    expect(find.text('You are offline'), findsOneWidget);
  });

  testWidgets('an offline driver is told to go online first', (tester) async {
    useDesignSurface(tester);
    final availability = AvailabilityController(repo, online: false);
    await tester.pumpWidget(appHarness(home(availability, repo)));
    expect(find.text('Go online to start receiving requests'), findsOneWidget);
  });

  testWidgets('an online driver with an empty queue waits for requests',
      (tester) async {
    useDesignSurface(tester);
    final availability = AvailabilityController(repo, online: true);
    await tester.pumpWidget(appHarness(home(availability, repo)));
    expect(find.text('Waiting for ride requests near you'), findsOneWidget);
  });
}
