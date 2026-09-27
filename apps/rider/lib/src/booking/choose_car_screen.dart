import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'vehicle_card.dart';

class ChooseCarScreen extends StatefulWidget {
  const ChooseCarScreen({
    super.key,
    required this.vehicles,
    required this.selected,
    required this.onCategory,
    required this.onSelect,
    required this.calc,
    required this.onConfirm,
    this.distanceKm = 8.0,
  });

  final List<Vehicle> vehicles;
  final RideCategory selected;
  final ValueChanged<RideCategory> onCategory;

  /// A card was tapped. Selection only; it commits nothing.
  final void Function(Vehicle vehicle) onSelect;
  final FareCalculator calc;

  /// `Find driver` was pressed. The only path that creates a trip.
  final void Function(Vehicle vehicle) onConfirm;
  final double distanceKm;

  @override
  State<ChooseCarScreen> createState() => _ChooseCarScreenState();
}

class _ChooseCarScreenState extends State<ChooseCarScreen> {
  late RideCategory _category = widget.selected;
  String? _chosenId;

  @override
  void didUpdateWidget(covariant ChooseCarScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected != oldWidget.selected) {
      setState(() {
        _category = widget.selected;
        _chosenId = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final matching =
        widget.vehicles.where((v) => v.rideCategory == _category).toList();
    final quote =
        widget.calc.quote(category: _category, distanceKm: widget.distanceKm);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: MngColors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('Choose your car'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding:
                  EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
              child: Row(
                children: [
                  Text('${widget.distanceKm.toStringAsFixed(1)} km',
                      style: MngTheme.light.textTheme.titleMedium),
                  SizedBox(width: 8.w),
                  Expanded(
                    child: Text('Fares shown are estimates',
                        overflow: TextOverflow.ellipsis,
                        style: MngTheme.light.textTheme.bodySmall),
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20.w),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final c in RideCategory.values)
                      Padding(
                        padding: EdgeInsets.only(right: 8.w),
                        child: GestureDetector(
                          key: Key('tab-${c.name}'),
                          onTap: () => setState(() {
                            _category = c;
                            _chosenId = null;
                            widget.onCategory(c);
                          }),
                          child: Container(
                            constraints: BoxConstraints(minHeight: 40.h),
                            alignment: Alignment.center,
                            padding: EdgeInsets.symmetric(
                                horizontal: 14.w, vertical: 8.h),
                            decoration: BoxDecoration(
                              color: c == _category
                                  ? MngColors.primary
                                  : MngColors.muted,
                              borderRadius:
                                  BorderRadius.circular(MngRadius.small),
                            ),
                            child: Text(
                              c.label,
                              style: TextStyle(
                                fontSize: 13.sp,
                                color: c == _category
                                    ? MngColors.onPrimary
                                    : MngColors.textSub,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding:
                    EdgeInsets.fromLTRB(20.w, 16.h, 20.w, 8.h),
                children: [
                  for (final v in matching)
                    VehicleCard(
                      vehicle: v,
                      fareGhs: widget.calc
                          .quote(
                              category: v.rideCategory,
                              distanceKm: widget.distanceKm)
                          .fareGhs,
                      selected: _chosenId == v.id,
                      onTap: () {
                        setState(() => _chosenId = v.id);
                        widget.onSelect(v);
                      },
                    ),
                  if (matching.isEmpty)
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 40.h),
                      child: Center(
                        child: Text(
                          'No ${_category.label} cars available',
                          style: MngTheme.light.textTheme.bodySmall,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(20.w, 8.h, 20.w, 20.h),
              child: FilledButton(
                key: const Key('findDriverButton'),
                onPressed: matching.isEmpty
                    ? null
                    : () {
                        final picked = matching.firstWhere(
                          (e) => e.id == _chosenId,
                          orElse: () => matching.first,
                        );
                        widget.onConfirm(picked);
                      },
                child: Text('Find driver  GHS ${quote.fareGhs.toStringAsFixed(2)}'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
