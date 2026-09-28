import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

import '../booking/choose_car_screen.dart';
import '../booking/route_entry_sheet.dart';
import '../data/trip_repository.dart';
import '../home/home_screen.dart';
import '../tracking/finding_driver_screen.dart';
import '../tracking/tracking_controller.dart';
import '../tracking/tracking_screen.dart';
import '../trip/receipt_screen.dart';
import 'rider_flow.dart';

/// The rider app's frame: the four bottom-nav tabs and the ride flow that runs
/// over them.
///
/// The flow is a single linear path, so it is one `_stage` rather than a route
/// stack the rider can come back to. Pushing four screens onto a stack and
/// popping them by hand is where "the rider pressed back and the app tried to
/// cancel a finished trip" bugs come from; a stage that only ever moves
/// forward cannot.
class RiderShell extends StatefulWidget {
  const RiderShell({super.key});

  @override
  State<RiderShell> createState() => _RiderShellState();
}

enum _Stage { idle, finding, tracking }

class _RiderShellState extends State<RiderShell> {
  int _tab = 0;
  _Stage _stage = _Stage.idle;
  Trip? _trip;
  Timer? _poll;
  bool _completing = false;

  static const _tabs = ['Home', 'Bookings', 'Chat', 'Profile'];

  @override
  void dispose() {
    _stopPolling();
    super.dispose();
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  /// Polls the rider's active trip. `request-ride` writes the trip synchronously
  /// and a driver accepts on a different device, so the only way the rider
  /// learns about it is by asking again. Three seconds is short enough that the
  /// wait does not feel broken and long enough that a pilot on a poor connection
  /// is not hammering the API.
  void _startPolling() {
    _stopPolling();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _tick());
  }

  Future<void> _tick() async {
    final flow = context.read<RiderFlow>();
    final fresh = await flow.refreshActive();
    if (!mounted || fresh == null) return;
    if (_stage == _Stage.finding && fresh.hasDriver) {
      setState(() {
        _trip = fresh;
        _stage = _Stage.tracking;
      });
      _startPolling();
    } else if (_stage == _Stage.tracking && fresh.state == TripState.completed) {
      _stopPolling();
      await _openReceipt(fresh);
    } else if (_stage == _Stage.tracking) {
      setState(() => _trip = fresh);
    }
  }

  Future<void> _openRouteEntry() async {
    final flow = context.read<RiderFlow>();
    await showRouteEntrySheet(
      context,
      calc: flow.calc,
      onSubmit: (draft) => _openCarChoice(draft),
    );
  }

  Future<void> _openCarChoice(RouteDraft draft) async {
    if (!mounted) return;
    final calc = context.read<RiderFlow>().calc;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChooseCarScreen(
          vehicles: kNearbyVehicles,
          calc: calc,
          selected: draft.category,
          onCategory: (_) {},
          onSelect: (_) {},
          onConfirm: (vehicle) => _requestRide(draft, vehicle),
          distanceKm: draft.pickup.point.distanceKmTo(draft.dropoff.point),
        ),
      ),
    );
  }

  Future<void> _requestRide(RouteDraft draft, Vehicle vehicle) async {
    final flow = context.read<RiderFlow>();
    final navigator = Navigator.of(context);
    final trip = await flow.requestRide(draft);
    if (!mounted) return;
    if (trip == null) {
      _toast(flow.requestError ?? 'Could not book that ride');
      return;
    }
    setState(() {
      _trip = trip;
      _stage = _Stage.finding;
      _tab = 0;
    });
    navigator.pop();
    _startPolling();
  }

  Future<void> _openReceipt(Trip trip) async {
    if (_completing || !mounted) return;
    setState(() => _completing = true);
    final flow = context.read<RiderFlow>();
    final controller = flow.controller;
    await controller.complete();
    if (!mounted) return;
    final settlement = controller.settlement;
    final state = controller.paymentState;
    setState(() => _completing = false);
    if (settlement == null || state == null) {
      _toast(controller.error ?? 'The trip finished but the receipt did not load');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReceiptScreen(
          trip: trip,
          settlement: settlement,
          paymentState: state,
          onRated: (stars, comment) => controller.complete(
            stars: stars,
            comment: comment,
          ),
        ),
      ),
    );
    if (!mounted) return;
    _stopPolling();
    context.read<RiderFlow>().reset();
    setState(() {
      _trip = null;
      _stage = _Stage.idle;
    });
  }

  Future<void> _cancelTrip() async {
    final flow = context.read<RiderFlow>();
    final trip = _trip;
    if (trip == null) return;
    _stopPolling();
    try {
      await flow.trips.cancelTrip(trip.id);
    } on Object catch (e) {
      if (!mounted) return;
      _toast(e.toString());
      return;
    }
    if (!mounted) return;
    context.read<RiderFlow>().reset();
    setState(() {
      _trip = null;
      _stage = _Stage.idle;
    });
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final flow = context.watch<RiderFlow>();
    final trip = _trip;
    final busy = flow.requesting || _completing;

    final Widget body;
    if (busy) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_stage == _Stage.finding && trip != null) {
      body = FindingDriverScreen(
        trip: trip,
        onCancelSearch: _cancelTrip,
      );
    } else if (_stage == _Stage.tracking && trip != null) {
      body = ChangeNotifierProvider<TrackingController>(
        create: (_) => TrackingController(
          trips: context.read<TripRepository>(),
          initialTrip: trip,
        ),
        child: const TrackingScreen(),
      );
    } else {
      body = _tabBody();
    }

    return Scaffold(
      body: SafeArea(bottom: false, child: body),
      bottomNavigationBar: _stage == _Stage.idle ? _nav() : null,
    );
  }

  Widget _tabBody() {
    switch (_tab) {
      case 0:
        return HomeScreen(
          nearby: kNearbyVehicles,
          promoCode: kPromoCode,
          onSearchTap: (_) => _openRouteEntry(),
        );
      default:
        return _Placeholder(title: _tabs[_tab]);
    }
  }

  Widget _nav() {
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
                    onTap: () => setState(() => _tab = i),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _iconFor(i),
                          size: 22,
                          color: _tab == i ? MngColors.primary : MngColors.textSub,
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

  IconData _iconFor(int index) {
    const icons = [
      Icons.home_outlined,
      Icons.receipt_long_outlined,
      Icons.chat_bubble_outline,
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
          Text(
            title,
            style: MngTheme.light.textTheme.titleMedium,
          ),
          SizedBox(height: 4.h),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 40.w),
            child: Text(
              'Not built yet. This round covers signing in, booking a ride '
              'and taking the trip.',
              textAlign: TextAlign.center,
              style: MngTheme.light.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
