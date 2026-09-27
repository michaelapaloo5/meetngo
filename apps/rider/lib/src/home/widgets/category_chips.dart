import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

/// Foreground for text or an icon drawn on top of [RideCategory.color].
///
/// `MngColors.premium` is `0xFF1A1A1A`, byte-identical to `MngColors.onPrimary`
/// and `MngColors.textPrimary`, so a selected Premium chip rendered with
/// `onPrimary` is dark-on-dark and reads as an empty box. Measured luminance on
/// this host: `standard` 0.5165, `van` 0.3560, `premium` 0.0103, `onPrimary`
/// 0.0103, `page` 1.0. The `0.5` threshold therefore leaves `standard` and
/// `van` on `onPrimary` exactly as before and flips only `premium` to `page`.
Color onCategoryColor(RideCategory category) =>
    category.color.computeLuminance() > 0.5 ? MngColors.onPrimary : MngColors.page;

class CategoryChips extends StatelessWidget {
  const CategoryChips({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final RideCategory selected;
  final ValueChanged<RideCategory> onSelected;

  static const _icons = <RideCategory, IconData>{
    RideCategory.standard: Icons.directions_car,
    RideCategory.premium: Icons.auto_awesome,
    RideCategory.van: Icons.airport_shuttle,
  };

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 76.h,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: RideCategory.values.length,
        separatorBuilder: (_, _) => SizedBox(width: 10.w),
        itemBuilder: (context, i) {
          final category = RideCategory.values[i];
          final isSelected = category == selected;
          return GestureDetector(
            key: Key('chip-${category.name}'),
            onTap: () => onSelected(category),
            child: Container(
              width: 64.w,
              padding: EdgeInsets.symmetric(vertical: 10.h),
              decoration: BoxDecoration(
                color: isSelected ? category.color : MngColors.muted,
                borderRadius: BorderRadius.circular(MngRadius.small),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _icons[category],
                    size: 20,
                    color: isSelected
                        ? onCategoryColor(category)
                        : MngColors.textPrimary,
                  ),
                  SizedBox(height: 4.h),
                  Text(
                    category.label,
                    style: TextStyle(
                      fontSize: 11.sp,
                      color: isSelected
                          ? onCategoryColor(category)
                          : MngColors.textSub,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
