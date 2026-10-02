import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../chat/chat_controller.dart';
import '../chat/chat_screen.dart';
import '../data/chat_repository.dart';
import '../data/trip_repository.dart';

/// Reaching the driver, from the rider's side.
///
/// Two of these decisions are the driver's app's decisions, and they are copied
/// here rather than reinvented because the rider is in the same position the
/// driver is: on a phone, in a hurry, needing a number.
///
/// **It offers a choice rather than dialling straight away.** A dialler opened
/// without asking is fine when you know the number and hostile when you do not:
/// the app cannot know whether the driver is already on a call, whether the rider
/// wants to read the number out to somebody instead, or whether the number is
/// even dialable from this handset. So the sheet offers the dialler, the
/// clipboard and a full-screen read of the digits, and the rider picks.
///
/// **A number that cannot be dialled is still shown.** `callable` is
/// `isCallableGhanaPhone`, so a driver whose number is present and malformed
/// gets `callable: false` -- and the rider is told the digits rather than being
/// offered a dialler that opens onto nothing. The same rule the driver app
/// applies to a rider.
Future<void> showDriverContactSheet(
  BuildContext context,
  DriverContact? contact, {
  bool loading = false,
  String? failed,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) =>
        _DriverContactSheet(contact: contact, loading: loading, failed: failed),
  );
}

/// Open the conversation with the driver on [tripId].
///
/// A no-op when there is no trip, rather than a push to a screen with no
/// conversation in it.
///
/// The rider's `ChatController` opens a *booked* trip -- the chat tab lists past
/// rides and the rider picks one. That is right for a tab and wrong for a live
/// ride: a rider pressing "Message" during a trip means the trip they are in,
/// and making them pick it back out of a list of past rides is a step nobody
/// should have to take mid-journey. So the live trip is opened directly.
Future<void> openDriverChat(
  BuildContext context, {
  required TripRepository trips,
  required ChatRepository chat,
  required String? tripId,
}) async {
  if (tripId == null) return;
  final controller = ChatController(trips: trips, chat: chat);
  final ride = await controller.bookedTrip(tripId);
  if (ride == null) return;
  await controller.openTrip(ride);
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ChangeNotifierProvider<ChatController>.value(
        value: controller,
        child: const ChatScreen(forOneTrip: true),
      ),
    ),
  );
}

class _DriverContactSheet extends StatelessWidget {
  const _DriverContactSheet({this.contact, this.loading = false, this.failed});

  final DriverContact? contact;
  final bool loading;
  final String? failed;

  @override
  Widget build(BuildContext context) {
    final theme = MngTheme.light.textTheme;
    final driver = contact;

    // Three states, three sentences. Collapsing them is what makes a screen feel
    // broken: "we are still asking", "we asked and could not find out" and "this
    // driver has no number on file" are different facts and a rider who is told
    // the wrong one will not act on any of them.
    if (loading) {
      return _body(
        context,
        title: 'Getting your driver\'s number',
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (driver == null) {
      return _body(
        context,
        title: 'Call your driver',
        child: Text(
          failed ?? 'Your driver\'s details are not available yet.',
          key: const Key('driverContactUnavailable'),
          style: theme.bodySmall,
        ),
      );
    }

    final hasNumber = driver.phone.isNotEmpty;
    final name = driver.name.isEmpty ? 'Your driver' : driver.name;

    return _body(
      context,
      title: name,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (driver.hasCar) ...[
            Row(
              children: [
                const Icon(Icons.directions_car, size: 18),
                SizedBox(width: 6.w),
                Expanded(
                  child: RichText(
                    key: const Key('driverContactCar'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    text: TextSpan(
                      style: theme.bodyMedium,
                      children: [
                        if (driver.car.isNotEmpty)
                          TextSpan(text: '${driver.car} '),
                        // The plate in bold, and last, because the plate is what
                        // the rider reads off a windscreen from across a
                        // forecourt. The model is a confirmation of it.
                        TextSpan(
                          text: driver.plate,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: 12.h),
          ],
          if (!hasNumber)
            Text(
              // One sentence for both cases on purpose. A driver with no number
              // and a driver whose number will not dial are the same fact from a
              // rider's side: there is nothing here to call, and the useful thing
              // to do is read the plate off the windscreen instead.
              'Your driver has not added a phone number.',
              key: const Key('driverContactNoNumber'),
              style: theme.bodySmall,
            )
          else ...[
            // The number in full, always, whatever the dialler can do with it.
            // This is the whole fallback for a number that will not dial.
            Text(
              // `formatGhanaPhone` is null-safe and returns null for a number it
              // cannot format, which `hasNumber` above has already excluded --
              // but a null here would print the word "null" to a rider standing
              // at a rank, so the fallback is the stored digits rather than
              // silence.
              formatGhanaPhone(driver.phone) ?? driver.phone,
              key: const Key('driverContactNumber'),
              style: theme.titleMedium,
            ),
            SizedBox(height: 16.h),
            if (driver.callable)
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const Key('driverContactCall'),
                  onPressed: () => _dial(context),
                  icon: const Icon(Icons.call),
                  label: const Text('Call'),
                ),
              ),
            if (driver.callable) SizedBox(height: 8.h),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const Key('driverContactCopy'),
                onPressed: () => _copy(context),
                icon: const Icon(Icons.copy),
                label: const Text('Copy number'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _body(
    BuildContext context, {
    required String title,
    required Widget child,
  }) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20.w, 20.h, 20.w, 20.h),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: MngTheme.light.textTheme.titleLarge),
            SizedBox(height: 12.h),
            child,
          ],
        ),
      ),
    );
  }

  Future<void> _dial(BuildContext context) async {
    final uri = ghanaTelUri(contact!.phone);
    if (uri == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await launchUrl(Uri.parse(uri));
    if (!ok) {
      // The dialler refused, which on a device with no telephony app is the
      // normal case rather than an error. Say so, because the alternative is a
      // button that appears to work and leaves the rider with nothing.
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(content: Text('No dialler app on this phone')),
        );
    }
  }

  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: contact!.phone));
    messenger
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('Number copied')));
  }
}
