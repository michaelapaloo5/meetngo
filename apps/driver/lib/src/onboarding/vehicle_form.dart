import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

import 'kyc_controller.dart';

/// The vehicle half of [KycScreen], on its own so a driver whose vehicle was
/// rejected can come back and fix it without walking the card and selfie steps
/// again.
class VehicleForm extends StatelessWidget {
  const VehicleForm({super.key, required this.controller});

  final KycController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('vehicleMakeField'),
          onChanged: (v) => controller.vehicleMake = v,
          decoration: const InputDecoration(hintText: 'Make (Toyota)'),
        ),
        SizedBox(height: 12.h),
        TextField(
          key: const Key('vehicleModelField'),
          onChanged: (v) => controller.vehicleModel = v,
          decoration: const InputDecoration(hintText: 'Model (Corolla)'),
        ),
        SizedBox(height: 12.h),
        TextField(
          key: const Key('vehiclePlateField'),
          onChanged: (v) => controller.vehiclePlate = v.toUpperCase(),
          decoration: const InputDecoration(hintText: 'Plate (GR-1234-22)'),
        ),
        SizedBox(height: 12.h),
        TextField(
          key: const Key('vehicleSeatsField'),
          keyboardType: TextInputType.number,
          onChanged: (v) => controller.vehicleSeats = int.tryParse(v) ?? 0,
          decoration: const InputDecoration(hintText: 'Seats (4)'),
        ),
        SizedBox(height: 12.h),
        DropdownButtonFormField<RideCategory>(
          key: const Key('vehicleCategoryField'),
          initialValue: controller.vehicleCategory,
          items: [
            for (final category in RideCategory.values)
              DropdownMenuItem(value: category, child: Text(category.label)),
          ],
          onChanged: (v) =>
              controller.vehicleCategory = v ?? RideCategory.standard,
        ),
        SizedBox(height: 12.h),
        Text(
          'A human checks your vehicle before you can take rides.',
          style: MngTheme.light.textTheme.bodySmall,
        ),
      ],
    );
  }
}
