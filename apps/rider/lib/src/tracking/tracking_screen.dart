import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';
import '../map/ride_map.dart';
import 'tracking_controller.dart';
import 'widgets/driver_summary.dart';
import 'widgets/eta_badge.dart';

class TrackingScreen extends StatelessWidget {
  const TrackingScreen({super.key});

  // The `tileProvider` parameter that used to be here is gone with the 2D map.
  // It existed only to hand `flutter_map` a silent tile source under test; the
  // map engine now draws through a native view and is switched off for tests by
  // `RideMap.disabledForTest` instead, which no caller has to plumb through.

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
        // The map is the background of the whole screen and the ride details
        // sit on an opaque card over the bottom of it. It used to be a 280px
        // map at the top of a scrolling column, which is a strip of city on a
        // screen a rider is watching to see where they are.
        //
        // The card scrolls on its own rather than the screen, so a drag over
        // the map does not move the map -- the map gestures are off for the
        // same reason.
        child: Stack(
          children: [
            // The real map, full bleed. `RideMap` draws OpenStreetMap vector
            // tiles in 3D with the pickup and dropoff pinned and a line
            // between them. The camera is tilted and rotated rather than
            // pointing straight down, which is what makes the city read as
            // three-dimensional.
            Positioned.fill(
              child: RideMap(
                key: const Key('trackingMap'),
                pickup: trip.pickup.point,
                dropoff: trip.dropoff.point,
                location: c.location,
                fill: true,
              ),
            ),
            // Opaque, not translucent: the ETA pill and the driver name have
            // to stay readable over dark parkland as well as pale blocks.
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.fromLTRB(20.w, 18.h, 20.w, 12.h),
                decoration: const BoxDecoration(
                  color: MngColors.page,
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(24),
                  ),
                ),
                // Scrollable inside the card, because at 2.0 text scale the
                // address line, the driver card and four buttons are taller
                // than the card and the last button would fall off the bottom.
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
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
            // Shown only while the driver is at the pickup, which is the only
            // moment the code is asked for. A driver arrives, taps "Arrived at
            // pickup", and asks the rider to read four digits out loud. Without
            // this panel the rider has nowhere to read them from and the trip
            // cannot leave `arriving` at all.
            //
            // `pickupOtp` is nullable, and null is shown rather than hidden:
            // a rider whose code is missing needs to know that, and a panel
            // that silently does not appear is indistinguishable from a bug.
            if (trip.state == TripState.arriving) ...[
              SizedBox(height: 12.h),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 20.w),
                child: Container(
                  key: const Key('pickupCodePanel'),
                  padding: EdgeInsets.symmetric(
                    horizontal: 16.w,
                    vertical: 12.h,
                  ),
                  decoration: BoxDecoration(
                    color: MngColors.primary,
                    borderRadius: BorderRadius.circular(MngRadius.large),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Read this out\nto your driver',
                          style: MngTheme.light.textTheme.bodySmall?.copyWith(
                            color: MngColors.onPrimary,
                          ),
                        ),
                      ),
                      SizedBox(width: 12.w),
                      // Shown as "Not available" rather than hidden: a rider
                      // whose trip row predates code minting has none, and a
                      // panel that silently does not appear is
                      // indistinguishable from a bug. `Flexible` because that
                      // placeholder is wider than four digits plus the
                      // letterspacing, and a bare `Text` here overflows the row
                      // by 6px at 390 logical pixels.
                      Flexible(
                        child: Text(
                          trip.pickupOtp ?? 'Not available',
                          key: const Key('pickupCodeText'),
                          textAlign: TextAlign.right,
                          overflow: TextOverflow.ellipsis,
                          style: MngTheme.light.textTheme.titleLarge?.copyWith(
                            color: MngColors.onPrimary,
                            letterSpacing: trip.pickupOtp == null ? 0 : 4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (c.sosRaised) ...[              SizedBox(height: 12.h),
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
            // No `Spacer` here any more. It was there to push the buttons to the
            // bottom of a column stretched to the viewport, which needed the
            // `IntrinsicHeight` that is now gone. Inside a scroll view its
            // height is unbounded, so a flex child throws outright:
            // "RenderFlex children have non-zero flex but incoming height
            // constraints are unbounded". The card is bottom-anchored and
            // sized to its content, so it does not need one.
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
          ],
        ),
      ),
    );
  }
}
