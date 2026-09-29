import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

class PromoBanner extends StatelessWidget {
  const PromoBanner({super.key, required this.code, this.onPressed});

  final String code;

  /// Pressed to take the offer.
  ///
  /// It was a `Container`, so the one control on the home screen that can change
  /// the price of a ride could not be pressed. A button advertises 30% off and
  /// then does nothing when tapped, which is worse than not advertising it.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final body = Container(
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
                    // "Code" only when it is a code to copy. Pressed, this is
                    // not something to retype, it is something to accept.
                    onPressed == null ? 'Code $code' : 'Tap to use $code',
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

    if (onPressed == null) return body;
    return Semantics(
      button: true,
      label: 'Limited offer, 30% off your first ride. Activate.',
      child: GestureDetector(
        key: const Key('promoBanner'),
        onTap: onPressed,
        child: body,
      ),
    );
  }
}
