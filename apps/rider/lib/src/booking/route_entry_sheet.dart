import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import '../home/widgets/category_chips.dart';

class RouteDraft {
  const RouteDraft({
    required this.pickup,
    required this.dropoff,
    required this.category,
  });

  final TripStop pickup;
  final TripStop dropoff;
  final RideCategory category;
}

/// Accra defaults used until live geocoding lands. Both are real coordinates
/// inside the pilot area so the demo route renders on the map.
const kDefaultPickup =
    TripStop('Pickup', GeoPoint(5.6037, -0.1870), 'Osu, Accra');
const kDefaultDropoff =
    TripStop('Dropoff', GeoPoint(5.6052, -0.1660), 'Airport Residential, Accra');

Future<void> showRouteEntrySheet(
  BuildContext context, {
  required FareCalculator calc,
  required void Function(RouteDraft draft) onSubmit,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => RouteEntrySheet(calc: calc, onSubmit: onSubmit),
  );
}

class RouteEntrySheet extends StatefulWidget {
  const RouteEntrySheet({
    super.key,
    required this.calc,
    required this.onSubmit,
  });

  final FareCalculator calc;
  final void Function(RouteDraft draft) onSubmit;

  @override
  State<RouteEntrySheet> createState() => _RouteEntrySheetState();
}

class _RouteEntrySheetState extends State<RouteEntrySheet> {
  final TripStop _pickup = kDefaultPickup;
  final TripStop _dropoff = kDefaultDropoff;
  RideCategory _category = RideCategory.standard;

  double get _distanceKm => _pickup.point.distanceKmTo(_dropoff.point);

  int get _driveMinutes => (_distanceKm / 24 * 60).round();

  @override
  Widget build(BuildContext context) {
    final quote = widget.calc.quote(category: _category, distanceKm: _distanceKm);
    return Padding(
      padding: EdgeInsets.fromLTRB(20.w, 8.h, 20.w, 20.h),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: EdgeInsets.all(12.w),
            decoration: BoxDecoration(
              color: MngColors.muted,
              borderRadius: BorderRadius.circular(MngRadius.small),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.circle,
                        size: 10, color: MngColors.success),
                    SizedBox(width: 8.w),
                    Expanded(
                      child: Text(_pickup.address,
                          style: MngTheme.light.textTheme.bodyMedium),
                    ),
                  ],
                ),
                SizedBox(height: 8.h),
                Row(
                  children: [
                    const Icon(Icons.circle, size: 10, color: MngColors.error),
                    SizedBox(width: 8.w),
                    Expanded(
                      child: Text(_dropoff.address,
                          style: MngTheme.light.textTheme.bodyMedium),
                    ),
                  ],
                ),
                SizedBox(height: 10.h),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_distanceKm.toStringAsFixed(1)} km  ·  ~$_driveMinutes min drive',
                        overflow: TextOverflow.ellipsis,
                        style: MngTheme.light.textTheme.titleMedium,
                      ),
                    ),
                    SizedBox(width: 8.w),
                    Text('GHS ${quote.fareGhs.toStringAsFixed(2)}',
                        style: MngTheme.light.textTheme.titleMedium),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(height: 16.h),
          CategoryChips(
            selected: _category,
            onSelected: (c) => setState(() => _category = c),
          ),
          SizedBox(height: 20.h),
          FilledButton(
            key: const Key('confirmRouteButton'),
            onPressed: () => widget.onSubmit(RouteDraft(
              pickup: _pickup,
              dropoff: _dropoff,
              category: _category,
            )),
            child: const Text('Search for a ride'),
          ),
        ],
      ),
    );
  }
}
