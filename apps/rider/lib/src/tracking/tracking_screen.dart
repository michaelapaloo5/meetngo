import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

import '../trip/trip_copy.dart';

import 'package:provider/provider.dart';

import '../data/chat_repository.dart';
import '../data/booked_trip.dart';
import '../map/fullscreen_ride_map_screen.dart';
import '../map/ride_map.dart';
import 'driver_contact_sheet.dart';
import '../trip/share_ride_sheet.dart';
import 'tracking_controller.dart';
import 'widgets/driver_summary.dart';
import 'widgets/eta_badge.dart';

class TrackingScreen extends StatelessWidget {
  const TrackingScreen({super.key, this.onCallDriver, this.onMessageDriver});

  /// Call the assigned driver.
  ///
  /// A callback rather than something this screen reaches for, because opening
  /// a dialler, copying a number and showing a sheet full screen are three
  /// different decisions and the screen should not own any of them. Null is a
  /// real state -- a build with no way to reach the other party -- and the
  /// buttons are *disabled* rather than removed, so the rider can see the
  /// feature exists and that it is unavailable, which is a different and more
  /// honest thing than a screen that never had the buttons.
  final VoidCallback? onCallDriver;

  /// Open the conversation with the assigned driver.
  ///
  /// Null for the same reason as [onCallDriver].
  final VoidCallback? onMessageDriver;

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

