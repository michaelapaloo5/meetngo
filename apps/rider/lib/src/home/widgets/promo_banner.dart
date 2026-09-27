import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

class PromoBanner extends StatelessWidget {
  const PromoBanner({super.key, required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(bottom: MngSpacing.md),
      padding: EdgeInsets.all(MngSpacing.md),
      decoration: BoxDecoration(
        color: MngColors.textPrimary,
        borderRadius: BorderRadius.circular(MngRadius.large),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Limited offer',
                  style: MngTheme.light.textTheme.bodySmall
                      ?.copyWith(color: MngColors.primary),
                ),
                SizedBox(height: 4.h),
                Text(
                  '30% off your first ride',
                  style: MngTheme.light.textTheme.titleMedium
                      ?.copyWith(color: Colors.white),
                ),
                SizedBox(height: 8.h),
                Container(
                  padding:
                      EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
                  decoration: BoxDecoration(
                    color: MngColors.primary,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Code $code',
                    style: MngTheme.light.textTheme.bodySmall
                        ?.copyWith(color: MngColors.onPrimary),
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.directions_car_filled,
              color: MngColors.primary, size: 44),
        ],
      ),
    );
  }
}
