import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import '../data/location_service.dart';
import '../map/live_location_button.dart';
import '../map/ride_map.dart';

class FindingDriverScreen extends StatefulWidget {
  const FindingDriverScreen({
    super.key,
    required this.trip,
    required this.onCancelSearch,
    this.location,
  });

  final Trip trip;
  final VoidCallback onCancelSearch;

  /// The device fix, when there is one. Absent or refused still renders the
  /// map, centred on the pickup the rider actually booked, with a note saying
  /// why there is no blue dot — which is the point: a blank map and a map that
  /// is confidently somewhere else are both worse than a map that is right
  /// about the pickup and honest about the rider's own position.
  final DeviceLocation? location;

  // The `tileProvider` parameter that used to be here went with the 2D map; see
  // the note on `TrackingScreen`. Tests switch the engine off through
  // `RideMap.disabledForTest` instead of through a caller-supplied provider.

  @override
  State<FindingDriverScreen> createState() => _FindingDriverScreenState();
}

class _FindingDriverScreenState extends State<FindingDriverScreen> {
  /// Reaches the map's camera for the live-location button.
  ///
  /// A key rather than a controller passed down: MapLibre's controller only
  /// exists once the native view is built and lives inside `RideMap`, and a
  /// `GlobalKey` is the ordinary way for a parent to reach a child's controller
  /// without threading it through the layout between them.
  final GlobalKey<RideMapState> _mapKey = GlobalKey<RideMapState>();

  @override
  Widget build(BuildContext context) {
    final trip = widget.trip;
    final location = widget.location;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: MngColors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: const BackButton(),
        title: const Text('Finding a driver'),
      ),
      body: SafeArea(
        // The map is the screen. The searching copy sits on a card over the
        // bottom of it, the way every ride-hailing app does, rather than
        // pushing a 300px map into the top third of a column and leaving the
        // rider to look at a strip of city while the thing they care about --
        // where they are being collected from -- is 300px tall.
        child: Stack(
          children: [
            Positioned.fill(
              // The `KeyedSubtree` keeps the `findingMap` key that a test and
              // a screenshot look for, while the map itself takes the
              // `GlobalKey` the live-location button drives. A widget has one
              // key, so the two cannot both sit on the `RideMap`.
              child: KeyedSubtree(
                key: const Key('findingMap'),
                child: RideMap(
                  key: _mapKey,
                  pickup: trip.pickup.point,
                  location: location,
                  fill: true,
                  // On, because nothing on this screen scrolls. The card is a
                  // fixed overlay at the bottom, so a drag that reached it
                  // would not be stealing anyone's scroll, which is the reason
                  // the tracking screen's map has to leave its gestures off.
                  // Here they were previously off, which made the map look
                  // broken: a rider who panned and tilted it could not get
                  // back, and nothing on screen said the map was even movable.
                  interactive: true,
                ),
              ),
            ),
            // The live-location button, over the map. Only drawn with a fix.
            Positioned.fill(
              child: LiveLocationButton(
                mapKey: _mapKey,
                point: location?.point,
              ),
            ),
            // The card. `Container` with a surface colour rather than
            // transparency, so the copy is readable over any part of the map
            // and the rider is never squinting at dark parkland.
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.fromLTRB(20.w, 20.h, 20.w, 20.h),
                decoration: BoxDecoration(
                  color: MngColors.page,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(24),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: MngColors.divider,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    SizedBox(height: 16.h),
                    Text(
                      'Asking ${trip.category.label} drivers near you',
                      style: MngTheme.light.textTheme.titleMedium,
                    ),
                    SizedBox(height: 6.h),
                    Text(
                      'We will tell you as soon as one accepts. That usually '
                      'takes under a minute.',
                      style: MngTheme.light.textTheme.bodySmall,
                    ),
                    // No "3 drivers found" and no row of three coloured
                    // avatars. Both were invented: the client is never told how
                    // many drivers were matched, only that one of them accepted,
                    // so a number here was fiction -- and three faces standing
                    // in for real drivers made it look like three identifiable
                    // people were on the way. What is known is the category
                    // asked for and that a search is running, so that is all it
                    // claims.
                    SizedBox(height: 20.h),
                    const Center(
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                    ),
                    SizedBox(height: 10.h),
                    Text(
                      'Searching',
                      textAlign: TextAlign.center,
                      style: MngTheme.light.textTheme.bodySmall,
                    ),
                    SizedBox(height: 16.h),
                    OutlinedButton(
                      key: const Key('cancelSearchButton'),
                      onPressed: widget.onCancelSearch,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                      child: const Text('Cancel search'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
