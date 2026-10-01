import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

import '../active_trip/active_trip_controller.dart';
import '../active_trip/active_trip_screen.dart';
import '../active_trip/leave_trip_controller.dart';
import '../active_trip/return_trip_banner.dart';
import '../auth/driver_auth_controller.dart';
import '../chat/chat_controller.dart';
import '../navigation/navigation_controller.dart';
import '../navigation/navigation_host.dart';
import '../contact/contact_controller.dart';
import '../data/driver_auth_repository.dart';
import '../data/driver_repository.dart';
import '../earnings/earnings_controller.dart';
import '../earnings/wallet_screen.dart';
import '../onboarding/kyc_controller.dart';
import '../onboarding/kyc_screen.dart';
import '../onboarding/phone_gate_screen.dart';
import '../offers/driver_home_screen.dart';
import '../profile/driver_profile_screen.dart';
import '../report/left_item_controller.dart';
import '../trips/trips_controller.dart';
import '../trips/trips_screen.dart';
import 'driver_flow.dart';

/// The driver's frame: the four bottom-nav tabs, and the flow that runs over
/// them.
///
/// The flow is one `_stage` rather than a route stack, for the reason
/// `RiderShell` gives: a trip a driver can navigate back out of is a trip they
/// can leave half-finished. A stage only ever moves forward.
///
/// Two timers, both owned here rather than by a screen, so a screen can be
/// rendered in a test without leaving a pending timer behind:
///  * a one-second tick over the offer queue, which does two jobs. It enforces
///    the TTL on screen, because no sweeper exists in the tree, and it re-renders
///    the countdown on the offer card. The second job is the reason the timer
///    stays at one second rather than going to five alongside the TTL: with a
///    five-minute offer and a thirty-second tick, the card would read "300s" for
///    half a minute and then jump, and a countdown that lies about being live is
///    worse than no countdown. One wake-up a second to keep one number honest is
///    not the cost that mattered;
///  * a three-second poll of the live trip, because `accept_offer` matches the
///    trip under a lock on another device's call, and the only way this driver
///    learns about it is by asking again.
class DriverShell extends StatefulWidget {
  const DriverShell({super.key});

  @override
  State<DriverShell> createState() => _DriverShellState();
}

enum _Stage { home, trip }

class _DriverShellState extends State<DriverShell> {
  static const _tabs = ['Drivers', 'Trips', 'Earnings', 'Profile'];

  int _tab = 0;
  _Stage _stage = _Stage.home;
  Timer? _expiry;
  Timer? _poll;
  StreamSubscription<Offer>? _offerWatch;
  KycController? _kyc;
  EarningsController? _earnings;
  TripsController? _trips;
  Vehicle? _vehicle;

  /// The other party's phone number for the live trip. Null until the trip
  /// stage first builds, and deliberately not cleared between trips by hand --
  /// `_tick` calls `load(tripId)` with the new id, and the controller supersedes
  /// a late answer from the previous one rather than showing a previous rider's
  /// number.
  ContactController? _contact;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  Future<void> _boot() async {
    if (!mounted) return;
    final flow = context.read<DriverFlow>();
    // Not awaited, and first: the map on the home tab and the pin on the live
    // trip are both waiting on it, and a phone can take twenty seconds to find
    // a satellite. Awaiting it here would hold the first frame for twenty
    // seconds on a spinner.
    unawaited(flow.refreshLocation());
    await flow.load();
    if (!mounted) return;
    flow.startProfileWatch();
    _startExpiry();
    if (!flow.kycApproved) {
      _kyc ??= KycController(flow.drivers);
      return;
    }
    final live = await flow.readActiveTrip();
    if (!mounted) return;
    if (live != null) {
      flow.activeTrip.trip = live;
      _startPolling();
      setState(() => _stage = _Stage.trip);
    } else {
      _beginOfferWatch();
    }
  }

  void _startExpiry() {
    _expiry?.cancel();
    _expiry = Timer.periodic(
      const Duration(seconds: 1),
      (_) => context.read<DriverFlow>().offers.tick(),
    );
  }

  void _beginOfferWatch() {
    if (_offerWatch != null) return;
    final flow = context.read<DriverFlow>();
    _offerWatch = flow.drivers.watchOffers().listen(
      flow.addOffer,
      onError: (Object e) => _toast(e.toString()),
    );
  }

