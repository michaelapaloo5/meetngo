import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

/// Foreground for text or an icon drawn on top of [RideCategory.color].
///
/// `MngColors.premium` is `0xFF1A1A1A`, byte-identical to `MngColors.onPrimary`
/// and `MngColors.textPrimary`, so a selected Premium chip rendered with
/// `onPrimary` is dark-on-dark and reads as an empty box. Measured luminance on
/// this host: `standard` 0.5165, `van` 0.3560, `premium` 0.0103, `onPrimary`
/// 0.0103, `page` 1.0. A `0.5` threshold clears `standard` alone, so it sent
/// `van` to `page` at 2.59:1. The `0.2` threshold keeps `standard` and `van`
/// on `onPrimary` and sends only `premium` to `page`.
Color onCategoryColor(RideCategory category) =>
    category.color.computeLuminance() > 0.2 ? MngColors.onPrimary : MngColors.page;

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
    // Three chips sharing the row's width, not three chips sized to their own
    // text inside a horizontal scroller.
    //
    // The scroller was the bug: inside it the Row is `mainAxisSize.min` with an
    // unbounded width, and the `Column` that holds the icon and the label ends
    // up width-constrained by the chip rather than the other way round, so the
    // label overflowed its own pill. It was visible on a 360dp phone, where
    // "Standard" is wider than the pill it was drawn in. There are three chips
    // and they all fit, so equal thirds is also the honest layout: it is the
    // same on every screen, and it does not silently scroll.
    // `IntrinsicHeight` rather than `CrossAxisAlignment.stretch`, because the
    // row sits in a vertical scroll view and so has an unbounded height, which
    // `stretch` cannot lay out against. The intrinsic pass is a few hundred
    // microseconds for three children, and it is what makes the three pills the
    // same height whether or not one of them is selected.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final category in RideCategory.values)
            Expanded(child: _chip(category)),
        ],
      ),
    );
  }

  Widget _chip(RideCategory category) {
    final isSelected = category == selected;
    return Padding(
      padding: EdgeInsets.only(right: 10.w),
      child: GestureDetector(
        key: Key('chip-${category.name}'),
        onTap: () => onSelected(category),
        child: Container(
          constraints: BoxConstraints(minHeight: 76.h),
          padding: EdgeInsets.symmetric(vertical: 10.h, horizontal: 4.w),
          decoration: BoxDecoration(
            color: isSelected ? category.color : MngColors.muted,
            borderRadius: BorderRadius.circular(MngRadius.small),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
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
              // Ellipsised rather than allowed to spill. A tier whose name is
              // cut short is still tappable and still correct; a tier whose
              // name is drawn outside its own background is neither legible nor
              // obviously pressable.
              Text(
                category.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
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
      ),
    );
  }
}
