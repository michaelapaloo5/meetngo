import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key, this.onDone});
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MngColors.primary,
      body: SafeArea(
        child: GestureDetector(
          onTap: onDone,
          child: Padding(
            padding: EdgeInsets.all(24.w),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Meet 'N Go",
                  style: MngTheme.light.textTheme.headlineMedium
                      ?.copyWith(color: MngColors.onPrimary, fontSize: 40),
                ),
                SizedBox(height: 8.h),
                Text(
                  'Make a beeline across the city',
                  style: MngTheme.light.textTheme.titleMedium
                      ?.copyWith(color: MngColors.onPrimary),
                ),
                SizedBox(height: 24.h),
                const Icon(Icons.directions_car_filled, size: 72, color: MngColors.onPrimary),
                SizedBox(height: 16.h),
                const Text('Get started  >',
                    style: TextStyle(color: MngColors.onPrimary, fontSize: 14)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