  /// The contact controller for the live trip, created once and reused.
  ///
  /// Built here rather than in `DriverFlow` because it is the only consumer, and
  /// because it has to be *the same instance* every time the trip screen is
  /// rebuilt -- a new controller per build would show a number that then vanishes
  /// and reappears as "Loading" on every frame the parent rebuilt.
  ///
  /// The lookup is fired against the trip the shell already knows about, in
  /// `_tick`, and this only hands the controller over. Splitting it that way
  /// means the screen is a pure function of its arguments and a test can render
  /// it with a stub repository.
  /// Navigation for the trip on screen. Owned here because it has to outlive the
  /// trip screen: the controller holds the route, the last-spoken step and the
  /// stuck timer, and a screen that rebuilt would drop all three.
  NavigationHost? _navigation;

  NavigationHost _navigationFor() {
    return _navigation ??= NavigationHost(
      repository: context.read<RouteRepository>(),
      // Read rather than built, for the same reason the repositories are.
      speech: context.read<SpeechPort>(),
    );
  }

  ContactController _contactFor(DriverFlow flow) {
    return _contact ??= ContactController(flow.contacts);
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _tick());
  }

  /// The trip the driver still holds, which the home screen shows as a banner.
  ///
  /// Null until `_tick` has found one, and deliberately *not* clearing to null
  /// while the poll is merely slow: a banner that flickers off and on every three
  /// seconds while the phone is trying to reach the network is worse than one that
  /// stays until the trip is genuinely gone.
  Trip? _returning;

  /// Adopt a trip the driver is still holding and show the banner for it.
  void _holdTrip(Trip live) {
    if (!mounted) return;
    if (_returning?.id == live.id) return;
    setState(() => _returning = live);
  }

  /// Drop the banner because the trip is over, or because the driver opened it.
  void _releaseTrip() {
    if (!mounted || _returning == null) return;
    setState(() => _returning = null);
  }

  Future<void> _tick() async {
    if (!mounted) return;
    final flow = context.read<DriverFlow>();
    final live = await flow.readActiveTrip();
    if (!mounted) return;
    if (live == null) {
      // A trip that has finished while the app was open closes the banner. Without
      // this a driver who completes a trip keeps being told they have one -- and
      // keeps following a route to somewhere they have already been.
      _releaseTrip();
      _navigation?.stop();
      return;
    }
    flow.activeTrip.trip = live;
    // Navigation follows the driver, and this poll already reads the position
    // the location controller is holding. Feeding it from here rather than from
    // a second timer is the difference between one location stream per trip and
    // two, on a connection that is metered.
    unawaited(_navigation?.onMoved(flow.location.point ?? live.pickup.point));
    _holdTrip(live);
    if (_stage != _Stage.trip) {
      setState(() {
        _stage = _Stage.trip;
        _tab = 0;
      });
      _startPolling();
    }
    // The contact lookup rides along with the poll rather than being fired from
    // the trip screen's `initState`, for one reason: the trip id is the input, and
    // the poll is the only place that reliably has the *current* one. A screen
    // that looked its own id up could fire against the trip the driver has just
    // finished.
    unawaited(_contactFor(flow).load(live.id));
  }

  /// The driver won the offer, so they are off the queue and the trip is live.
  Future<void> _onOfferAccepted() async {
    final flow = context.read<DriverFlow>();
    await flow.availability.beginTrip();
    if (!mounted) return;
    await _tick();
  }

  /// The driver genuinely left the trip, and the stage may now move backwards.
  ///
  /// This is the *only* path out of `_Stage.trip` that is not `_finishTrip`, and
  /// the stage machine is deliberately one-way everywhere else. The reason is not
  /// tidiness: every other transition is a stage the driver reached by doing the
  /// thing that stage is for, and a stage reached any other way is a stage whose
  /// preconditions nobody checked. Leaving is the exception because it is the one
  /// case where the driver legitimately ends up back where they started, and
  /// because the alternative -- no way out of a trip that is not going ahead -- is
  /// how a driver ends up sitting in a dead trip until they force-quit.
  ///
  /// `flow.reset()` rather than a bespoke unwind, because after leaving there is
  /// no trip, no trip history refresh is owed, and the earnings figure did not
  /// move. The same three lines `_finishTrip` runs, for the same reasons.
  Future<void> _onTripLeft() async {
    final flow = context.read<DriverFlow>();
    if (!mounted) return;
    _stopPolling();
    _navigation?.stop();
    flow.reset();
    setState(() {
      _stage = _Stage.home;
      _tab = 0;
    });
    // The driver is back on the offer queue -- `leave-trip` set them `online`
    // server-side -- so the queue has to start feeding again, or they sit on an
    // empty home screen after leaving a trip.
    _beginOfferWatch();
    _startPolling();
    _toast('You left the trip. Your rider is looking for another driver.');
  }

  Future<void> _finishTrip() async {
    final flow = context.read<DriverFlow>();
    await flow.availability.endTrip();
    if (!mounted) return;
    _stopPolling();
    _navigation?.stop();
    flow.reset();
    setState(() {
      _stage = _Stage.home;
      _tab = 2;
    });
    await _earningsFor(flow).load();
  }

  Future<void> _recheckKyc() async {
    final flow = context.read<DriverFlow>();
    await flow.load();
    if (!mounted || !flow.kycApproved) return;
    _beginOfferWatch();
    setState(() => _stage = _Stage.home);
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  @override
  void dispose() {
    _expiry?.cancel();
    _stopPolling();
    _offerWatch?.cancel();
    _offerWatch = null;
    _navigation?.stop();
    _navigation?.dispose();
    _kyc?.dispose();
    _earnings?.dispose();
    _trips?.dispose();
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final flow = context.watch<DriverFlow>();

    if (flow.loading && flow.profile == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (!flow.kycApproved) {
      final kyc = _kyc ??= KycController(flow.drivers);
      return ChangeNotifierProvider<KycController>.value(
        value: kyc,
        child: KycScreen(controller: kyc, onContinue: _recheckKyc),
      );
    }

    // A driver who is approved but has no phone number.
    //
    // Placed *after* the KYC gate and *before* everything else, and that
    // ordering is the whole decision. Every driver registered before the phone
    // field existed has `phone = ''`, so without this they would open the app
    // fully approved, take rides, and be unreachable by every rider on them --
    // and nothing on any screen would tell them or the rider.
    //
    // After KYC, because their documents are already accepted and sending them
    // back through six uploads to add one field is how you lose a verified
    // driver. Before the home screen, because a driver who cannot be called
    // cannot take a passenger, so the app has nothing to offer them.
    //
    // The profile is refreshed rather than cached on the shell: `watchProfile`
    // is a realtime stream on `profiles`, so this update arrives by itself and
    // the gate clears on the next frame without the shell keeping a second copy
    // of the profile.
    if (!flow.hasCallablePhone) {
      return PhoneGateScreen(onSaved: (phone) async {
        await flow.drivers.savePhone(phone);
        await flow.load();
      });
    }

    if (_stage == _Stage.trip) {
      return ChangeNotifierProvider<ActiveTripController>.value(
        value: flow.activeTrip,
        child: ActiveTripScreen(
          onFinished: _finishTrip,
          location: flow.location,
          contact: _contactFor(flow),
          // Read from the provider rather than built here, so the shell does not
          // need the Supabase client and the wiring test can leave both out.
          //
          // `read`, not `watch`: neither repository changes while a trip is live,
          // and a `watch` would rebuild the trip screen on every provider change
          // for no gain.
          //
          // The profile id decides which chat bubbles are the driver's own. It is
          // null only before the first profile read, and the shell renders a
          // spinner until that resolves, so by the time the trip screen exists
          // there is a profile.
          chatRepository: context.read<ChatRepository>(),
          leftItemRepository: context.read<LeftItemRepository>(),
          leaveTripRepository: context.read<LeaveTripRepository>(),
          navigationHost: _navigationFor(),
          onTripLeft: _onTripLeft,
          driverId: flow.profile?.id,
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        bottom: false,
        // The banner sits above the tab body, not inside it. Inside the home tab
        // it would scroll away the moment the driver touched the map, and the one
        // screen where they must not lose sight of it is the one they arrive on.
        child: Column(
          children: [
            if (_returning != null)
              Padding(
                padding: EdgeInsets.fromLTRB(12.w, 8.h, 12.w, 0),
                child: ReturnTripBanner(
                  trip: _returning!,
                  // The rider's name comes from the contact controller, which is
                  // the only thing in this app permitted to know it.
                  riderName: _contact?.contact?.name,
                  onOpen: () {
                    // Not a setState to the trip stage directly: the trip
                    // controller has to be told first, or the trip screen renders
                    // against a trip that is null.
                    flow.activeTrip.trip = _returning;
                    _releaseTrip();
                    setState(() {
                      _stage = _Stage.trip;
                      _tab = 0;
                    });
                    _startPolling();
                  },
                ),
              ),
            Expanded(child: _tabBody(flow)),
          ],
        ),
      ),
      bottomNavigationBar: _nav(flow),
    );
  }

  Widget _tabBody(DriverFlow flow) {
    switch (_tab) {
      case 0:
        return DriverHomeScreen(
          availability: flow.availability,
          offers: flow.offers,
          profile: flow.profile,
          location: flow.location,
          onAccepted: _onOfferAccepted,
        );
      case 1:
        // Provided rather than passed in, exactly as the wallet is: the list is
        // reloaded on every visit to the tab, so the controller has to outlive
        // the screen that reads it.
        return ChangeNotifierProvider<TripsController>.value(
          value: _tripsFor(flow),
          child: const TripsScreen(),
        );
      case 2:
        final earnings = _earningsFor(flow);
        return ChangeNotifierProvider<EarningsController>.value(
          value: earnings,
          child: const WalletScreen(),
        );
      case 3:
        return DriverProfileScreen(
          profile: flow.profile,
          email: context.read<DriverAuthRepository>().currentEmail,
          vehicle: _vehicleFor(flow),
          busy: context.watch<DriverAuthController>().busy,
          onSignOut: _signOut,
        );
      default:
        return const SizedBox.shrink();
    }
  }

  EarningsController _earningsFor(DriverFlow flow) =>
      _earnings ??= EarningsController(flow.earnings);

  TripsController _tripsFor(DriverFlow flow) =>
      _trips ??= TripsController(flow.drivers);

  /// The driver's one vehicle, read once per shell and kept.
  ///
  /// A `FutureBuilder` here would re-read on every rebuild, and this screen
  /// rebuilds on every availability change. The row cannot change underneath
  /// the driver -- a vehicle is added during onboarding, and the KYC gate means
  /// a driver who has not added one never reaches this tab -- so one read per
  /// session is the whole story.
  Vehicle? _vehicleFor(DriverFlow flow) {
    if (_readVehicle) return _vehicle;
    _readVehicle = true;
    unawaited(_loadVehicle(flow));
    return _vehicle;
  }

  bool _readVehicle = false;

  Future<void> _loadVehicle(DriverFlow flow) async {
    try {
      final vehicle = await flow.drivers.myVehicle();
      if (!mounted || vehicle == null) return;
      setState(() => _vehicle = vehicle);
    } on DriverAuthFailure catch (e) {
      _toast(e.message);
    }
  }

  /// Ends the session.
  ///
  /// Handled by the auth controller rather than by `Supabase.instance` so the
  /// failure has somewhere to go: a refused sign-out that is swallowed leaves
  /// the driver looking at a Profile tab that no longer signs them out.
  Future<void> _signOut() async {
    final auth = context.read<DriverAuthController>();
    if (await auth.submitSignOut()) return;
    if (!mounted) return;
    _toast(auth.error ?? 'Could not sign out');
  }

  Widget _nav(DriverFlow flow) {
    return Container(
      decoration: const BoxDecoration(
        color: MngColors.page,
        border: Border(top: BorderSide(color: MngColors.divider)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 60.h,
          child: Row(
            children: [
              for (var i = 0; i < _tabs.length; i++)
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _selectTab(flow, i),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _iconFor(i),
                          size: 22,
                          color: _tab == i
                              ? MngColors.primary
                              : MngColors.textSub,
                        ),
                        SizedBox(height: 3.h),
                        Text(
                          _tabs[i],
                          style: MngTheme.light.textTheme.bodySmall?.copyWith(
                            fontSize: 10.sp,
                            color: _tab == i
                                ? MngColors.textPrimary
                                : MngColors.textSub,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _selectTab(DriverFlow flow, int index) {
    setState(() => _tab = index);
    // The two tabs that read from the server are read on arrival rather than
    // on first build, so a driver who never opens Trips never pays for the
    // query and a driver who does sees today's figures.
    if (index == 1) unawaited(_tripsFor(flow).load());
    if (index == 2) unawaited(_earningsFor(flow).load());
  }

  IconData _iconFor(int index) {
    const icons = [
      Icons.directions_car_outlined,
      Icons.receipt_long_outlined,
      Icons.account_balance_wallet_outlined,
      Icons.person_outline,
    ];
    return icons[index];
  }
}
