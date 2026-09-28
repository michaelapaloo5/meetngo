import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

import '../auth/auth_controller.dart';
import '../booking/choose_car_screen.dart';
import '../booking/route_entry_sheet.dart';
import '../bookings/bookings_controller.dart';
import '../bookings/bookings_screen.dart';
import '../chat/chat_controller.dart';
import '../chat/chat_screen.dart';
import '../data/chat_repository.dart';
import '../data/location_service.dart';
import '../data/profile_repository.dart';
import '../data/trip_repository.dart';
import '../home/home_screen.dart';
import '../home/notifications_screen.dart';
import '../profile/profile_controller.dart';
import '../profile/profile_screen.dart';
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

  /// The rider's own position for the home line and the two map screens, read
  /// once on launch and again when the search sheet opens and when a trip is
  /// booked. Held rather than read inside the screens so a rider who declined
  /// permission sees the same sentence everywhere, instead of one screen
  /// explaining itself and the other being silent about it.
  DeviceLocation? _location;

  /// Whether a read is already in flight, so the launch read and a later
  /// search-tap read do not both fire for one visit.
  bool _locating = false;

  static const _tabs = ['Home', 'Bookings', 'Chat', 'Profile'];

  @override
  void initState() {
    super.initState();
    // Asked here rather than on the first tap, because the home screen now
    // shows the rider's position under the greeting. It used to print a
    // hard-coded 'Osu, Accra, Ghana' there instead, so nothing needed this
    // before and the rider was never asked.
    _readLocation();
  }

  Future<void> _readLocation() async {
    if (_locating || _location != null) return;
    _locating = true;
    final reading = await context.read<TripRepository>().locate();
    if (!mounted) return;
    setState(() {
      _location = reading;
      _locating = false;
    });
  }

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
    // Asked for before the sheet opens rather than inside it, so the permission
    // dialog is not stacked under a modal bottom sheet on Android. A rider who
    // says no still gets the sheet, with `kDefaultPickup` and the note that
    // explains why — the sheet never blocks on this.
    final reading = await context.read<TripRepository>().locate();
    if (!mounted) return;
    setState(() => _location = reading);
    _locating = false;
    await showRouteEntrySheet(
      context,
      calc: flow.calc,
      pickup: reading.point == null ? null : pickupFromFix(reading.point!),
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
        location: _location,
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

  /// One of the four tabs, each with its own controller created here rather
  /// than in `main.dart`.
  ///
  /// The repositories are app-wide, so they are provided once at the root. The
  /// three per-screen controllers are not: each one owns a screen's own
  /// loading state, and a single instance shared between two mounted copies of
  /// the same tab would leave a stale list behind every time the tab was
  /// rebuilt. They are also disposed with the tab, which is what stops a
  /// bookings list from still holding yesterday's rows the moment the rider
  /// signs out.
  Widget _tabBody() {
    switch (_tab) {
      case 0:
        return _home();
      case 1:
        return ChangeNotifierProvider<BookingsController>(
          create: (c) => BookingsController(c.read<TripRepository>()),
          child: const BookingsScreen(),
        );
      case 2:
        return ChangeNotifierProvider<ChatController>(
          create: (c) => ChatController(
            trips: c.read<TripRepository>(),
            chat: c.read<ChatRepository>(),
          )..selfId = c.read<AuthController>().uid,
          child: const ChatScreen(),
        );
      case 3:
        return ChangeNotifierProvider<RiderProfileController>(
          create: (c) => RiderProfileController(c.read<ProfileRepository>()),
          child: const ProfileScreen(),
        );
      // The nav builds an index from `_tabs` and nothing else assigns `_tab`,
      // so this is unreachable. It falls back to home rather than throwing: a
      // shell that dies on an impossible value takes the rider's session with
      // it, and home is the one body that needs no provider of its own.
      default:
        return _home();
    }
  }

  Widget _home() => HomeScreen(
        riderName: context.watch<RiderProfileController>().greetingName,
        promoCode: kPromoCode,
        location: _location,
        onSearchTap: (_) => _openRouteEntry(),
        onNotificationsTap: (_) => _openNotifications(),
      );

  Future<void> _openNotifications() async {
    // Pushed with a bookings controller of its own rather than reusing the one
    // the Bookings tab would build, so the list is read fresh when the bell is
    // pressed and is not left holding whatever the bookings tab last fetched.
    final bookings = BookingsController(context.read<TripRepository>())..load();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChangeNotifierProvider<BookingsController>.value(
          value: bookings,
          child: const NotificationsScreen(),
        ),
      ),
    );
    bookings.dispose();
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
