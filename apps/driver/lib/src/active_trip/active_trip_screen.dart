import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

import '../contact/contact_controller.dart';
import '../contact/contact_sheet.dart';
import '../chat/chat_controller.dart';
import '../chat/chat_screen.dart';
import '../location/location_banner.dart';
import '../location/location_controller.dart';
import '../map/driver_map_panel.dart';
import 'active_trip_controller.dart';
import 'pickup_otp_sheet.dart';

class ActiveTripScreen extends StatelessWidget {
  const ActiveTripScreen({
    super.key,
    required this.onFinished,
    required this.location,
    required this.contact,
    this.chatRepository,
    this.driverId,
  });

  /// Called when the driver presses the button on a finished trip.
  final VoidCallback onFinished;

  /// The driver's own position, for the map. An argument rather than a
  /// provider read, and the body is wrapped in a `ListenableBuilder` over it,
  /// because a fix that arrives after the first frame has to move the pin.
  final LocationController location;

  /// The other party on this trip, for the call sheet.
  ///
  /// An argument rather than a provider read, matching [location] and for the
  /// same reason: this screen must be renderable in a test with no network and
  /// no Supabase client. The controller is read through a `ListenableBuilder`
  /// below, so a number that arrives after the first frame reaches the button.
  final ContactController contact;

  /// Where chat messages come from, or null when chat is not wired in.
  ///
  /// Optional on purpose. Every existing `DriverFlow(...)` in the test suite
  /// builds a flow with no chat repository, and making this required would mean
  /// touching all of them to add a dependency that most of those tests are not
  /// about. Null is a real state -- a build without chat -- and the screen handles
  /// it by saying so rather than by failing.
  final ChatRepository? chatRepository;

  /// The signed-in driver's own profile id, for deciding which chat bubbles are
  /// theirs. Null when the flow has not loaded a profile; the chat is then closed
  /// anyway by [chatRepository] being null in the same build.
  final String? driverId;

  /// What the two buttons the plan put on this screen cannot do yet.
  ///
  /// `url_launcher` is not a dependency of this app and a phone in the pilot
  /// has no navigation app configured, so a button that launched it would fail
  /// on the device that matters. The plan's `onPressed: () {}` was worse: a
  /// live-looking control that does nothing at all. This says what is missing
  /// instead -- and the map above the buttons is what the driver uses to
  /// navigate, which is the honest replacement.
  static const _notInThisBuild =
      'Turn-by-turn navigation is not part of this build. Follow the map above.';

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
          : ListenableBuilder(
              listenable: location,
              builder: (context, _) => _tripBody(context, controller, trip),
            ),
    );
  }

  Widget _tripBody(
    BuildContext context,
    ActiveTripController controller,
    Trip trip,
  ) {
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
            child: Row(
              children: [
                // `Flexible` on the row, not inside the chip: the chip is a
                // `Container`, and a `Flexible` inside one has no `Flex`
                // ancestor to apply its parent data to. Out here it is what
                // gives the chip a bounded width, so a long state name
                // ellipsizes instead of pushing the fare off the row.
                Flexible(
                  child: Container(
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
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: MngTheme.light.textTheme.bodySmall,
                    ),
                  ),
                ),
                const Spacer(),
                Flexible(
                  child: Text(
                    'GHS ${trip.fareGhs.toStringAsFixed(2)}',
                    overflow: TextOverflow.ellipsis,
                    style: MngTheme.light.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
          ),
          LocationBanner(location: location),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 20.w),
            child: DriverMapPanel(
              // The driver, the pickup and the drop-off, with a line from the
              // driver to the pickup while collecting and from the pickup to
              // the drop-off once the rider is aboard. Before the fix lands the
              // panel says so rather than showing an empty rectangle.
              driverPoint: location.point,
              // With it, the driver's own car is drawn pointed the way they are
              // driving rather than as a dot. Without a compass reading nothing
              // is drawn rather than something drawn pointing north, which on a
              // driver's own map would be a car going the wrong way up their
              // own street.
              driverHeading: location.heading,
              pickup: trip.pickup.point,
              dropoff: trip.dropoff.point,
              height: 200.h,
            ),
          ),
          SizedBox(height: 8.h),
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
                // Rebuilt when the contact controller changes, so the button
                // wakes when the number arrives. Without this the button is
                // rendered once with no contact, stays disabled for the rest of
                // the trip, and a driver who presses it concludes calling is
                // broken -- which is exactly what the button said it was before
                // this feature existed.
                ListenableBuilder(
                  listenable: contact,
                  builder: (context, _) => Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const Key('navigateButton'),
                          onPressed: () => _say(context, _notInThisBuild),
                          icon: const Icon(Icons.navigation),
                          label: const Text('Navigate'),
                        ),
                      ),
                      SizedBox(width: 12.w),
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const Key('callRiderButton'),
                          // Opens the contact sheet, which offers the dialler,
                          // the clipboard and a full-screen read of the number.
                          // The label says who, once the number has loaded,
                          // because "Call Michael" and "Call" are different
                          // levels of reassurance and a driver about to dial a
                          // stranger's number wants both.
                          onPressed: contact.contact == null
                              ? null
                              : () => ContactSheet.show(context, contact.contact!),
                          icon: const Icon(Icons.call),
                          label: Text(
                            contact.contact?.actionLabel ??
                                (contact.busy ? 'Loading...' : 'Call'),
                            key: const Key('callRiderLabel'),
                            // One line, ellipsised: a name long enough to wrap
                            // pushes the button's height out of line with
                            // Navigate beside it.
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 12.h),
                // Chat and, once it exists, reporting a left item: the two things
                // a driver needs during a trip rather than at its end.
                //
                // Full width rather than a third of the row above. Three buttons
                // across 390 logical pixels leaves about 110 each, which is below
                // the 48-pixel touch target once the icon and the label are in it,
                // and a driver pressing this one-handed in traffic is the exact
                // person a too-small target fails.
                OutlinedButton.icon(
                  key: const Key('chatRiderButton'),
                  onPressed: () => _openChat(context),
                  icon: const Icon(Icons.chat_bubble_outline),
                  label: const Text('Message rider'),
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
    );
  }

  void _say(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Open the conversation with this trip's rider.
  ///
  /// The repository comes from the widget rather than from the flow, because chat
  /// is reached from exactly one place and a `ChatRepository` in the flow's
  /// constructor list would be a dependency that the twenty-odd `DriverFlow(...)`
  /// calls in the test suite do not have and do not need.
  ///
  /// Falls back to a sentence rather than opening an empty thread when there is
  /// no repository -- which is the state every existing flow is in. A crash here
  /// would take down the screen a driver is using to run a live trip, over a
  /// feature that is not what they pressed.
  void _openChat(BuildContext context) {
    final trip = context.read<ActiveTripController>().trip;
    final repo = chatRepository;
    if (trip == null || repo == null) {
      _say(
        context,
        'Messages are not available right now. You can still call the rider.',
      );
      return;
    }
    final riderName = context.read<ContactController>().contact?.name ?? 'Rider';
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(
          controller: ChatController(myId: driverId ?? '', tripId: trip.id)
            ..repository = repo,
          riderName: riderName,
        ),
      ),
    );
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
