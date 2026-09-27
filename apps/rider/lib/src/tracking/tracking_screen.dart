import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';
import 'tracking_controller.dart';
import 'widgets/driver_summary.dart';
import 'widgets/eta_badge.dart';

class TrackingScreen extends StatelessWidget {
  const TrackingScreen({super.key});

  static const _headlines = <TripState, String>{
    TripState.requested: 'Finding your driver',
    TripState.matched: 'Ride confirmed',
    TripState.arriving: 'Arriving soon',
    TripState.ongoing: 'On the way',
    TripState.completed: 'Trip complete',
    TripState.cancelled: 'Trip cancelled',
  };

  @override
  Widget build(BuildContext context) {
    final c = context.watch<TrackingController>();
    final trip = c.trip;
    if (trip == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // The Dart `canTransition` table, not a copy of it. It is the same table the
    // database trigger enforces (`init.sql:192-197`) and the one the controller
    // checks before it calls the function, so the button is hidden by asking
    // the authority rather than by a second list that could disagree.
    final canCancel = canTransition(trip.state, TripState.cancelled);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: MngColors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: const BackButton(),
        title: const Text('Your ride'),
      ),
      body: SafeArea(
        // Scrollable, because at 2.0 text scale the fixed content below — a
        // 280.h map box, the address line, the driver card and four buttons —
        // is 107px taller than an 844-high viewport and the last button falls
        // off the bottom. `ConstrainedBox` at the viewport height is what keeps
        // the `Spacer` meaningful: while the content is shorter than the screen
        // the Column is stretched to fill it and the buttons sit at the bottom
        // exactly as they do without the scroll view, and only a taller column
        // overflows into scrolling.
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
            // Map placeholder: the Google Maps widget is dropped into this
            // Container in the integration pass. Keeping the box fixed means
            // the widget tests never need a platform view.
            Container(
              height: 280.h,
              margin: EdgeInsets.symmetric(horizontal: 20.w),
              decoration: BoxDecoration(
                color: MngColors.muted,
                borderRadius: BorderRadius.circular(MngRadius.large),
              ),
              child: const Center(child: Icon(Icons.map, size: 40)),
            ),
            SizedBox(height: 20.h),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20.w),
              child: Row(
                children: [
                  // Expanded, so the headline ellipsizes beside the ETA pill
                  // rather than overflowing the row by 3.5px at 390 logical
                  // pixels.
                  Expanded(
                    child: Text(
                      _headlines[trip.state] ?? 'Your ride',
                      overflow: TextOverflow.ellipsis,
                      style: MngTheme.light.textTheme.titleLarge,
                    ),
                  ),
                  if (c.etaMinutes != null) ...[
                    SizedBox(width: 10.w),
                    EtaBadge(minutes: c.etaMinutes!),
                  ],
                ],
              ),
            ),
            SizedBox(height: 4.h),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20.w),
              child: Text(
                '${trip.pickup.address} to ${trip.dropoff.address}',
                style: MngTheme.light.textTheme.bodySmall,
              ),
            ),
            SizedBox(height: 16.h),
            if (c.driver != null)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 20.w),
                child: DriverSummary(
                  driver: c.driver!,
                  vehicle: c.driverVehicle,
                ),
              ),
            if (c.sosRaised) ...[
              SizedBox(height: 12.h),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 20.w),
                child: Container(
                  padding: EdgeInsets.all(12.w),
                  decoration: BoxDecoration(
                    color: MngColors.error.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(MngRadius.small),
                  ),
                  child: const Text(
                    'Help is on the way. Our team has your trip.',
                    style: TextStyle(color: MngColors.error),
                  ),
                ),
              ),
            ],
            // Both failure messages, and they are different kinds of thing. The
            // banner above is only reachable once `raiseSos` has written a row;
            // this line is where every caught failure lands, which is why the
            // SOS button stays enabled after a failed press.
            if (c.error != null) ...[
              SizedBox(height: 12.h),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 20.w),
                child: Text(c.error!,
                    style: const TextStyle(color: MngColors.error)),
              ),
            ],
            const Spacer(),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20.w),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('callButton'),
                      onPressed: () {},
                      icon: const Icon(Icons.call, size: 18),
                      label: const Text('Call'),
                    ),
                  ),
                  SizedBox(width: 10.w),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('messageButton'),
                      onPressed: () {},
                      icon: const Icon(Icons.chat_bubble_outline, size: 18),
                      label: const Text('Message'),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 10.h),
            if (canCancel)
              Padding(
                padding:
                    EdgeInsets.fromLTRB(20.w, 0, 20.w, 12.h),
                child: OutlinedButton(
                  key: const Key('cancelButton'),
                  onPressed: c.cancel,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: MngColors.error,
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: const Text('Cancel trip'),
                ),
              ),
            Padding(
              padding: EdgeInsets.fromLTRB(20.w, 0, 20.w, 20.h),
              child: OutlinedButton.icon(
                key: const Key('sosButton'),
                onPressed: c.raiseSos,
                style: OutlinedButton.styleFrom(
                  foregroundColor: MngColors.error,
                  minimumSize: const Size.fromHeight(48),
                ),
                icon: const Icon(Icons.shield_outlined, size: 18),
                label: const Text('Safety'),
              ),
            ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
