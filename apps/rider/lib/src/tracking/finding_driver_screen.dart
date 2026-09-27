import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

class FindingDriverScreen extends StatelessWidget {
  const FindingDriverScreen({
    super.key,
    required this.trip,
    required this.onCancelSearch,
  });

  final Trip trip;
  final VoidCallback onCancelSearch;

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
            // Map placeholder, for the same reason as the one on
            // `TrackingScreen`: a fixed box, so a platform view is not needed
            // to render this screen under test.
            Container(
              height: 300.h,
              margin: EdgeInsets.symmetric(horizontal: 20.w),
              decoration: BoxDecoration(
                color: MngColors.muted,
                borderRadius: BorderRadius.circular(MngRadius.large),
              ),
              child: const Center(child: Icon(Icons.map, size: 40)),
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
