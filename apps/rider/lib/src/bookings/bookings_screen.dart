import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

import '../data/booked_trip.dart';
import '../data/trip_report_repository.dart';
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
          // The chips sit above the list rather than inside it, so they stay put
          // when the rider scrolls and are reachable when the list is empty.
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _FilterChips(controller: c)),
              ..._rowsSlivers(c),
            ],
          ),
        ),
      ),
    );
  }

  /// The list, or whichever of the three empty/failed states applies.
  List<Widget> _rowsSlivers(BookingsController c) {
    if (c.state == BookingsStatus.loading) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (c.state == BookingsStatus.failed) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _Message(
            icon: Icons.cloud_off_outlined,
            title: 'Your rides did not load',
            body: c.error ?? 'Could not reach the server',
            onRetry: c.load,
          ),
        ),
      ];
    }
    if (c.trips.isEmpty) {
      // "No rides yet" is only true when no filter is on. With "Cancelled"
      // selected and nothing cancelled, that sentence tells a rider with 24
      // rides that they have none, and they would act on it. The filtered case
      // names the filter and offers the way back instead.
      final filtered = !c.filter.sameAs(BookingsFilters.all);
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _Message(
            icon: filtered
                ? Icons.filter_alt_off_outlined
                : Icons.route_outlined,
            title: filtered
                ? 'No ${c.filter.label.toLowerCase()} rides'
                : 'No rides yet',
            body: filtered
                ? 'You have other rides. This filter is showing none of them.'
                : 'When you book a ride it will appear here, newest first.',
            actionLabel: filtered ? 'Show all rides' : null,
            onAction: filtered ? () => c.setFilter(BookingsFilters.all) : null,
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(20.w, 4.h, 20.w, 24.h),
        sliver: SliverList.separated(
          itemCount: c.trips.length,
          separatorBuilder: (_, _) => SizedBox(height: 12.h),
          itemBuilder: (context, i) => TripRow(ride: c.trips[i]),
        ),
      ),
    ];
  }
}

/// The row of chips that narrows the list to one kind of ride.
///
/// Between them the chips are exhaustive over `TripState.values`: every state
/// that `isActive` is under "Live", and every finished state has its own chip. A
/// state with no chip would be a ride that exists and cannot be found, which is
/// worse than an extra chip. That is why "Live" is derived from the enum rather
/// than written out -- see `BookingsFilters.active`.
class _FilterChips extends StatelessWidget {
  const _FilterChips({required this.controller});

  final BookingsController controller;

  @override
  Widget build(BuildContext context) {
    final selected = controller.filter;
    return SizedBox(
      height: 52.h,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: 20.w),
        children: [
          for (final filter in BookingsFilters.offered)
            Padding(
              padding: EdgeInsets.only(right: 8.w),
              child: FilterChip(
                key: Key('filterChip-${filter.label}'),
                label: Text(filter.label),
                selected: filter.sameAs(selected),
                // Disabled while a read is in flight so the row cannot be
                // double-tapped into two overlapping requests. The controller
                // ignores the second tap regardless; this makes the state
                // visible rather than silent.
                onSelected: controller.loading
                    ? null
                    : (_) => controller.setFilter(filter),
              ),
            ),
        ],
      ),
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
          // Read here, at the tap, rather than passed in from the list: this is
          // the row's own navigation and the repository is one `context.read`
          // away. It has to be supplied -- `TripDetailScreen` requires it -- and
          // the point of a required argument is that this call site cannot
          // quietly leave the report button off the list.
          builder: (_) => TripDetailScreen(
            ride: ride,
            reports: context.read<TripReportRepository>(),
          ),
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
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String body;
  final Future<void> Function()? onRetry;

  /// A way out of the state that is not "try the same thing again".
  ///
  /// For a filtered list that matched nothing the answer is to remove the filter,
  /// and retrying the identical query would fail identically.
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    // Deliberately **not** a `ListView`.
    //
    // This used to be one, back when the screen's body was the list itself and
    // the `RefreshIndicator` needed a scrollable child. Now the state is a
    // `SliverFillRemaining` inside a `CustomScrollView`, and a `ListView` here is
    // a viewport inside a viewport: during layout Flutter asks the outer one for
    // its intrinsic height, which it refuses to compute because that would mean
    // instantiating every child -- `RenderViewport does not support returning
    // intrinsic dimensions`. Every empty state on this screen threw on its way
    // to the screen. Found by a test that tapped a filter matching nothing.
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 32.w, vertical: 60.h),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
          if (actionLabel != null) ...[
            SizedBox(height: 12.h),
            FilledButton(
              key: const Key('emptyStateAction'),
              onPressed: onAction,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}
