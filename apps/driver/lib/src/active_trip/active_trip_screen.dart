import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

import 'active_trip_controller.dart';
import 'pickup_otp_sheet.dart';

class ActiveTripScreen extends StatelessWidget {
  const ActiveTripScreen({super.key, required this.onFinished});

  /// Called when the driver presses the button on a finished trip.
  final VoidCallback onFinished;

  /// What the two buttons the plan put on this screen cannot do yet.
  ///
  /// `google_maps_flutter` and `url_launcher` are not dependencies of this app
  /// and a phone in the pilot has neither configured, so a button that launched
  /// them would fail on the device that matters. The plan's `onPressed: () {}`
  /// was worse: a live-looking control that does nothing at all. This says what
  /// is missing instead.
  static const _notInThisBuild =
      'Turn-by-turn navigation is not part of this build.';

  static const _callNotInThisBuild =
      'Calling from the app is not part of this build.';

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ActiveTripController>();
    final trip = controller.trip;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: MngColors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          controller.headline,
          style: MngTheme.light.textTheme.titleLarge,
        ),
      ),
      body: trip == null
          // Not the headline: the app bar already carries it, and the plan's
          // version rendered 'No active trip' in both, so the one string on
          // this screen a test can assert on appears twice.
          ? Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 40.w),
                child: Text(
                  'There is no trip on this account to show.',
                  textAlign: TextAlign.center,
                  style: MngTheme.light.textTheme.bodySmall,
                ),
              ),
            )
          : SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
                    child: Row(
                      children: [
                        Container(
                          key: const Key('tripStateChip'),
                          padding: EdgeInsets.symmetric(
                            horizontal: 12.w,
                            vertical: 6.h,
                          ),
                          decoration: BoxDecoration(
                            color: MngColors.muted,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            trip.state.name,
                            style: MngTheme.light.textTheme.bodySmall,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          'GHS ${trip.fareGhs.toStringAsFixed(2)}',
                          style: MngTheme.light.textTheme.titleMedium,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      padding: EdgeInsets.symmetric(horizontal: 20.w),
                      children: [
                        _RouteStop(
                          icon: Icons.trip_origin,
                          title: trip.pickup.label,
                          address: trip.pickup.address,
                        ),
                        _RouteStop(
                          icon: Icons.place,
                          title: trip.dropoff.label,
                          address: trip.dropoff.address,
                          last: true,
                        ),
                      ],
                    ),
                  ),
                  if (controller.error != null)
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 20.w),
                      child: Text(
                        controller.error!,
                        key: const Key('activeTripError'),
                        style: const TextStyle(color: MngColors.error),
                      ),
                    ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(20.w, 12.h, 20.w, 20.h),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                key: const Key('navigateButton'),
                                onPressed: () => _say(
                                  context,
                                  _notInThisBuild,
                                ),
                                icon: const Icon(Icons.navigation),
                                label: const Text('Navigate'),
                              ),
                            ),
                            SizedBox(width: 12.w),
                            Expanded(
                              child: OutlinedButton.icon(
                                key: const Key('callRiderButton'),
                                onPressed: () =>
                                    _say(context, _callNotInThisBuild),
                                icon: const Icon(Icons.call),
                                label: const Text('Call'),
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 12.h),
                        FilledButton(
                          key: const Key('primaryActionButton'),
                          onPressed: controller.busy ||
                                  (!controller.canAdvance &&
                                      !controller.isFinished)
                              ? null
                              : () => _act(context, controller),
                          child: Text(controller.primaryActionLabel),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  void _say(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _act(
    BuildContext context,
    ActiveTripController controller,
  ) async {
    if (controller.isFinished) {
      onFinished();
      return;
    }
    if (controller.trip?.state == TripState.arriving) {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => PickupOtpSheet(controller: controller),
      );
      return;
    }
    // Read the state off the controller and not off the `trip` this build
    // captured. `advance` is awaited, and the `trip` local is the pre-advance
    // object, so `trip.state == completed` was never true here and
    // `onFinished` was dead code.
    await controller.advance();
    if (controller.isFinished) onFinished();
  }
}

class _RouteStop extends StatelessWidget {
  const _RouteStop({
    required this.icon,
    required this.title,
    required this.address,
    this.last = false,
  });

  final IconData icon;
  final String title;
  final String address;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Icon(
              icon,
              color: last ? MngColors.success : MngColors.primary,
              size: 20,
            ),
            if (!last)
              Container(width: 2, height: 40.h, color: MngColors.divider),
          ],
        ),
        SizedBox(width: 12.w),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: last ? 0 : 20.h),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: MngTheme.light.textTheme.titleMedium),
                SizedBox(height: 2.h),
                Text(address, style: MngTheme.light.textTheme.bodySmall),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
