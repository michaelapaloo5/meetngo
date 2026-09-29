import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

import '../location/location_banner.dart';
import '../location/location_controller.dart';
import '../map/driver_map_panel.dart';
import 'availability_controller.dart';
import 'offer_card.dart';
import 'offer_queue_controller.dart';

/// The home tab: the toggle, where the driver is, and whatever is in the queue.
///
/// The two controllers are constructor arguments rather than read from
/// `context`, so the screen can be driven by a fake with no provider above it
/// and so what the screen reads and what the test holds are the same object.
/// The plan's version took both as arguments and then read the queue from
/// `context` and the toggle from `context`, which meant the arguments were
/// decoration.
///
/// Which means the listeners have to come from the arguments too. A screen that
/// reads a `ChangeNotifier` it holds and never listens to it is a screen that
/// does not change: the toggle writes `online` and the title still reads the
/// value from before. `ListenableBuilder` over all three is the whole
/// subscription, and it needs no provider at all.
class DriverHomeScreen extends StatelessWidget {
  const DriverHomeScreen({
    super.key,
    required this.availability,
    required this.offers,
    required this.profile,
    required this.location,
    this.onAccepted,
  });

  final AvailabilityController availability;
  final OfferQueueController offers;
  final DriverProfile? profile;
  final LocationController location;

  /// Called after the server confirms the driver won an offer -- not when they
  /// pressed Accept, which is the difference between "I asked" and "it is mine".
  final Future<void> Function()? onAccepted;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([availability, offers, location]),
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          backgroundColor: MngColors.page,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          title: Text(
            availability.online ? 'You are online' : 'You are offline',
            style: MngTheme.light.textTheme.titleLarge,
          ),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if ((profile?.fullName ?? '').isNotEmpty)
                      Text(
                        'Hello, ${profile!.fullName}',
                        style: MngTheme.light.textTheme.titleMedium,
                      ),
                    SizedBox(height: 8.h),
                    SwitchListTile(
                      key: const Key('onlineToggle'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Accept ride requests'),
                      subtitle: Text(
                        'Ride requests go to drivers within 5 km who have shared '
                        'their location.',
                        style: MngTheme.light.textTheme.bodySmall,
                      ),
                      value: availability.online,
                      onChanged: availability.canToggle
                          ? availability.setOnline
                          : null,
                    ),
                    if (availability.refusalReason != null)
                      Text(
                        availability.refusalReason!,
                        key: const Key('availabilityRefusal'),
                        style: const TextStyle(color: MngColors.error),
                      ),
                    if (availability.error != null)
                      Text(
                        availability.error!,
                        key: const Key('availabilityError'),
                        style: const TextStyle(color: MngColors.error),
                      ),
                  ],
                ),
              ),
              // The driver, on a real map. No pickup pin: the queue holds
              // several trips at once and pinning one of them would claim it is
              // the trip the driver is on.
              LocationBanner(location: location),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 20.w),
                // The driver's own car, with the heading, so the offer queue's
                // map shows which way they are facing rather than a bare dot
                // that could be anywhere.
                child: DriverMapPanel(
                  driverPoint: location.point,
                  driverHeading: location.heading,
                ),
              ),
              Expanded(
                child: offers.offers.isEmpty
                    ? Center(
                        child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: 40.w),
                          child: Text(
                            availability.online
                                ? 'Waiting for ride requests near you'
                                : 'Go online to start receiving requests',
                            textAlign: TextAlign.center,
                            style: MngTheme.light.textTheme.bodySmall,
                          ),
                        ),
                      )
                    : ListView(
                        children: [
                          for (final offer in offers.offers)
                            OfferCard(
                              offer: offer,
                              onAccept: () async {
                                if (await offers.accept(offer)) {
                                  await onAccepted?.call();
                                }
                              },
                              onDecline: () => offers.decline(offer),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
