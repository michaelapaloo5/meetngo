import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

import '../data/driver_trip.dart';
import 'trip_detail_screen.dart';
import 'trips_controller.dart';

/// The Trips tab: every trip this driver has driven.
///
/// The controller is read from the provider the shell registers, exactly as
/// `WalletScreen` reads `EarningsController`, so the list survives a tab switch
/// and a rebuild does not start a second read.
class TripsScreen extends StatelessWidget {
  const TripsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<TripsController>();
    return Scaffold(
      appBar: AppBar(
        backgroundColor: MngColors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Your trips', style: MngTheme.light.textTheme.titleLarge),
      ),
      body: SafeArea(child: _body(context, controller)),
    );
  }

  Widget _body(BuildContext context, TripsController controller) {
    if (controller.error != null) {
      return _Notice(
        key: const Key('tripsError'),
        icon: Icons.cloud_off_outlined,
        message: controller.error!,
        onRetry: controller.load,
      );
    }
    if (controller.trips.isEmpty) {
      if (!controller.loadedOnce) {
        return const Center(
          key: Key('tripsLoading'),
          child: CircularProgressIndicator(),
        );
      }
      return const _Notice(
        key: Key('tripsEmptyState'),
        icon: Icons.route_outlined,
        message: 'No trips yet. Go online and the first one will show up here.',
      );
    }
    return RefreshIndicator(
      onRefresh: controller.load,
      child: ListView.builder(
        key: const Key('tripsList'),
        padding: EdgeInsets.fromLTRB(20.w, 4.h, 20.w, 20.h),
        itemCount: controller.trips.length,
        itemBuilder: (context, index) {
          final record = controller.trips[index];
          return _TripRow(
            record: record,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => TripDetailScreen(record: record),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _TripRow extends StatelessWidget {
  const _TripRow({required this.record, required this.onTap});

  final DriverTrip record;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = MngTheme.light.textTheme;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 6.h),
      child: Material(
        color: MngColors.surface,
        borderRadius: BorderRadius.circular(MngRadius.large),
        child: InkWell(
          key: Key('tripRow-${record.id}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(MngRadius.large),
          child: Container(
            padding: EdgeInsets.all(16.w),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(MngRadius.large),
              border: Border.all(color: MngColors.divider),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        'GHS ${record.trip.fareGhs.toStringAsFixed(2)}',
                        overflow: TextOverflow.ellipsis,
                        style: text.titleMedium,
                      ),
                    ),
                    SizedBox(width: 8.w),
                    // `Flexible` out here, on the row, not inside the pill: the
                    // pill is a `Container`, and a `Flexible` inside one has no
                    // `Flex` ancestor to apply its parent data to. This is what
                    // gives the pill a bounded width so its label can ellipsize
                    // rather than overflow a long state name.
                    Flexible(
                      child: _StatePill(
                        label: record.stateLabel,
                        state: record.trip.state,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 10.h),
                _Leg(
                  icon: Icons.trip_origin,
                  color: MngColors.primary,
                  text: record.trip.pickup.label,
                ),
                SizedBox(height: 6.h),
                _Leg(
                  icon: Icons.place,
                  color: MngColors.success,
                  text: record.trip.dropoff.label,
                ),
                SizedBox(height: 10.h),
                Text(record.dateLabel, style: text.bodySmall),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Leg extends StatelessWidget {
  const _Leg({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: color),
        SizedBox(width: 8.w),
        // `Flexible` rather than `Expanded`: a long place name ellipsizes
        // instead of wrapping to a second line and doubling the row's height
        // mid-list, which pushed rows off the bottom of the screen.
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: MngTheme.light.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _StatePill extends StatelessWidget {
  const _StatePill({required this.label, required this.state});

  final String label;
  final TripState state;

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      TripState.completed => MngColors.success,
      TripState.cancelled => MngColors.error,
      _ => MngColors.primary,
    };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
      decoration: BoxDecoration(
        color: MngColors.muted,
        borderRadius: BorderRadius.circular(MngRadius.small),
        border: Border.all(color: color),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: MngTheme.light.textTheme.bodySmall?.copyWith(color: color),
      ),
    );
  }
}

/// The empty, failed and "not yet loaded" states, in one shape.
///
/// All three are a full-width message rather than a centred icon over blank
/// space, because each of them is a sentence the driver has to act on, and the
/// actions differ: a failed read is worth retrying and an empty history is not.
class _Notice extends StatelessWidget {
  const _Notice({
    super.key,
    required this.icon,
    required this.message,
    this.onRetry,
  });

  final IconData icon;
  final String message;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 32.w),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 32, color: MngColors.textSub),
            SizedBox(height: 12.h),
            Text(
              message,
              textAlign: TextAlign.center,
              style: MngTheme.light.textTheme.bodySmall,
            ),
            if (onRetry != null) ...[
              SizedBox(height: 16.h),
              OutlinedButton(
                key: const Key('tripsRetry'),
                onPressed: onRetry,
                child: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
