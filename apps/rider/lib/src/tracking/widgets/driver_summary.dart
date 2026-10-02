import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

import '../../data/trip_repository.dart';

class DriverSummary extends StatelessWidget {
  const DriverSummary({super.key, required this.driver});

  /// What the `contact` function answered with.
  ///
  /// A [DriverContact] rather than a `DriverProfile` and a `Vehicle`, because
  /// those two are the driver's own types and neither can be built from what a
  /// rider is entitled to see. `profiles` is readable by its owner only and
  /// `vehicles` by their owner only -- the rider's app can construct neither, and
  /// the only reason a `DriverProfile` ever appeared on this widget was a test
  /// fixture that no production path could produce. That is why the card never
  /// rendered, and why it was missed: the widget was correct and complete and
  /// had nothing real to draw.
  final DriverContact driver;

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
            backgroundImage: driver.photoUrl.isEmpty
                ? null
                : NetworkImage(driver.photoUrl),
            child: driver.photoUrl.isEmpty
                ? Text(
                    driver.name.isEmpty ? '?' : driver.name.characters.first,
                    style: MngTheme.light.textTheme.titleMedium,
                  )
                : null,
          ),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // "Your driver" rather than an empty line when the lookup found no name.
                // A blank where a person's name should be reads as a bug; a
                // generic label reads as "we don't know yet", which is true.
                Text(
                  driver.name.isEmpty ? 'Your driver' : driver.name,
                  style: MngTheme.light.textTheme.titleMedium,
                ),
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
                    // Only when there is one. A star with no number beside it is
                    // decoration pretending to be information.
                    if (driver.rating != null)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.star,
                            size: 14,
                            color: MngColors.primary,
                          ),
                          SizedBox(width: 2.w),
                          Text(
                            driver.rating!.toStringAsFixed(1),
                            style: MngTheme.light.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    if (driver.car.isNotEmpty)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              driver.car,
                              overflow: TextOverflow.ellipsis,
                              style: MngTheme.light.textTheme.bodySmall,
                            ),
                          ),
                          SizedBox(width: 6.w),
                          // Flexible like the name beside it. The plate used to
                          // be a plain Text, so at 200% text scale the row ran
                          // 33px past the card's edge -- the name would have
                          // ellipsized and then the plate overflowed anyway,
                          // which is the worst of both: a truncated car AND a
                          // stripe across the screen.
                          Flexible(
                            child: Text(
                              driver.plate,
                              overflow: TextOverflow.ellipsis,
                              style: MngTheme.light.textTheme.bodySmall,
                            ),
                          ),
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
