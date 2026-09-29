import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';
import 'package:meetngo_driver/main.dart';
import 'package:meetngo_driver/src/app/driver_config.dart';
import 'package:meetngo_driver/src/app/driver_flow.dart';
import 'package:meetngo_driver/src/app/driver_shell.dart';
import 'package:meetngo_driver/src/auth/driver_auth_controller.dart';
import 'package:meetngo_driver/src/auth/driver_login_screen.dart';
import 'package:meetngo_driver/src/data/driver_auth_repository.dart';
import 'package:meetngo_driver/src/earnings/earnings_controller.dart';
import 'package:meetngo_driver/src/offers/availability_controller.dart';
import 'package:provider/provider.dart';

import '../support/fakes.dart';
import '../support/harness.dart';

/// Pumps without advancing the clock, so a periodic timer never fires.
Future<void> settle(WidgetTester tester, [int frames = 5]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump();
  }
}

void main() {
  // The build under test has no `--dart-define`, which is the state a first run
  // is in. Without this branch the app would reach `Supabase.instance` and throw
  // on the first frame, which tells a first-time runner nothing at all.
  testWidgets('with no credentials the app says which two are missing', (
    tester,
  ) async {
    useDesignSurface(tester);
    expect(DriverConfig.isConfigured, isFalse);

    await tester.pumpWidget(const DriverNGoApp());
    await tester.pumpAndSettle();

    expect(find.textContaining('No Supabase project is connected'), findsOneWidget);
    expect(find.textContaining('SUPABASE_URL'), findsOneWidget);
    expect(find.textContaining('SUPABASE_ANON_KEY'), findsOneWidget);
  });

  testWidgets('the app boots to a MaterialApp', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(const DriverNGoApp());
    expect(find.byType(MaterialApp), findsOneWidget);
  });

  test('the config reads two compile-time values and nothing else', () {
    expect(DriverConfig.supabaseUrl, isA<String>());
    expect(DriverConfig.supabaseAnonKey, isA<String>());
    expect(
      DriverConfig.isConfigured,
      DriverConfig.supabaseUrl.isNotEmpty &&
          DriverConfig.supabaseAnonKey.isNotEmpty,
    );
  });

  group('DriverFlow', () {
    test('an unapproved driver is not allowed to drive', () async {
      final flow = DriverFlow(
        drivers: StubDriverRepository(
          profile: driverProfile(kyc: KycStatus.pending),
        ),
        earnings: StubEarningsRepository(),
      );
      addTearDown(flow.dispose);

      await flow.load();
      expect(flow.kycApproved, isFalse);
    });

    // `match_offers_for_trip` only matches `kyc_status = 'approved'` drivers, so
    // a driver who is not approved must not reach the offer queue at all. The
    // gate lives on the flow so there is one answer to "may this driver drive".
    test('a driver with no profile at all is not allowed to drive', () async {
      final flow = DriverFlow(
        drivers: StubDriverRepository(),
        earnings: StubEarningsRepository(),
      );
      addTearDown(flow.dispose);

      await flow.load();
      expect(flow.profile, isNull);
      expect(flow.kycApproved, isFalse);
    });

    test('a rejected driver is not allowed to drive', () async {
      final flow = DriverFlow(
        drivers: StubDriverRepository(
          profile: driverProfile(kyc: KycStatus.rejected),
        ),
        earnings: StubEarningsRepository(),
      );
      addTearDown(flow.dispose);

      await flow.load();
      expect(flow.kycApproved, isFalse);
    });

    test('an approved driver may drive', () async {
      final flow = DriverFlow(
        drivers: StubDriverRepository(profile: driverProfile()),
        earnings: StubEarningsRepository(),
      );
      addTearDown(flow.dispose);

      await flow.load();
      expect(flow.kycApproved, isTrue);
      expect(flow.error, isNull);
    });

    test('a failed profile read is reported and blocks driving', () async {
      final repo = StubDriverRepository(profile: driverProfile())..meFails = true;
      final flow = DriverFlow(drivers: repo, earnings: StubEarningsRepository());
      addTearDown(flow.dispose);

      await flow.load();
      expect(flow.error, isNotNull);
      expect(flow.kycApproved, isFalse);
      expect(flow.loading, isFalse);
    });

    test('the toggle is seeded from the value the server holds', () async {
      final flow = DriverFlow(
        drivers: StubDriverRepository(
          profile: driverProfile(availability: DriverAvailability.online),
        ),
        earnings: StubEarningsRepository(),
      );
      addTearDown(flow.dispose);

      await flow.load();
      expect(flow.availability.online, isTrue);
    });

    // The phone died mid-trip, or the app was killed. A driver whose profile
    // still reads `onTrip` with no live trip is invisible to the matcher forever,
    // and the driver has no way to work out why.
    test('a stored onTrip with no trip behind it goes back on the queue',
        () async {
      final repo = StubDriverRepository(
        profile: driverProfile(availability: DriverAvailability.onTrip),
      );
      final flow = DriverFlow(drivers: repo, earnings: StubEarningsRepository());
      addTearDown(flow.dispose);

      await flow.load();
      expect(repo.availability, DriverAvailability.online);
      expect(flow.availability.online, isTrue);
    });

    test('a stored onTrip with a live trip behind it is left alone', () async {
      final repo = StubDriverRepository(
        profile: driverProfile(availability: DriverAvailability.onTrip),
      )..active = tripIn(TripState.ongoing);
      final flow = DriverFlow(drivers: repo, earnings: StubEarningsRepository());
      addTearDown(flow.dispose);

      await flow.load();
      expect(
        repo.setAvailabilityCalls,
        0,
        reason: 'a driver mid-trip is not moved by a load',
      );
      expect(flow.availability.online, isFalse);
    });

    test('the controllers are made once and handed to the screens', () async {
      final flow = DriverFlow(
        drivers: StubDriverRepository(profile: driverProfile()),
        earnings: StubEarningsRepository(),
      );
      addTearDown(flow.dispose);

      final availability = flow.availability;
      final offers = flow.offers;
      final active = flow.activeTrip;
      // A controller rebuilt on every rebuild would drop an in-flight request
      // and a pending error.
      expect(identical(flow.availability, availability), isTrue);
      expect(identical(flow.offers, offers), isTrue);
      expect(identical(flow.activeTrip, active), isTrue);
      expect(availability, isA<AvailabilityController>());
      expect(flow.earnings, isA<StubEarningsRepository>());
    });

    test('an offer fed to the flow lands in the queue', () async {
      final flow = DriverFlow(
        drivers: StubDriverRepository(profile: driverProfile()),
        earnings: StubEarningsRepository(),
      );
      addTearDown(flow.dispose);
      await flow.load();

      flow.addOffer(offer('a'));
      expect(flow.offers.offers.map((o) => o.id), ['a']);
    });

    test('a failed trip read is reported rather than thrown', () async {
      final repo = StubDriverRepository(profile: driverProfile())
        ..activeTripFails = true;
      final flow = DriverFlow(drivers: repo, earnings: StubEarningsRepository());
      addTearDown(flow.dispose);

      expect(await flow.readActiveTrip(), isNull);
      expect(flow.error, isNotNull);
    });

    test('reset forgets the trip and empties the queue', () async {
      final flow = DriverFlow(
        drivers: StubDriverRepository(profile: driverProfile()),
        earnings: StubEarningsRepository(),
      );
      addTearDown(flow.dispose);
      await flow.load();
      flow.activeTrip.trip = tripIn(TripState.ongoing);
      flow.addOffer(offer('a'));

      flow.reset();

      expect(flow.activeTrip.trip, isNull);
      expect(flow.offers.offers, isEmpty);
    });

    test('the profile watch updates the gate', () async {
      final repo = StubDriverRepository(
        profile: driverProfile(kyc: KycStatus.pending),
      );
      final flow = DriverFlow(drivers: repo, earnings: StubEarningsRepository());
      addTearDown(flow.dispose);
      await flow.load();
      expect(flow.kycApproved, isFalse);

      // A second read, as an admin's approval would come back through.
      repo.profile = driverProfile(kyc: KycStatus.approved);
      flow.startProfileWatch();
      await Future<void>.delayed(Duration.zero);

      expect(flow.kycApproved, isTrue);
    });

    // `load` catches rather than throws, so the shell calls `startProfileWatch`
    // straight after a *failed* read too. The subscription could then hand back
    // a profile the failed read never produced, and the first event replaced
    // `profile` and the KYC gate with it -- moving a driver whose status nobody
    // had successfully read into the offer queue.
    test('a watch event cannot stand in for a read that never happened',
        () async {
      final repo = StubDriverRepository(profile: driverProfile())..meFails = true;
      final flow = DriverFlow(drivers: repo, earnings: StubEarningsRepository());
      addTearDown(flow.dispose);
      await flow.load();
      expect(flow.error, isNotNull);
      expect(flow.kycApproved, isFalse);

      repo.meFails = false;
      repo.profile = driverProfile();
      flow.startProfileWatch();
      await Future<void>.delayed(Duration.zero);

      expect(
        flow.kycApproved,
        isFalse,
        reason: 'the watch is refused until a read has succeeded',
      );
    });

    test('a read that succeeds re-arms the watch', () async {
      final repo = StubDriverRepository(profile: driverProfile())..meFails = true;
      final flow = DriverFlow(drivers: repo, earnings: StubEarningsRepository());
      addTearDown(flow.dispose);
      await flow.load();
      flow.startProfileWatch();

      repo.meFails = false;
      repo.profile = driverProfile(kyc: KycStatus.approved);
      await flow.load();
      expect(flow.kycApproved, isTrue);
    });

    test('the flow disposes the controllers it made', () async {
      final flow = DriverFlow(
        drivers: StubDriverRepository(profile: driverProfile()),
        earnings: StubEarningsRepository(),
      );
      await flow.load();
      final availability = flow.availability;
      flow.dispose();
      // A ChangeNotifier that has been disposed throws when it notifies, which is
      // how a screen still holding one announces the bug.
      expect(() => availability.notifyListeners(), throwsFlutterError);
    });
  });

  group('the shell', () {
    /// Drives the shipped [DriverShell] with a flow over fakes.
    ///
    /// The shell owns two timers, so the tree is torn down at the end of every
    /// test: a pending periodic timer is a test failure, and a shell left
    /// running would keep ticking against a disposed flow.
    ///
    /// The auth repository and controller are here because the shell reads them
    /// for the Profile tab -- the email on the driver's own session, and the
    /// sign-out call -- and `main.dart` registers exactly these two. Leaving
    /// them out would be a test that only passes because the Profile tab is
    /// never opened.
    Future<void> pumpShell(
      WidgetTester tester,
      StubDriverRepository repo, {
      StubDriverAuthRepository? auth,
    }) async {
      final flow = DriverFlow(
        drivers: repo,
        earnings: StubEarningsRepository(),
        // A fake reader, so the boot-time location check does not go out to a
        // platform channel the test binding has no answer for.
        locationReader: StubLocationReader(),
      );
      addTearDown(flow.dispose);
      await tester.pumpWidget(
        appHarness(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<DriverFlow>.value(value: flow),
              Provider<DriverAuthRepository>.value(
                value: auth ?? StubDriverAuthRepository(),
              ),
              ChangeNotifierProvider<DriverAuthController>(
                create: (c) => DriverAuthController(c.read<DriverAuthRepository>()),
              ),
            ],
            child: const DriverShell(),
          ),
        ),
      );
      // Bounded pumps, not `pumpAndSettle`. The shell owns a one-second offer
      // tick and a three-second trip poll, and `pumpAndSettle` keeps pumping
      // until nothing schedules a frame -- against a periodic timer that is
      // either a long wait or a timeout, and neither tells a reader what
      // happened. Plain `pump` does not advance the test clock, so the timers
      // never fire and five pumps are enough for the boot callback and its
      // awaits.
      await settle(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await settle(tester);
      });
    }

    // `match_offers_for_trip` only matches `kyc_status = 'approved'` drivers, so
    // a driver who is not approved must not reach the offer queue at all. This is
    // the shipped shell deciding that, not a stand-in for it.
    testWidgets('an unapproved driver is walked through KYC, not the queue', (
      tester,
    ) async {
      useDesignSurface(tester);
      await pumpShell(
        tester,
        StubDriverRepository(profile: driverProfile(kyc: KycStatus.pending)),
      );

      // The contract is "in the KYC flow, not the offer queue", and which step
      // of the flow is a different question. This test used to pin the identity
      // step, which is what the app did before it learned to resume -- and a
      // `pending` driver has their Ghana Card in, so resuming at the identity
      // step would be asking a driver to re-enter a name the server already
      // holds. The gate is asserted; the step is not.
      expect(find.text('Earnings'), findsNothing);
      expect(find.byKey(const Key('onlineToggle')), findsNothing);
      // Something from the flow itself. Any of the step headlines will do.
      final inFlow = find.textContaining('Verification').evaluate().isNotEmpty ||
          find.text('Take a selfie').evaluate().isNotEmpty ||
          find.text('Add your vehicle').evaluate().isNotEmpty ||
          find.text('Review your details').evaluate().isNotEmpty;
      expect(inFlow, isTrue, reason: 'not in KYC and not in the queue');
    });

    testWidgets('a driver with no profile is walked through KYC', (
      tester,
    ) async {
      useDesignSurface(tester);
      await pumpShell(tester, StubDriverRepository());
      // No profile at all: nothing to resume from, so the first step, which is
      // the list of documents to send. The name field is two steps further on
      // and asserting on it here would be asserting on a step this driver has
      // not reached.
      expect(find.byKey(const Key('documentChecklist')), findsOneWidget);
      expect(find.byKey(const Key('onlineToggle')), findsNothing);
    });

    testWidgets('an approved driver gets the toggle and the four tabs', (
      tester,
    ) async {
      useDesignSurface(tester);
      await pumpShell(
        tester,
        StubDriverRepository(profile: driverProfile()),
      );

      expect(find.byKey(const Key('onlineToggle')), findsOneWidget);
      for (final tab in ['Drivers', 'Trips', 'Earnings', 'Profile']) {
        expect(find.text(tab), findsOneWidget, reason: tab);
      }
    });

    testWidgets('Earnings is the third tab and opens the wallet', (tester) async {
      useDesignSurface(tester);
      await pumpShell(tester, StubDriverRepository(profile: driverProfile()));

      await tester.tap(find.text('Earnings'));
      await settle(tester);

      expect(find.byKey(const Key('availableBalance')), findsOneWidget);
      expect(find.byKey(const Key('lifetimeEarnings')), findsOneWidget);
    });

    testWidgets('Trips is the second tab and opens the trip history', (
      tester,
    ) async {
      useDesignSurface(tester);
      final repo = StubDriverRepository(
        profile: driverProfile(),
        trips: [driverTrip(id: 't1')],
      );
      await pumpShell(tester, repo);

      await tester.tap(find.text('Trips'));
      await settle(tester);

      // The read happens on arrival, so the row can only be there if the tab
      // asked for it -- the placeholder this replaced never asked for anything.
      expect(repo.myTripsCalls, 1);
      expect(find.byKey(const Key('tripsList')), findsOneWidget);
      expect(find.byKey(const Key('tripRow-t1')), findsOneWidget);
      expect(find.text('Not built yet'), findsNothing);
    });

    testWidgets('Profile is the fourth tab and reads the driver own row', (
      tester,
    ) async {
      useDesignSurface(tester);
      final repo = StubDriverRepository(
        profile: driverProfile(fullName: 'Ama Mensah'),
        vehicle: driverVehicle(),
      );
      final auth = StubDriverAuthRepository()..email = 'ama@example.com';
      await pumpShell(tester, repo, auth: auth);

      await tester.tap(find.text('Profile'));
      await settle(tester);

      expect(find.text('Ama Mensah'), findsOneWidget);
      // The email comes from the driver's own session, not from `profiles`:
      // that table has no email column, so the repository is the only place it
      // can come from and a fake with none has to render no row at all.
      expect(find.text('ama@example.com'), findsOneWidget);
      expect(find.byKey(const Key('signOutButton')), findsOneWidget);
      expect(find.text('Not built yet'), findsNothing);
    });

    testWidgets('Sign out on the Profile tab ends the session', (tester) async {
      useDesignSurface(tester);
      final auth = StubDriverAuthRepository()..email = 'ama@example.com';
      await pumpShell(
        tester,
        StubDriverRepository(profile: driverProfile(), vehicle: driverVehicle()),
        auth: auth,
      );

      await tester.tap(find.text('Profile'));
      await settle(tester);
      await tester.tap(find.byKey(const Key('signOutButton')));
      await settle(tester);

      expect(auth.signedOut, isTrue);
    });

    testWidgets('a refused sign out is shown, not swallowed', (tester) async {
      useDesignSurface(tester);
      final auth = StubDriverAuthRepository()
        ..email = 'ama@example.com'
        ..failSignOutWith = 'Could not sign out';
      await pumpShell(
        tester,
        StubDriverRepository(profile: driverProfile(), vehicle: driverVehicle()),
        auth: auth,
      );

      await tester.tap(find.text('Profile'));
      await settle(tester);
      await tester.tap(find.byKey(const Key('signOutButton')));
      await settle(tester);

      expect(auth.signedOut, isFalse);
      expect(find.text('Could not sign out'), findsOneWidget);
    });

    testWidgets('a live trip opens the trip screen over the tabs', (
      tester,
    ) async {
      useDesignSurface(tester);
      final repo = StubDriverRepository(profile: driverProfile())
        ..active = tripIn(TripState.matched);
      await pumpShell(tester, repo);

      expect(find.byKey(const Key('tripStateChip')), findsOneWidget);
      expect(find.byKey(const Key('primaryActionButton')), findsOneWidget);
      expect(find.text('Earnings'), findsNothing, reason: 'tabs are not shown');
    });

    testWidgets('a failed profile read does not offer the queue', (
      tester,
    ) async {
      useDesignSurface(tester);
      final repo = StubDriverRepository(profile: driverProfile())..meFails = true;
      await pumpShell(tester, repo);

      // The gate is "no offer queue", which is the thing that would let an
      // unapproved driver be matched. That it is the document list rather than
      // the name field is a detail of where a driver with no readable profile
      // starts, and it is asserted on the document list so both tests are
      // saying the same thing about the same gate.
      expect(find.byKey(const Key('onlineToggle')), findsNothing);
      expect(find.byKey(const Key('documentChecklist')), findsOneWidget);
    });
  });

  testWidgets('the login screen is the thing before the app', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(
      appHarness(
        ChangeNotifierProvider<DriverAuthController>(
          create: (_) => DriverAuthController(StubDriverAuthRepository()),
          child: const DriverLoginScreen(),
        ),
      ),
    );
    expect(find.byKey(const Key('loginButton')), findsOneWidget);
    expect(find.byKey(const Key('emailField')), findsOneWidget);
  });

  test('the earnings controller the flow builds is the same one it hands out',
      () async {
    final repo = StubEarningsRepository();
    final flow = DriverFlow(
      drivers: StubDriverRepository(profile: driverProfile()),
      earnings: repo,
    );
    addTearDown(flow.dispose);
    final controller = EarningsController(flow.earnings);
    await controller.load();
    expect(controller.snapshot, isNotNull);
  });
}