  /// Ask before raising an SOS, then say plainly what happened.
  ///
  /// Three things this fixes, all of them found by reading rather than by
  /// looking:
  ///
  /// - there was no confirmation at all, so a mis-tap raised a real alert that
  ///   nothing in this app could retract
  /// - the success state was a red `Text` with no key of its own, so it could
  ///   not be asserted on and a rider who pressed it could not tell whether it
  ///   had landed
  /// - a second press was a silent no-op (`if (sosRaised) return`), so a rider
  ///   who pressed again because nothing appeared was told nothing
  ///
  /// The snackbar is the receipt. `raiseSos` rolls its optimistic flag back on
  /// failure, and a rider who was shown "help is on the way" for a row that
  /// never reached `sos_events` is the outcome this whole path exists to
  /// prevent -- so the message is only shown once the write has actually landed.
  static Future<void> _confirmSos(
    BuildContext context,
    TrackingController controller,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('sosConfirmDialog'),
        title: const Text('Alert our team?'),
        content: const Text(
          'We will share your trip and location with the Meet \'N Go team so they '
          'can help. Your driver will not be told.',
        ),
        actions: [
          TextButton(
            key: const Key('sosConfirmCancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('sosConfirmSend'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Send alert'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;

    final raised = await controller.raiseSos();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          key: const Key('sosResultSnack'),
          content: Text(
            raised
                // Not "Help is on the way" -- nothing in this app sends anyone
                // anywhere. The team has the trip and the rider's location and
                // will act; saying help is coming would be a promise the app
                // cannot keep.
                ? 'Our team has your trip and location.'
                : controller.error ?? 'We could not send the alert. Try again.',
          ),
        ),
      );
  }

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
                // The two place names, printed beside their pins. `stopLabel`
                // rather than `.label` directly: some rows in this database
                // carry a coordinate string where the label belongs, and
                // `stopLabel` is the one function in this app that refuses to
                // print one.
                pickupLabel: stopLabel(trip.pickup),
                dropoffLabel: stopLabel(trip.dropoff),
                location: c.location,
                // The driver, with the heading they published, so the car turns
                // as it approaches instead of sitting pointed at north. Null
                // until a position has been read, in which case the map is
                // unchanged and simply has no car on it yet.
                driver: c.driverPoint,
                fill: true,
                // Tap to open it full screen.
                //
                // The card cannot be pannable -- it is inside a scrolling column,
                // so a drag on it has to scroll the ride details, or the buttons
                // below are unreachable. That leaves the rider watching a fixed
                // frame with no way to check the junction they are about to pass,
                // so the tap is the way past it and the larger map has the
                // gestures on.
                onTapToExpand: () => FullscreenRideMapScreen.show(
                  context,
                  pickup: trip.pickup.point,
                  pickupLabel: stopLabel(trip.pickup),
                  dropoff: trip.dropoff.point,
                  dropoffLabel: stopLabel(trip.dropoff),
                  location: c.location,
                  driver: c.driverPoint,
                ),
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
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
                      if (c.driverContact != null)
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 20.w),
                          child: DriverSummary(driver: c.driverContact!),
                        )
                      // A rider waiting for a car and told nothing is the worst
                      // state this screen has. While the lookup is in flight, say
                      // so, rather than showing a gap where the driver should be
                      // -- which is what an unconditional null check looks like.
                      else if (c.driverContactPending)
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 20.w),
                          child: Text(
                            'Getting your driver\'s details...',
                            key: const Key('driverDetailsPending'),
                            style: MngTheme.light.textTheme.bodySmall,
                          ),
                        )
                      else if (c.driverContactFailed != null)
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 20.w),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  c.driverContactFailed!,
                                  key: const Key('driverDetailsFailed'),
                                  style: MngTheme.light.textTheme.bodySmall,
                                ),
                              ),
                              TextButton(
                                key: const Key('driverDetailsRetry'),
                                onPressed: c.loadDriverContact,
                                child: const Text('Try again'),
                              ),
                            ],
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
                              borderRadius: BorderRadius.circular(
                                MngRadius.large,
                              ),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Read this out\nto your driver',
                                    style: MngTheme.light.textTheme.bodySmall
                                        ?.copyWith(color: MngColors.onPrimary),
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
                                    style: MngTheme.light.textTheme.titleLarge
                                        ?.copyWith(
                                          color: MngColors.onPrimary,
                                          letterSpacing: trip.pickupOtp == null
                                              ? 0
                                              : 4,
                                        ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      if (c.sosRaised) ...[
                        SizedBox(height: 12.h),
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 20.w),
                          child: Container(
                            padding: EdgeInsets.all(12.w),
                            decoration: BoxDecoration(
                              color: MngColors.error.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(
                                MngRadius.small,
                              ),
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
                          child: Text(
                            c.error!,
                            style: const TextStyle(color: MngColors.error),
                          ),
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
                                // The `contact` Edge Function, which answers a rider
                                // asking about their driver as readily as a driver asking
                                // about their rider. `onPressed: () {}` was here: a
                                // live-looking button that did nothing, which is worse
                                // than no button, because a rider who presses it concludes
                                // the app cannot call and gives up rather than asking
                                // someone for the number.
                                onPressed: () => showDriverContactSheet(
                                  context,
                                  c.knownDriver,
                                  loading: c.driverContactPending,
                                  failed: c.driverContactFailed,
                                ),
                                icon: const Icon(Icons.call, size: 18),
                                label: const Text('Call'),
                              ),
                            ),
                            SizedBox(width: 10.w),
                            Expanded(
                              child: OutlinedButton.icon(
                                key: const Key('messageButton'),
                                onPressed: () => openDriverChat(
                                  context,
                                  trips: c.trips,
                                  chat: context.read<ChatRepository>(),
                                  tripId: c.trip?.id,
                                ),
                                icon: const Icon(
                                  Icons.chat_bubble_outline,
                                  size: 18,
                                ),
                                label: const Text('Message'),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: 10.h),
                      // Share, because the question a rider actually asks about
                      // a live ride is "where are you", and the answer is
                      // usually to somebody else.
                      //
                      // No coordinates in what leaves the phone: `stopLabel` is
                      // used precisely because some rows in this database carry a
                      // coordinate string in the address field, and a shared block
                      // is the last place that should leak one.
                      Padding(
                        padding: EdgeInsets.fromLTRB(20.w, 0, 20.w, 10.h),
                        child: OutlinedButton.icon(
                          key: const Key('shareRideButton'),
                          onPressed: () => ShareRideSheet.show(
                            context,
                            ride: BookedTrip(
                              trip: trip,
                              createdAt: DateTime.now(),
                            ),
                            driver: c.knownDriver,
                          ),
                          icon: const Icon(Icons.ios_share, size: 18),
                          label: const Text('Share ride details'),
                        ),
                      ),
                      if (canCancel)
                        Padding(
                          padding: EdgeInsets.fromLTRB(20.w, 0, 20.w, 12.h),
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
                          // A confirmation, because the alternative is one tap
                          // writing an irreversible `sos_events` row that nothing
                          // in this app can retract.
                          //
                          // The audit found no `showDialog` anywhere in the rider
                          // app -- not a decision against one, just nobody having
                          // written it. A mis-tap in a moving car is the ordinary
                          // case, and a false alert that teaches staff to discount
                          // this button is worse than no alert at all.
                          //
                          // Confirm rather than press-and-hold or a countdown: a
                          // rider in real distress should not have to learn a
                          // gesture first. The dialog offers cancelling, which is
                          // the entire reason it exists.
                          onPressed: c.sosRaised
                              ? null
                              : () => _confirmSos(context, c),
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
