import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

/// What each tier is, in the words a rider would use.
///
/// Every one of these is a property of the *category*, not of a car: the seats
/// are what the category is matched on, and the car itself is not known until a
/// driver accepts. The previous version of this screen listed four named cars
/// with invented registration plates, which are not rows in `vehicles` and are
/// owned by nobody.
class _Tier {
  const _Tier({
    required this.category,
    required this.seats,
    required this.blurb,
  });

  final RideCategory category;
  final int seats;
  final String blurb;
}

const List<_Tier> _tiers = [
  _Tier(
    category: RideCategory.standard,
    seats: 4,
    blurb: 'Everyday car. Up to 4 seats.',
  ),
  _Tier(
    category: RideCategory.premium,
    seats: 4,
    blurb: 'Newer, nicer car. Up to 4 seats.',
  ),
  _Tier(
    category: RideCategory.lite,
    seats: 7,
    blurb: 'Room for a group. Up to 7 seats.',
  ),
];

class ChooseCarScreen extends StatefulWidget {
  const ChooseCarScreen({
    super.key,
    required this.selected,
    required this.onCategory,
    required this.calc,
    required this.onConfirm,
    this.distanceKm = 8.0,
  });

  final RideCategory selected;
  final ValueChanged<RideCategory> onCategory;

  /// `Find driver` was pressed. The only path that creates a trip.
  ///
  /// Takes a category and not a `Vehicle`, because the rider is choosing a tier
  /// and not a car: `request-ride` matches on `ride_category` against the
  /// drivers actually online, and the specific car is the matched driver's.
  final void Function(RideCategory category) onConfirm;
  final FareCalculator calc;
  final double distanceKm;

  @override
  State<ChooseCarScreen> createState() => _ChooseCarScreenState();
}

class _ChooseCarScreenState extends State<ChooseCarScreen> {
  late RideCategory _category = widget.selected;

  @override
  void didUpdateWidget(covariant ChooseCarScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected != oldWidget.selected) {
      setState(() => _category = widget.selected);
    }
  }

  void _select(RideCategory c) {
    setState(() => _category = c);
    widget.onCategory(c);
  }

  @override
  Widget build(BuildContext context) {
    final quote =
        widget.calc.quote(category: _category, distanceKm: widget.distanceKm);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: MngColors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('Choose your ride'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
              child: Row(
                children: [
                  Text('${widget.distanceKm.toStringAsFixed(1)} km',
                      style: MngTheme.light.textTheme.titleMedium),
                  SizedBox(width: 8.w),
                  Expanded(
                    child: Text('Fares are estimates until you ride',
                        overflow: TextOverflow.ellipsis,
                        style: MngTheme.light.textTheme.bodySmall),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.fromLTRB(20.w, 8.h, 20.w, 8.h),
                children: [
                  for (final tier in _tiers)
                    Padding(
                      padding: EdgeInsets.only(bottom: 12.h),
                      child: _TierCard(
                        tier: tier,
                        fareGhs: widget.calc
                            .quote(
                              category: tier.category,
                              distanceKm: widget.distanceKm,
                            )
                            .fareGhs,
                        selected: tier.category == _category,
                        onTap: () => _select(tier.category),
                      ),
                    ),
                  SizedBox(height: 4.h),
                  // The sentence that replaces four invented cars.
                  //
                  // A rider who chooses a tier is told who is bringing them, and
                  // when, on the tracking screen -- the same as every real
                  // ride-hailing app. This screen deliberately does not name a
                  // car, a driver, or a number of drivers, because it cannot
                  // know any of them: nothing in the client has seen a
                  // `vehicles` row or a match yet.
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.info_outline,
                          size: 16, color: MngColors.textSub),
                      SizedBox(width: 8.w),
                      Expanded(
                        child: Text(
                          'Your driver and car are assigned when a driver '
                          'accepts. You will see the name, car and plate on '
                          'the next screen.',
                          style: MngTheme.light.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(20.w, 8.h, 20.w, 20.h),
              child: FilledButton(
                key: const Key('findDriverButton'),
                onPressed: () => widget.onConfirm(_category),
                child: Text(
                  'Find driver  GHS ${quote.fareGhs.toStringAsFixed(2)}',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TierCard extends StatelessWidget {
  const _TierCard({
    required this.tier,
    required this.fareGhs,
    required this.selected,
    required this.onTap,
  });

  final _Tier tier;
  final double fareGhs;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = tier.category.color;
    return GestureDetector(
      key: Key('rideCard-${tier.category.name}'),
      onTap: onTap,
      child: Container(
        key: Key('tierPanel-${tier.category.name}'),
        padding: EdgeInsets.all(14.w),
        decoration: BoxDecoration(
          color: MngColors.surface,
          borderRadius: BorderRadius.circular(MngRadius.small),
          border: Border.all(
            color: selected ? color : MngColors.divider,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? color : MngColors.muted,
                shape: BoxShape.circle,
              ),
              child: Icon(
                _iconFor(tier.category),
                color: selected ? MngColors.onPrimary : MngColors.textSub,
              ),
            ),
            SizedBox(width: 12.w),
            Expanded(
              // Stacked, not a Row. Once the icon, the gaps and the fare have
              // taken their share of a 390-wide screen, the middle is about
              // 108px, and "Standard" beside "4 seats" does not fit in that --
              // it overflowed by 114px. Vertical text grows down, and this
              // panel is inside a ListView, so it can.
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tier.category.label,
                    style: MngTheme.light.textTheme.titleMedium,
                  ),
                  Text(
                    '${tier.seats} seats',
                    style: MngTheme.light.textTheme.bodySmall,
                  ),
                  SizedBox(height: 2.h),
                  Text(
                    tier.blurb,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: MngTheme.light.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            SizedBox(width: 8.w),
            // Flexible so it can shrink rather than push the row over. At 200%
            // text scale the fare is wide enough to do exactly that, and an
            // overflow stripe across a price is the last thing a rider should
            // see. Ellipsis on a price is bad too, so it gives up the padding
            // first -- the fare is the one number that must stay whole, so it
            // is the last thing to be clipped.
            Flexible(
              child: Text(
                'GHS ${fareGhs.toStringAsFixed(2)}',
                textAlign: TextAlign.right,
                style: MngTheme.light.textTheme.titleMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _iconFor(RideCategory c) => switch (c) {
        RideCategory.standard => Icons.directions_car,
        RideCategory.premium => Icons.auto_awesome,
        RideCategory.lite => Icons.airport_shuttle,
      };
}
