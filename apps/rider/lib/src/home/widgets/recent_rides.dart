import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

import '../../data/booked_trip.dart';
import '../../trip/trip_copy.dart';

/// The rider's own last few trips, under the search field.
///
/// These are rows from `trips` -- rides that actually happened, with the address
/// the rider booked and the fare the server settled. They are what belongs on
/// the home screen, and they replace a list of four invented cars that sat in
/// the same space.
///
/// Nothing is drawn for a rider who has never booked, and nothing is drawn while
/// the first read is in flight: a "Recent rides" heading over an empty list is
/// a promise the app has not kept yet, and the space is better left empty than
/// filled with a message about having nothing.
class RecentRides extends StatelessWidget {
  const RecentRides({super.key, required this.rides, this.onOpen});

  /// Newest first, already limited by the caller. Capped again here so a
  /// caller that forgets cannot put a hundred rows on the home screen.
  final List<BookedTrip> rides;

  final void Function(BookedTrip ride)? onOpen;

  /// Five is a screenful on a 390-wide phone and still reads as "recent" rather
  /// than as a history.
  static const int kMaxShown = 5;

  @override
  Widget build(BuildContext context) {
    if (rides.isEmpty) return const SizedBox.shrink();
    final shown = rides.take(kMaxShown).toList();
    return Column(
      key: const Key('recentRides'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Recent rides',
          style: MngTheme.light.textTheme.titleMedium,
        ),
        SizedBox(height: 8.h),
        for (final ride in shown)
          Padding(
            padding: EdgeInsets.only(bottom: 8.h),
            child: _RideRow(ride: ride, onTap: onOpen),
          ),
      ],
    );
  }
}

class _RideRow extends StatelessWidget {
  const _RideRow({required this.ride, this.onTap});

  final BookedTrip ride;
  final void Function(BookedTrip ride)? onTap;

  @override
  Widget build(BuildContext context) {
    final trip = ride.trip;
    // A coordinate is never shown. Trips booked before the build that stopped
    // writing them have one stored in the pickup address, and a rider scanning
    // their own history is exactly the person who cannot read "5.5879, -0.2204"
    // as "where I was picked up". Those rows fall back to the stop's label.
    final from = addressForDisplay(
      trip.pickup.address,
      trip.pickup.label.trim().isEmpty ? 'Pickup' : trip.pickup.label,
    );
    final to = addressForDisplay(
      trip.dropoff.address,
      trip.dropoff.label.trim().isEmpty ? 'Drop-off' : trip.dropoff.label,
    );
    // A place to be picked up from is the one thing that makes a past trip
    // recognisable, so that leads; the destination is the fallback when the
    // pickup is a coordinate.
    final line = from == 'Pickup' && to != 'Drop-off' ? to : '$from to $to';

    return GestureDetector(
      key: Key('recentRide-${trip.id}'),
      onTap: onTap == null ? null : () => onTap!(ride),
      child: Container(
        padding: EdgeInsets.all(12.w),
        decoration: BoxDecoration(
          color: MngColors.surface,
          borderRadius: BorderRadius.circular(MngRadius.small),
          border: Border.all(color: MngColors.divider),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: MngColors.muted,
                shape: BoxShape.circle,
              ),
              child: Icon(
                _iconFor(trip.state),
                size: 18,
                color: MngColors.textSub,
              ),
            ),
            SizedBox(width: 12.w),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    line,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: MngTheme.light.textTheme.bodyMedium,
                  ),
                  SizedBox(height: 2.h),
                  Text(
                    '${_when(ride.createdAt)}  ·  '
                    'GHS ${trip.fareGhs.toStringAsFixed(2)}',
                    style: MngTheme.light.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Relative for anything recent, absolute after a week.
  ///
  /// "2 days ago" is what a rider recognises; "2026-09-28" is what a database
  /// recognises. A five-row list mixing the two reads as noise.
  static String _when(DateTime at) {
    final delta = DateTime.now().difference(at);
    if (delta.inMinutes < 1) return 'Just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
    if (delta.inHours < 24) {
      return '${delta.inHours} hour${delta.inHours == 1 ? '' : 's'} ago';
    }
    if (delta.inDays < 7) {
      return '${delta.inDays} day${delta.inDays == 1 ? '' : 's'} ago';
    }
    return '${at.day}/${at.month}/${at.year}';
  }

  static IconData _iconFor(TripState state) => switch (state) {
        TripState.cancelled => Icons.close,
        TripState.completed => Icons.check,
        _ => Icons.directions_car,
      };
}
