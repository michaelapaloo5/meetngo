import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

class VehicleCard extends StatelessWidget {
  const VehicleCard({
    super.key,
    required this.vehicle,
    required this.fareGhs,
    required this.onTap,
    this.rating = 4.9,
    this.selected = false,
  });

  final Vehicle vehicle;
  final double fareGhs;
  final VoidCallback onTap;
  final double rating;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: Key('vehicleCard-${vehicle.id}'),
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.only(bottom: 12.h),
        padding: EdgeInsets.all(12.w),
        decoration: BoxDecoration(
          color: MngColors.surface,
          borderRadius: BorderRadius.circular(MngRadius.large),
          border: Border.all(
            color: selected ? MngColors.primary : MngColors.divider,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 64.w,
              height: 48.h,
              decoration: BoxDecoration(
                color: MngColors.muted,
                borderRadius: BorderRadius.circular(MngRadius.small),
              ),
              child: vehicle.photoUrl.isEmpty
                  ? Icon(Icons.directions_car,
                      color: vehicle.rideCategory.color, size: 28)
                  : Image.network(vehicle.photoUrl),
            ),
            SizedBox(width: 12.w),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(vehicle.rideCategory.label,
                      style: MngTheme.light.textTheme.bodySmall),
                  SizedBox(height: 2.h),
                  Text(vehicle.displayName,
                      style: MngTheme.light.textTheme.titleMedium),
                  SizedBox(height: 4.h),
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
                          Text(rating.toStringAsFixed(1),
                              style: MngTheme.light.textTheme.bodySmall),
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.person,
                              size: 14, color: MngColors.textSub),
                          SizedBox(width: 2.w),
                          Text('${vehicle.seats} seats',
                              style: MngTheme.light.textTheme.bodySmall),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text('GHS ${fareGhs.toStringAsFixed(2)}',
                    style: MngTheme.light.textTheme.titleMedium),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
