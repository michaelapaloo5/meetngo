import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

import '../active_trip/active_trip_controller.dart';
import '../active_trip/active_trip_screen.dart';
import '../earnings/earnings_controller.dart';
import '../earnings/wallet_screen.dart';
import '../onboarding/kyc_controller.dart';
import '../onboarding/kyc_screen.dart';
import '../offers/driver_home_screen.dart';
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
///  * a one-second tick that expires the offer queue, because the 20-second TTL
///    is enforced on screen and nowhere else -- no sweeper exists in the tree;
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  Future<void> _boot() async {
    if (!mounted) return;
    final flow = context.read<DriverFlow>();
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

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _tick());
  }

  Future<void> _tick() async {
    if (!mounted) return;
    final flow = context.read<DriverFlow>();
    final live = await flow.readActiveTrip();
    if (!mounted || live == null) return;
    flow.activeTrip.trip = live;
    if (_stage != _Stage.trip) {
      setState(() {
        _stage = _Stage.trip;
        _tab = 0;
      });
      _startPolling();
    }
  }

  /// The driver won the offer, so they are off the queue and the trip is live.
  Future<void> _onOfferAccepted() async {
    final flow = context.read<DriverFlow>();
    await flow.availability.beginTrip();
    if (!mounted) return;
    await _tick();
  }

  Future<void> _finishTrip() async {
    final flow = context.read<DriverFlow>();
    await flow.availability.endTrip();
    if (!mounted) return;
    _stopPolling();
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
    _kyc?.dispose();
    _earnings?.dispose();
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

    if (_stage == _Stage.trip) {
      return ChangeNotifierProvider<ActiveTripController>.value(
        value: flow.activeTrip,
        child: ActiveTripScreen(onFinished: _finishTrip),
      );
    }

    return Scaffold(
      body: SafeArea(bottom: false, child: _tabBody(flow)),
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
          onAccepted: _onOfferAccepted,
        );
      case 2:
        final earnings = _earningsFor(flow);
        return ChangeNotifierProvider<EarningsController>.value(
          value: earnings,
          child: const WalletScreen(),
        );
      default:
        return _Placeholder(title: _tabs[_tab]);
    }
  }

  EarningsController _earningsFor(DriverFlow flow) =>
      _earnings ??= EarningsController(flow.earnings);

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
    if (index == 2) _earningsFor(flow).load();
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

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.construction_outlined,
            size: 40,
            color: MngColors.divider,
          ),
          SizedBox(height: 12.h),
          Text(title, style: MngTheme.light.textTheme.titleMedium),
          SizedBox(height: 4.h),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 40.w),
            child: Text(
              'Not built yet. This round covers verification, going online, '
              'taking a trip and the earnings wallet.',
              textAlign: TextAlign.center,
              style: MngTheme.light.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
