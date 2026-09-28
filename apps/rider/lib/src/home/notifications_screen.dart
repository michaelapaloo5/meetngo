import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

import '../bookings/bookings_controller.dart';
import '../data/booked_trip.dart';
import '../trip/trip_copy.dart';

/// What the home screen's bell opens.
///
/// There is no `notifications` table in this schema, and inventing a feed
/// would mean writing rows the rider never asked for. So this screen is driven
/// by the one thing that *is* real and *is* a thing a rider wants to be told
/// about: the state of their own `trips` rows. Every line is a trip the rider
/// booked, at the state the database last reported, with the moment it was
/// booked.
///
/// A rider with no trips gets "No notifications yet" rather than a spinner
/// that never resolves or an empty box with no explanation. That is the honest
/// empty state: there is genuinely nothing to report, and the screen says so.
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<BookingsController>();
    return Scaffold(
      appBar: AppBar(
        backgroundColor: MngColors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('Notifications'),
      ),
      body: SafeArea(
        top: false,
        child: _body(c),
      ),
    );
  }

  Widget _body(BookingsController c) {
    if (c.state == BookingsStatus.loading && c.trips.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (c.trips.isEmpty) {
      // The failure and the genuinely-empty case are told apart, because
      // "No notifications yet" over a dropped connection is a claim that
      // nothing has happened, and the rider may well have taken a ride.
      return _Notice(
        key: const Key('emptyNotifications'),
        icon: Icons.notifications_none,
        title: 'No notifications yet',
        body: c.state == BookingsStatus.failed
            ? c.error ?? 'Could not reach the server'
            : 'Updates about your rides will show up here.',
        onRetry: c.state == BookingsStatus.failed ? c.load : null,
      );
    }
    return RefreshIndicator(
      onRefresh: c.load,
      child: ListView.separated(
        padding: EdgeInsets.fromLTRB(20.w, 8.h, 20.w, 24.h),
        itemCount: c.trips.length,
        separatorBuilder: (_, _) => SizedBox(height: 10.h),
        itemBuilder: (context, i) => _Line(ride: c.trips[i]),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.ride});

  final BookedTrip ride;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('notification-${ride.id}'),
      padding: EdgeInsets.all(16.w),
      decoration: BoxDecoration(
        color: MngColors.surface,
        borderRadius: BorderRadius.circular(MngRadius.large),
        border: Border.all(color: MngColors.divider),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: MngColors.muted,
              shape: BoxShape.circle,
            ),
            child: Icon(_iconFor(ride.state), size: 18),
          ),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tripStateLabel(ride.state),
                  style: MngTheme.light.textTheme.titleMedium,
                ),
                SizedBox(height: 2.h),
                Text(
                  'To ${stopLabel(ride.dropoff)}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: MngTheme.light.textTheme.bodySmall,
                ),
                SizedBox(height: 4.h),
                Text(
                  formatTripMoment(ride.createdAt),
                  style: MngTheme.light.textTheme.bodySmall
                      ?.copyWith(fontSize: 11.sp),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static IconData _iconFor(TripState state) => switch (state) {
        TripState.requested => Icons.hourglass_empty,
        TripState.matched => Icons.person_pin_circle_outlined,
        TripState.arriving => Icons.directions_car,
        TripState.ongoing => Icons.navigation,
        TripState.completed => Icons.check_circle_outline,
        TripState.cancelled => Icons.cancel_outlined,
      };
}

class _Notice extends StatelessWidget {
  const _Notice({
    super.key,
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
