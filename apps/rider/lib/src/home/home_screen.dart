import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'widgets/category_chips.dart';
import 'widgets/promo_banner.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.nearby,
    required this.promoCode,
    this.onSearchTap,
  });

  final List<Vehicle> nearby;
  final String promoCode;
  final void Function(BuildContext context)? onSearchTap;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  RideCategory _category = RideCategory.standard;

  String get _greeting {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('$_greeting, Alex',
                            style: MngTheme.light.textTheme.titleLarge),
                        SizedBox(height: 2.h),
                        Text('Osu, Accra, Ghana',
                            style: MngTheme.light.textTheme.bodySmall),
                      ],
                    ),
                  ),
                  const Icon(Icons.notifications_none),
                ],
              ),
              SizedBox(height: 20.h),
              GestureDetector(
                key: const Key('searchField'),
                onTap: () => widget.onSearchTap?.call(context),
                child: Container(
                  height: 52.h,
                  padding: EdgeInsets.symmetric(horizontal: 16.w),
                  decoration: BoxDecoration(
                    color: MngColors.muted,
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.search, color: MngColors.textSub),
                      SizedBox(width: 10.w),
                      Text(
                        'Where would you go?',
                        style: MngTheme.light.textTheme.bodyMedium
                            ?.copyWith(color: MngColors.textSub),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: 16.h),
              CategoryChips(
                selected: _category,
                onSelected: (c) => setState(() => _category = c),
              ),
              SizedBox(height: 8.h),
              PromoBanner(code: widget.promoCode),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Available cars',
                      style: MngTheme.light.textTheme.titleMedium),
                  Text('See all', style: MngTheme.light.textTheme.bodySmall),
                ],
              ),
              SizedBox(height: 12.h),
              if (widget.nearby.isEmpty)
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 40.h),
                  child: Center(
                    child: Text('No cars nearby right now',
                        style: MngTheme.light.textTheme.bodySmall),
                  ),
                )
              else
                for (final v in widget.nearby)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: v.rideCategory.color,
                      child: Icon(Icons.directions_car,
                          color: onCategoryColor(v.rideCategory)),
                    ),
                    title: Text(v.displayName),
                    subtitle: Text('${v.rideCategory.label} · ${v.seats} seats'),
                    trailing: const Icon(Icons.chevron_right),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}
