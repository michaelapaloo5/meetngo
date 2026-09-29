import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

import '../auth/auth_controller.dart';
import '../booking/choose_car_screen.dart';
import '../booking/destination_search_page.dart';
import '../booking/route_confirm_page.dart';
import '../bookings/bookings_controller.dart';
import '../bookings/bookings_screen.dart';
import '../chat/chat_controller.dart';
import '../chat/chat_screen.dart';
import '../data/chat_repository.dart';
import '../data/booked_trip.dart';
import '../data/location_service.dart';
import '../data/place_service.dart';
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

  /// The place name for [_location], once a geocoder has answered.
  ///
  /// Held in the shell rather than read inside [HomeScreen] so the home screen
  /// stays a pure view with no network in it, and so a failed lookup costs the
  /// rider nothing: the screen falls back to the coordinates it already has.
  PlaceName? _place;

  static const _tabs = ['Home', 'Bookings', 'Chat', 'Profile'];

  @override
  void initState() {
    super.initState();
    // Asked here rather than on the first tap, because the home screen now
    // shows the rider's position under the greeting. It used to print a
    // hard-coded 'Osu, Accra, Ghana' there instead, so nothing needed this
    // before and the rider was never asked.
    _readLocation();
    // Recent rides are read on arrival, not only on the way past from a
    // booking. They used to be loaded in `_openRouteEntry` alone, which meant
    // that a rider who opened the app and looked at the home screen -- the
    // first thing every returning rider does -- saw no history at all until
    // they had booked something. The section the home screen is built around
    // was empty on a cold start, for a rider who had five trips on file.
    //
    // A failure leaves it null, which draws nothing: an empty list of past
    // rides is not worth an error message on a screen whose job is booking one.
    unawaited(_loadRecentRides());
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
    // Named second and separately, so a slow or refused geocoder never delays
    // the position the rider can already see. A null answer is normal and is
    // not an error: the home line falls back to coordinates.
    await _readPlace(reading);
  }

  Future<void> _readPlace(DeviceLocation reading) async {
    final point = reading.point;
    if (point == null) return;
    final place = await context.read<PlaceService>().reverse(point);
    if (!mounted) return;
    setState(() => _place = place);
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

  Future<void> _openRouteEntry({bool promo = false}) async {
    final flow = context.read<RiderFlow>();
    // Asked for before the page opens rather than inside it, so the permission
    // dialog is not stacked under a pushed route on Android. A rider who says
    // no still gets the flow, with `kDefaultPickup` and the note that explains
    // why -- the search never blocks on this.
    final reading = await context.read<TripRepository>().locate();
    if (!mounted) return;
    setState(() => _location = reading);
    _locating = false;

    // Step one: where are you going. A whole screen, a search field focused on
    // arrival, and a full-width list. This replaces a modal sheet that asked for
    // two stops, a tier and a fare at once over a map the rider could not move.
    final destination = await Navigator.of(context).push<PlaceSuggestion>(
      MaterialPageRoute<PlaceSuggestion>(
        builder: (_) => DestinationSearchPage(
          places: context.read<PlaceService>(),
          recent: _recentDestinations(),
        ),
      ),
    );
    if (destination == null || !mounted) {
      unawaited(_loadRecentRides());
      return;
    }

    // Step two: confirm the route and the tier.
    final draft = await pushRouteConfirmPage(
      context,
      calc: flow.calc,
      places: context.read<PlaceService>(),
      pickup: reading.point == null
          ? null
          : pickupFromFix(reading.point!, label: _place?.line),
      dropoff: TripStop('Dropoff', destination.point, destination.label),
      promoApplied: promo,
      onSubmit: _openCarChoice,
    );

    // Read the rider's history on the way past, so Recent rides on the home
    // screen is populated by the time they get back to it. A failure leaves it
    // null, which draws nothing -- an empty list of past rides is not worth an
    // error message on a screen whose job is booking one.
    unawaited(_loadRecentRides());
    // `draft` is unused here on purpose: `onSubmit` already advanced the flow,
    // and the pop value exists for a caller that wants to chain without a
    // callback. Assigning it would be a statement about nothing.
    assert(draft == null || draft.dropoff.address == destination.label);
  }

  /// Destinations this rider has actually been to, newest first, deduplicated.
  ///
  /// Real trips and nothing else. The alternative for an empty search is a
  /// "popular destinations" list, which in a pilot with a handful of drivers
  /// would be a set of places nobody in the pilot has ever ridden to -- the
  /// same invention as the four fake cars, wearing a different hat.
  List<PlaceSuggestion> _recentDestinations() {
    final seen = <String>{};
    final out = <PlaceSuggestion>[];
    for (final ride in _recentRides ?? const <BookedTrip>[]) {
      final address = ride.trip.dropoff.address.trim();
      if (address.isEmpty || !seen.add(address)) continue;
      out.add(PlaceSuggestion(label: address, point: ride.trip.dropoff.point));
      if (out.length >= 5) break;
    }
    return out;
  }

  Future<void> _loadRecentRides() async {
    try {
      final rows = await context.read<TripRepository>().history(limit: 5);
      if (!mounted) return;
      setState(() => _recentRides = rows);
    } on Object {
      // Left null. The screen draws nothing for null and nothing for empty, so
      // a failed history read is invisible rather than alarming.
    }
  }

  Future<void> _openCarChoice(RouteDraft draft) async {
    if (!mounted) return;
    final calc = context.read<RiderFlow>().calc;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChooseCarScreen(
          calc: calc,
          selected: draft.category,
          onCategory: (_) {},
          onConfirm: (_) => _requestRide(draft),
          distanceKm: draft.pickup.point.distanceKmTo(draft.dropoff.point),
        ),
      ),
    );
  }

  Future<void> _requestRide(RouteDraft draft) async {
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
        place: _place,
        recentRides: _recentRides,
        onSearchTap: (_, {bool promo = false}) =>
            _openRouteEntry(promo: promo),
        onNotificationsTap: (_) => _openNotifications(),
      );

  /// The rider's last few trips for the home screen.
  ///
  /// Loaded once, alongside the position, and deliberately not watched. The
  /// home screen is not the bookings tab: a rider who has finished a ride should
  /// see it appear in Recent rides, and a rider who has not scrolled away from
  /// the home screen does not need the list rebuilt on every keystroke in a
  /// search field.
  List<BookedTrip>? _recentRides;

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
