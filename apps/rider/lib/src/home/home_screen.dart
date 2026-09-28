import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'widgets/category_chips.dart';
import 'widgets/promo_banner.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.riderName,
    required this.promoCode,
    this.onSearchTap,
    this.onNotificationsTap,
  });

  /// The signed-in rider's own first name.
  ///
  /// Null or blank when `profiles.full_name` is empty, which is a real value
  /// for every account created before sign-up began persisting it, and also
  /// when the profile row has not loaded or could not be read. The greeting
  /// falls back rather than rendering ", ", because a screen that greets a
  /// rider with a comma is worse than one that does not name them.
  final String? riderName;

  final String promoCode;
  final void Function(BuildContext context)? onSearchTap;
  final void Function(BuildContext context)? onNotificationsTap;

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
    final name = widget.riderName?.trim() ?? '';
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
                        Text(
                          name.isEmpty ? _greeting : '$_greeting, $name',
                          key: const Key('greeting'),
                          style: MngTheme.light.textTheme.titleLarge,
                        ),
                        SizedBox(height: 2.h),
                        Text(
                          'Osu, Accra, Ghana',
                          style: MngTheme.light.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const Key('notificationsButton'),
                    onPressed: () => widget.onNotificationsTap?.call(context),
                    icon: const Icon(Icons.notifications_none),
                    tooltip: 'Notifications',
                  ),
                ],
              ),
              SizedBox(height: 20.h),
              GestureDetector(
                key: const Key('searchField'),
                onTap: () => widget.onSearchTap?.call(context),
                child: Container(
                  constraints: BoxConstraints(minHeight: 52.h),
                  padding: EdgeInsets.symmetric(
                      horizontal: 16.w, vertical: 14.h),
                  decoration: BoxDecoration(
                    color: MngColors.muted,
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.search, color: MngColors.textSub),
                      SizedBox(width: 10.w),
                      Expanded(
                        child: Text(
                          'Where would you go?',
                          overflow: TextOverflow.ellipsis,
                          style: MngTheme.light.textTheme.bodyMedium
                              ?.copyWith(color: MngColors.textSub),
                        ),
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
              // No "Available cars" section, and nothing put in its place.
              // The list it used to draw came from `kNearbyVehicles`, a
              // constant in `rider_flow.dart`: four seeded Toyotas, Nissans
              // and a Mercedes with invented plates, none of which is a row in
              // `vehicles` and none of which any driver owns. It was not "the
              // cars near you", it was four strings. `request-ride` matches
              // against `driver_locations` on the server, so this build has no
              // client-side source of real nearby cars at all, and the only
              // honest thing to do with the space is to leave it empty. The
              // fare quoted after a search tap is computed by
              // `FareCalculator` from the drafted distance, not invented.
            ],
          ),
        ),
      ),
    );
  }
}
