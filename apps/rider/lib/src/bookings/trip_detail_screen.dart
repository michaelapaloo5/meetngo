import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

import '../data/booked_trip.dart';
import '../map/fullscreen_ride_map_screen.dart';
import '../map/ride_map.dart';
import '../map/rider_route_map.dart';
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
class TripDetailScreen extends StatefulWidget {
  const TripDetailScreen({
    super.key,
    required this.ride,
    required this.reports,
  });

  final BookedTrip ride;

  /// Where a report goes.
  ///
  /// **Required, and that is the point.** It was optional at first, and the row
  /// in `BookingsScreen` did not pass it -- so the report button silently did not
  /// exist on the most obvious way into this screen. Every decorative button in
  /// the rider app has already been found and either wired or removed once; the
  /// least useful thing this code could do is add another one that compiles. A
  /// required parameter makes every call site state where reports go.
  final TripReportRepository reports;

  @override
  State<TripDetailScreen> createState() => _TripDetailScreenState();
}

class _TripDetailScreenState extends State<TripDetailScreen> {
  /// What this rider already reported about this ride, if anything.
  RideReport? _existing;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  /// Asks whether there is already a report, so the button can offer to add to it
  /// instead of inviting a second one about the same journey.
  ///
  /// Fetched here rather than handed in, which is what keeps [TripDetailScreen]
  /// down to one thing a caller must supply. The previous version took the
  /// existing report as a second optional parameter; every call site then had two
  /// chances to forget something, and one of them did.
  Future<void> _loadExisting() async {
    if (!_canReport) return;
    final found = await widget.reports.reportFor(widget.ride.trip.id);
    if (!mounted) return;
    setState(() => _existing = found);
  }

  /// Whether this ride is finished enough to report on.
  ///
  /// The same rule as `trips_can_be_reported` in the database, which is the
  /// authority. Checked here only so the button is not offered on a ride it would
  /// be refused for.
  bool get _canReport {
    final state = widget.ride.trip.state;
    return state == TripState.completed || state == TripState.cancelled;
  }

  @override
  Widget build(BuildContext context) {
    final ride = widget.ride;
    final reports = widget.reports;
    final existingReport = _existing;
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
            // The road, not a line between two pins. A past ride is the one place
            // a rider is asking "where *was* that?", and a straight line through
            // blocks answers a different question from the one they asked.
            RiderRouteMap(
              from: trip.pickup.point,
              to: trip.dropoff.point,
              builder: (context, shape) => RideMap(
                pickup: trip.pickup.point,
                dropoff: trip.dropoff.point,
                routeShape: shape,
                // On a past ride the rider is asking "where was that?", and a bare
                // coloured dot cannot answer it. The names are what they are
                // looking for.
                pickupLabel: stopLabel(trip.pickup),
                dropoffLabel: stopLabel(trip.dropoff),
                height: 200,
                // **Tappable, which it was not.** A rider who opens a past ride to
                // see where they went could not do anything with the map at all --
                // no tap, no drag, no way in. It was a picture.
                //
                // Tap to expand, not gestures on. This map is a 200px card inside a
                // `ListView`, and turning the map's own gestures on means a drag
                // over it moves the map instead of scrolling the list, which puts
                // everything below the card -- the fare, the category, the report
                // button -- out of reach. The same reasoning already governs the
                // tracking screen's map, and this is the same shape of problem, so
                // this is the same answer: the tap is the way past it, and the
                // larger map has the gestures and the recentre button.
                onTapToExpand: () => FullscreenRideMapScreen.show(
                  context,
                  pickup: trip.pickup.point,
                  pickupLabel: stopLabel(trip.pickup),
                  dropoff: trip.dropoff.point,
                  dropoffLabel: stopLabel(trip.dropoff),
                ),
              ),
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
            // `cancelled` -- so the button and the rule cannot disagree.
            //
            // Shown on both routes into this screen, because the repository is a
            // required argument rather than an optional one.
            if (_canReport) ...[
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
                      Text(existingReport.reason, style: theme.titleSmall),
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
                    repository: reports,
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
