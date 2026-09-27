import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

class EtaBadge extends StatelessWidget {
  const EtaBadge({super.key, required this.minutes});

  final int minutes;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('etaBadge'),
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 6.h),
      decoration: BoxDecoration(
        color: MngColors.primary,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$minutes min',
        style: const TextStyle(
          color: MngColors.onPrimary,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
