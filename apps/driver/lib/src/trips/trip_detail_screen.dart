import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

import '../data/driver_trip.dart';
import '../map/driver_map_panel.dart';

/// One trip, in full.
///
/// Reached by tapping a row on the Trips tab, so it takes the record as an
/// argument and needs no provider and no read: the row it was opened from
/// already holds the whole row, and a detail screen that re-reads it can show
/// a different trip from the one that was tapped.
///
/// The rider's pickup code is deliberately not on this screen even though
/// `Trip` carries it. It is a one-shot secret, it is only ever read out at the
/// pickup, and a completed trip's history is the last place it should be.
class TripDetailScreen extends StatelessWidget {
  const TripDetailScreen({super.key, required this.record});

  final DriverTrip record;

  @override
  Widget build(BuildContext context) {
    final text = MngTheme.light.textTheme;
    final trip = record.trip;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: MngColors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Trip details', style: text.titleLarge),
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(20.w, 8.h, 20.w, 32.h),
          children: [
            DriverMapPanel(
              driverPoint: null,
              pickup: trip.pickup.point,
              dropoff: trip.dropoff.point,
              height: 200.h,
            ),
            SizedBox(height: 16.h),
            Container(
              padding: EdgeInsets.all(16.w),
              decoration: BoxDecoration(
                color: MngColors.surface,
                borderRadius: BorderRadius.circular(MngRadius.large),
                border: Border.all(color: MngColors.divider),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Line(
                    label: 'Fare earned',
                    value: 'GHS ${trip.fareGhs.toStringAsFixed(2)}',
                    valueKey: const Key('tripDetailFare'),
                    emphasise: true,
                  ),
                  _Line(
                    label: 'Status',
                    value: record.stateLabel,
                    valueKey: const Key('tripDetailState'),
                  ),
                  _Line(
                    label: 'Date',
                    value: record.dateLabel,
                    valueKey: const Key('tripDetailDate'),
                  ),
                  _Line(
                    label: 'Distance',
                    value: '${trip.distanceKm.toStringAsFixed(1)} km',
                    valueKey: const Key('tripDetailDistance'),
                  ),
                  _Line(
                    label: 'Category',
                    value: trip.category.label,
                    valueKey: const Key('tripDetailCategory'),
                  ),
                ],
              ),
            ),
            SizedBox(height: 12.h),
            _Stop(
              icon: Icons.trip_origin,
              color: MngColors.primary,
              title: trip.pickup.label,
              address: trip.pickup.address,
              titleKey: const Key('tripDetailPickup'),
            ),
            _Stop(
              icon: Icons.place,
              color: MngColors.success,
              title: trip.dropoff.label,
              address: trip.dropoff.address,
              titleKey: const Key('tripDetailDropoff'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({
    required this.label,
    required this.value,
    required this.valueKey,
    this.emphasise = false,
  });

  final String label;
  final String value;
  final Key valueKey;
  final bool emphasise;

  @override
  Widget build(BuildContext context) {
    final text = MngTheme.light.textTheme;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 6.h),
      child: Row(
        children: [
          Flexible(
            child: Text(label, style: text.bodySmall),
          ),
          SizedBox(width: 12.w),
          Flexible(
            child: Text(
              value,
              key: valueKey,
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
              style: emphasise ? text.titleMedium : text.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _Stop extends StatelessWidget {
  const _Stop({
    required this.icon,
    required this.color,
    required this.title,
    required this.address,
    required this.titleKey,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String address;
  final Key titleKey;

  @override
  Widget build(BuildContext context) {
    final text = MngTheme.light.textTheme;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 8.h),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, key: titleKey, style: text.titleMedium),
                SizedBox(height: 2.h),
                Text(address, style: text.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
