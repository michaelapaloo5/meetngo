import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

import '../data/booked_trip.dart';
import '../data/trip_repository.dart';
import 'trip_copy.dart';

/// Share the ride, for somebody who needs to know where the rider is.
///
/// The use case is not social. It is a rider texting a flatmate "on my way, this
/// is the plate", or sending the trip to somebody waiting at the destination, or
/// a family member who needs the driver's name and plate. So the thing being
/// shared is a short block of *facts* rather than a link -- there is no web page
/// for this trip to link to, and inventing a URL that resolves to nothing would
/// be worse than no button.
///
/// Deliberately text rather than a screenshot or an image: the recipient can
/// read the plate out of it, paste it into a map app, and forward it without
/// this app being installed.
///
/// No coordinates. `stopLabel` and `addressForDisplay` are used precisely because
/// some rows in this database carry a coordinate string in the address field --
/// see the note in `trip_copy.dart` -- and a shared block is the last place that
/// should leak one.
class ShareRideSheet extends StatelessWidget {
  const ShareRideSheet({super.key, required this.ride, this.driver});

  final BookedTrip ride;

  /// The driver's name and plate, when the trip is live and the lookup
  /// succeeded. Null on a past trip, and the sheet says so rather than
  /// pretending the rider's car had no driver.
  final DriverContact? driver;

  /// The text that gets shared.
  ///
  /// A top-level function rather than something read off the widget, because the
  /// exact string is the feature: a test can pin it, and a reviewer can read
  /// every word that leaves the phone without running the app.
  static String summaryFor(BookedTrip ride, {DriverContact? driver}) {
    final trip = ride.trip;
    final buffer = StringBuffer()
      ..writeln('Meet \'N Go ride')
      ..writeln('From: ${stopLabel(trip.pickup)}')
      ..writeln('To: ${stopLabel(trip.dropoff)}')
      ..writeln('Status: ${tripStateLabel(trip.state)}')
      ..writeln('Fare: ${formatGhs(trip.fareGhs)}');
    final who = driver;
    if (who != null && who.name.isNotEmpty) {
      buffer.writeln('Driver: ${who.name}');
    }
    if (who != null && who.plate.isNotEmpty) {
      buffer.writeln('Plate: ${who.plate}');
    }
    if (who != null && who.callable && who.phone.isNotEmpty) {
      buffer.writeln('Phone: ${who.phone}');
    }
    return buffer.toString().trimRight();
  }

  static Future<void> show(
    BuildContext context, {
    required BookedTrip ride,
    DriverContact? driver,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ShareRideSheet(ride: ride, driver: driver),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = MngTheme.light.textTheme;
    final text = summaryFor(ride, driver: driver);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20.w, 20.h, 20.w, 20.h),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Share ride', style: theme.titleLarge),
            SizedBox(height: 4.h),
            Text(
              'Send these details to somebody waiting for you.',
              style: theme.bodySmall?.copyWith(color: MngColors.textSub),
            ),
            SizedBox(height: 14.h),
            // Selectable, and in a container rather than bare on the sheet, so
            // the recipient is clearly being shown a block of text rather than
            // body copy -- and so the rider can drag-select a single line out of
            // it if they would rather not copy the whole thing.
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(12.w),
              decoration: BoxDecoration(
                color: MngColors.muted,
                borderRadius: BorderRadius.circular(MngRadius.large),
              ),
              child: SelectableText(
                text,
                key: const Key('shareRideText'),
                style: theme.bodySmall,
              ),
            ),
            SizedBox(height: 16.h),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('shareRideCopy'),
                onPressed: () => _copy(context, text),
                icon: const Icon(Icons.copy),
                label: const Text('Copy details'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copy(BuildContext context, String text) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: text));
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(
          key: Key('shareRideCopied'),
          content: Text('Ride details copied'),
        ),
      );
  }
}
