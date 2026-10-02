import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

import '../data/booked_trip.dart';
import '../map/ride_map.dart';
import '../trip/trip_copy.dart';
import 'bookings_screen.dart' show TripStateBadge;

/// One past ride, in full.
///
/// Opened by a row in `BookingsScreen`. Everything drawn here comes off the one
/// `trips` row the rider already owns: the map, both addresses, the fare, the
/// distance, the category and the moment it was booked.
///
/// What is deliberately *not* here is the driver's name and phone. `profiles`
/// has exactly one SELECT policy, `own profile` (`id = auth.uid()`), and the
/// database has no policy that would let a rider read the driver they were
/// assigned. The live tracking screen can show a driver because the app passes
/// one in; a ride that is over has no such caller. A detail page that said
/// "Driver details are not available for past trips" is honest, and a page
/// that invented a name is not — so the driver is left out rather than faked.
///
/// The pickup code is shown for the same reason it is on the tracking screen:
/// it is on the row, and a rider checking an old ride can see the four digits
/// that trip used.
class TripDetailScreen extends StatelessWidget {
  const TripDetailScreen({super.key, required this.ride});

  final BookedTrip ride;

  @override
  Widget build(BuildContext context) {
    final trip = ride.trip;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: MngColors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('Ride details'),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: EdgeInsets.fromLTRB(20.w, 8.h, 20.w, 24.h),
          children: [
            RideMap(
              pickup: trip.pickup.point,
              dropoff: trip.dropoff.point,
              // On a past ride the rider is asking "where was that?", and a bare
              // coloured dot cannot answer it. The names are what they are
              // looking for.
              pickupLabel: stopLabel(trip.pickup),
              dropoffLabel: stopLabel(trip.dropoff),
              height: 200,
            ),
            SizedBox(height: 20.h),
            Row(
              children: [
                Expanded(
                  child: Text(
                    tripStateLabel(trip.state),
                    style: MngTheme.light.textTheme.titleLarge,
                  ),
                ),
                TripStateBadge(state: trip.state),
              ],
            ),
            SizedBox(height: 4.h),
            Text(
              'Booked ${formatTripMoment(ride.createdAt)}',
              style: MngTheme.light.textTheme.bodySmall,
            ),
            SizedBox(height: 20.h),
            _Card(
              title: 'Route',
              children: [
                _Line(
                  icon: Icons.circle,
                  iconSize: 10,
                  iconColor: MngColors.success,
                  text: stopLabel(trip.pickup),
                ),
                SizedBox(height: 10.h),
                _Line(
                  icon: Icons.place,
                  iconSize: 14,
                  iconColor: MngColors.error,
                  text: stopLabel(trip.dropoff),
                ),
              ],
            ),
            SizedBox(height: 12.h),
            _Card(
              title: 'This ride',
              children: [
                _Fact(
                  label: 'Fare',
                  value: formatGhs(trip.fareGhs),
                  valueKey: const Key('fareValue'),
                ),
                _Fact(
                  label: 'Distance',
                  value: '${trip.distanceKm.toStringAsFixed(1)} km',
                ),
                _Fact(label: 'Category', value: trip.category.label),
                if (trip.pickupOtp != null)
                  _Fact(
                    label: 'Pickup code',
                    value: trip.pickupOtp!,
                    valueKey: const Key('pickupCodeValue'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(16.w),
      decoration: BoxDecoration(
        color: MngColors.surface,
        borderRadius: BorderRadius.circular(MngRadius.large),
        border: Border.all(color: MngColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: MngTheme.light.textTheme.titleMedium),
          SizedBox(height: 12.h),
          ...children,
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, this.valueKey});

  final String label;
  final String value;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: 8.h),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(label, style: MngTheme.light.textTheme.bodySmall),
          ),
          SizedBox(width: 12.w),
          Text(
            value,
            key: valueKey,
            textAlign: TextAlign.right,
            style: MngTheme.light.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({
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
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: iconSize, color: iconColor),
        SizedBox(width: 10.w),
        Expanded(child: Text(text, style: MngTheme.light.textTheme.bodyMedium)),
      ],
    );
  }
}
