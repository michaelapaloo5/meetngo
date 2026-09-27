import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

class DriverSummary extends StatelessWidget {
  const DriverSummary({super.key, required this.driver, this.vehicle});

  final DriverProfile driver;
  final Vehicle? vehicle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(MngSpacing.md),
      decoration: BoxDecoration(
        color: MngColors.surface,
        borderRadius: BorderRadius.circular(MngRadius.large),
        border: Border.all(color: MngColors.divider),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: MngColors.muted,
            backgroundImage:
                driver.photoUrl.isEmpty ? null : NetworkImage(driver.photoUrl),
            child: driver.photoUrl.isEmpty
                ? Text(
                    driver.fullName.isEmpty
                        ? '?'
                        : driver.fullName.characters.first,
                    style: MngTheme.light.textTheme.titleMedium,
                  )
                : null,
          ),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(driver.fullName,
                    style: MngTheme.light.textTheme.titleMedium),
                SizedBox(height: 2.h),
                // A `Wrap` of `MainAxisSize.min` rows, not one Row. The rating,
                // the car and the plate are three independent facts and a plate
                // is as wide as the card allows; in a single Row they overflow
                // the card at 390 logical pixels. The plate is outside the
                // `Flexible`, because the name is the part that has to ellipsize
                // and the plate is the part that has to stay whole.
                Wrap(
                  spacing: 10.w,
                  runSpacing: 2.h,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.star,
                            size: 14, color: MngColors.primary),
                        SizedBox(width: 2.w),
                        Text(driver.rating.toStringAsFixed(1),
                            style: MngTheme.light.textTheme.bodySmall),
                      ],
                    ),
                    if (vehicle != null)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(vehicle!.displayName,
                                overflow: TextOverflow.ellipsis,
                                style: MngTheme.light.textTheme.bodySmall),
                          ),
                          SizedBox(width: 6.w),
                          Text(vehicle!.plate,
                              style: MngTheme.light.textTheme.bodySmall),
                        ],
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
