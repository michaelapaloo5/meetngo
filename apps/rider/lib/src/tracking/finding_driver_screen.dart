import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import '../data/location_service.dart';
import '../map/ride_map.dart';

class FindingDriverScreen extends StatelessWidget {
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
  Widget build(BuildContext context) {
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
              child: RideMap(
                key: const Key('findingMap'),
                pickup: trip.pickup.point,
                location: location,
                fill: true,
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
                      onPressed: onCancelSearch,
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
