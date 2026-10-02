import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

import '../data/booked_trip.dart';
import '../map/ride_map.dart';
import '../data/trip_report_repository.dart';
import '../report/report_problem_sheet.dart';
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
  const TripDetailScreen({
    super.key,
    required this.ride,
    this.reports,
    this.existingReport,
  });

  final BookedTrip ride;

  /// Where a report goes, or null when this build has nowhere to send one.
  ///
  /// Null hides the button rather than showing a dead one. Every button on this
  /// screen that used to be decorative has been wired, and the one lesson from
  /// that run is that a live-looking control which does nothing is worse than
  /// an absent one.
  final TripReportRepository? reports;

  /// What this rider already reported, so the button can offer to add to it.
  final RideReport? existingReport;

  /// Whether this ride is finished enough to report on.
  ///
  /// The same rule as `trips_can_be_reported` in the database, which is the
  /// authority. Checked here only so the button is not offered on a ride it would
  /// be refused for.
  bool get _canReport {
    final state = ride.trip.state;
    return state == TripState.completed || state == TripState.cancelled;
  }

  @override
  Widget build(BuildContext context) {
    final trip = ride.trip;
    final theme = MngTheme.light.textTheme;
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
            // Report a problem, on a **finished** ride only.
            //
            // Mid-ride a rider has the SOS button and the driver's number, and a
            // support ticket raised while the car is still arriving is something
            // nobody reads until it is over. The database says the same thing --
            // `trips_can_be_reported` refuses anything not `completed` or
            // `cancelled` -- so the button and the rule cannot disagree, and a
            // rider who got here through the home list rather than a live ride
            // sees no dead control.
            if (_canReport && reports != null) ...[
              SizedBox(height: 16.h),
              if (existingReport != null) ...[
                Container(
                  key: const Key('alreadyReported'),
                  width: double.infinity,
                  padding: EdgeInsets.all(12.w),
                  decoration: BoxDecoration(
                    color: MngColors.muted,
                    borderRadius: BorderRadius.circular(MngRadius.large),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('You reported this', style: theme.bodySmall),
                      SizedBox(height: 2.h),
                      Text(existingReport!.reason, style: theme.titleSmall),
                    ],
                  ),
                ),
                SizedBox(height: 10.h),
              ],
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  key: const Key('reportProblemButton'),
                  onPressed: () => ReportProblemSheet.show(
                    context,
                    tripId: trip.id,
                    repository: reports!,
                    existing: existingReport,
                  ),
                  icon: const Icon(Icons.flag_outlined),
                  label: Text(
                    existingReport == null
                        ? 'Report a problem'
                        : 'Add to your report',
                  ),
                ),
              ),
            ],
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
