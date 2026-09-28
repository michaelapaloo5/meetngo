import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

import '../data/booked_trip.dart';
import '../trip/trip_copy.dart';
import 'bookings_controller.dart';
import 'trip_detail_screen.dart';

/// The rider's own rides, newest first.
///
/// Replaces the `_Placeholder` that stood in for the Bookings tab. Every row is
/// a real row from `trips` where `rider_id = auth.uid()`; there is no seed data
/// behind this list, which is why the empty state says "No rides yet" rather
/// than offering sample trips.
class BookingsScreen extends StatefulWidget {
  const BookingsScreen({super.key});

  @override
  State<BookingsScreen> createState() => _BookingsScreenState();
}

class _BookingsScreenState extends State<BookingsScreen> {
  @override
  void initState() {
    super.initState();
    // After the first frame, so `context.read` inside the controller's own
    // load cannot race the provider being torn down with this element.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<BookingsController>().load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<BookingsController>();
    return Scaffold(
      appBar: AppBar(
        backgroundColor: MngColors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('Your rides'),
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: c.load,
          child: _body(c),
        ),
      ),
    );
  }

  Widget _body(BookingsController c) {
    if (c.state == BookingsStatus.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (c.state == BookingsStatus.failed) {
      return _Message(
        icon: Icons.cloud_off_outlined,
        title: 'Your rides did not load',
        body: c.error ?? 'Could not reach the server',
        onRetry: c.load,
      );
    }
    if (c.trips.isEmpty) {
      return const _Message(
        icon: Icons.route_outlined,
        title: 'No rides yet',
        body: 'When you book a ride it will appear here, newest first.',
      );
    }
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(20.w, 8.h, 20.w, 24.h),
      itemCount: c.trips.length,
      separatorBuilder: (_, _) => SizedBox(height: 12.h),
      itemBuilder: (context, i) => TripRow(ride: c.trips[i]),
    );
  }
}

/// One ride in the list.
///
/// Reads the trip's own addresses, fare and state rather than anything the
/// caller supplies, so a row cannot drift from the trip it represents.
class TripRow extends StatelessWidget {
  const TripRow({super.key, required this.ride});

  final BookedTrip ride;

  @override
  Widget build(BuildContext context) {
    final trip = ride.trip;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TripDetailScreen(ride: ride),
        ),
      ),
      child: Container(
        key: Key('tripRow-${ride.id}'),
        padding: EdgeInsets.all(16.w),
        decoration: BoxDecoration(
          color: MngColors.surface,
          borderRadius: BorderRadius.circular(MngRadius.large),
          border: Border.all(color: MngColors.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    tripStateLabel(trip.state),
                    overflow: TextOverflow.ellipsis,
                    style: MngTheme.light.textTheme.titleMedium,
                  ),
                ),
                SizedBox(width: 8.w),
                TripStateBadge(state: trip.state),
              ],
            ),
            SizedBox(height: 12.h),
            _Route(
              icon: Icons.circle,
              iconSize: 10,
              iconColor: MngColors.success,
              text: stopLabel(trip.pickup),
            ),
            SizedBox(height: 8.h),
            _Route(
              icon: Icons.place,
              iconSize: 12,
              iconColor: MngColors.error,
              text: stopLabel(trip.dropoff),
            ),
            SizedBox(height: 12.h),
            Row(
              children: [
                Expanded(
                  child: Text(
                    formatGhs(trip.fareGhs),
                    style: MngTheme.light.textTheme.titleMedium,
                  ),
                ),
                Text(
                  formatTripMoment(ride.createdAt),
                  style: MngTheme.light.textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The filled pill that tells a completed ride from one still running.
class TripStateBadge extends StatelessWidget {
  const TripStateBadge({super.key, required this.state});

  final TripState state;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('stateBadge-${state.name}'),
      padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
      decoration: BoxDecoration(
        color: tripStateColor(state),
        borderRadius: BorderRadius.circular(MngRadius.small),
      ),
      child: Text(
        state.isActive ? 'Live' : 'Done',
        style: MngTheme.light.textTheme.bodySmall?.copyWith(
          color: tripStateTextColor(state),
          fontSize: 11.sp,
        ),
      ),
    );
  }
}

class _Route extends StatelessWidget {
  const _Route({
    required this.icon,
    required this.iconSize,
    required this.iconColor,
    required this.text,
  });

  final IconData icon;
  final double iconSize;
  final Color iconColor;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: iconSize, color: iconColor),
        SizedBox(width: 10.w),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: MngTheme.light.textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }
}

/// What every non-list state of this screen renders.
///
/// One widget for the empty and failed cases so neither can be a bare `Text`
/// with no padding, and so the failed case cannot be produced by forgetting a
/// message: [body] is required and [onRetry] is what decides whether a button
/// appears.
class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String body;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    // Inside a RefreshIndicator, which needs a scrollable child to pull on.
    return ListView(
      padding: EdgeInsets.symmetric(horizontal: 32.w, vertical: 80.h),
      children: [
        Icon(icon, size: 40, color: MngColors.divider),
        SizedBox(height: 12.h),
        Text(
          title,
          textAlign: TextAlign.center,
          style: MngTheme.light.textTheme.titleMedium,
        ),
        SizedBox(height: 4.h),
        Text(
          body,
          textAlign: TextAlign.center,
          style: MngTheme.light.textTheme.bodySmall,
        ),
        if (onRetry != null) ...[
          SizedBox(height: 20.h),
          OutlinedButton(
            key: const Key('retryButton'),
            onPressed: onRetry,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            child: const Text('Try again'),
          ),
        ],
      ],
    );
  }
}

