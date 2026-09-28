import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:mng_core/mng_core.dart';
import '../data/location_service.dart';
import '../map/ride_map.dart';

class FindingDriverScreen extends StatelessWidget {
  const FindingDriverScreen({
    super.key,
    required this.trip,
    required this.onCancelSearch,
    this.location,
    this.tileProvider,
  });

  final Trip trip;
  final VoidCallback onCancelSearch;

  /// The device fix, when there is one. Absent or refused still renders the
  /// map, centred on the pickup the rider actually booked, with a note saying
  /// why there is no blue dot — which is the point: a blank map and a map that
  /// is confidently somewhere else are both worse than a map that is right
  /// about the pickup and honest about the rider's own position.
  final DeviceLocation? location;

  /// Null in the app, a silent provider under test. See [RideMap.tileProvider].
  final TileProvider? tileProvider;

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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20.w),
              child: RideMap(
                key: const Key('findingMap'),
                pickup: trip.pickup.point,
                location: location,
                height: 300,
                tileProvider: tileProvider,
              ),
            ),
            SizedBox(height: 24.h),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20.w),
              child: Text('3 drivers found',
                  style: MngTheme.light.textTheme.titleLarge),
            ),
            SizedBox(height: 4.h),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20.w),
              child: Text(
                'Asking ${trip.category.label} drivers near you',
                style: MngTheme.light.textTheme.bodySmall,
              ),
            ),
            SizedBox(height: 24.h),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20.w),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final c in const [MngColors.standard, MngColors.info, MngColors.van])
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6.w),
                      child: CircleAvatar(
                        radius: 22,
                        backgroundColor: c,
                        child: const Icon(Icons.person, color: MngColors.onPrimary),
                      ),
                    ),
                ],
              ),
            ),
            const Spacer(),
            Padding(
              padding: EdgeInsets.fromLTRB(20.w, 0, 20.w, 20.h),
              child: OutlinedButton(
                key: const Key('cancelSearchButton'),
                onPressed: onCancelSearch,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                child: const Text('Cancel search'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
