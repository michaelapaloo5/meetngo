import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:url_launcher/url_launcher.dart';

import 'contact_controller.dart';

/// How a call was made, so the caller can report it and the test can assert it.
enum CallOutcome {
  /// The dialler was opened with the number.
  dialled,

  /// The number was copied to the clipboard.
  copied,

  /// The number was shown, for the driver to read out or dial by hand.
  shown,

  /// Nothing happened: there was no number, or the launch failed.
  failed,
}

/// The two ways to reach somebody, offered together.
///
/// A single "Call" button is not enough, and the reason is the phone rather than
/// the design. `url_launcher` hands the number to whatever handles `tel:` on the
/// device, and on a handset with no dialler configured, no SIM, or a restricted
/// profile it goes nowhere: the intent fires, nothing answers, and the driver's
/// only feedback is that the screen did not change. On a phone in the pilot that
/// is a real possibility, not a theoretical one.
///
/// So the sheet always offers both, and the *display* is not a fallback hidden
/// behind an error. The digits are on screen whether or not the dialler works,
/// because a driver who can read `024 123 4567` has three options -- call it,
/// read it out to the rider, or write it down -- and only one of them needs an
/// app to cooperate.
///
/// The number is shown, not hidden behind a tap, because the moment this sheet
/// is open is the moment somebody needs the number, and a number behind a second
/// button is a number somebody does not find.
class ContactSheet extends StatefulWidget {
  const ContactSheet({super.key, required this.contact});

  final Contact contact;

  /// Opens the sheet and reports what the driver chose.
  static Future<CallOutcome?> show(BuildContext context, Contact contact) {
    return showModalBottomSheet<CallOutcome>(
      context: context,
      backgroundColor: MngColors.page,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => ContactSheet(contact: contact),
    );
  }

  @override
  State<ContactSheet> createState() => _ContactSheetState();
}

class _ContactSheetState extends State<ContactSheet> {
  CallOutcome? _last;
  String? _message;

  Contact get contact => widget.contact;

  @override
  Widget build(BuildContext context) {
    final theme = MngTheme.light.textTheme;
    final name = contact.shortName;
    final heading = name.isEmpty ? contact.roleLabel : '$name (${contact.roleLabel})';

    return SafeArea(
      child: SingleChildScrollView(
        // Scrollable rather than a fixed Column. The "no number" case is the tall
        // one -- a two-line message instead of one line of digits -- and it
        // overflowed the bottom by 18 pixels at 390x844, which is a phone size
        // this app is built for. A sheet that clips its own call to action is
        // worse than one that scrolls, and the alternative -- dropping the Close
        // button when there is no number -- would remove the only way out for
        // somebody whose phone has no back gesture.
        child: Padding(
          padding: EdgeInsets.fromLTRB(20.w, 16.h, 20.w, 20.h),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: MngColors.divider,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              SizedBox(height: 16.h),
              Text('Call $heading', style: theme.titleMedium),
              SizedBox(height: 16.h),

            // The number, always visible and always selectable. This is the point
            // of the sheet: a driver whose phone cannot dial can still read it.
            if (contact.display != null)
              SelectableText(
                contact.display!,
                key: const Key('contactNumber'),
                textAlign: TextAlign.center,
                style: theme.headlineSmall?.copyWith(letterSpacing: 1),
              )
            else
              // No number. Say so plainly rather than showing an empty field the
              // driver will read as a number that failed to load.
              Container(
                key: const Key('contactNoNumber'),
                padding: EdgeInsets.symmetric(vertical: 12.h, horizontal: 16.w),
                decoration: BoxDecoration(
                  color: MngColors.muted,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  name.isEmpty
                      ? 'This ${contact.roleLabel.toLowerCase()} has not added a '
                          'phone number.'
                      : '$name has not added a phone number.',
                  textAlign: TextAlign.center,
                  style: theme.bodyMedium,
                ),
              ),
            SizedBox(height: 20.h),

            if (_message != null) ...[
              Text(
                _message!,
                key: const Key('contactMessage'),
                textAlign: TextAlign.center,
                style: theme.bodySmall,
              ),
              SizedBox(height: 12.h),
            ],

            // "Call" first and primary, because it is what almost everybody
            // wants. "Copy" and "Show" are beside it rather than below it,
            // because they are peers: a driver picking the wrong one should be
            // one glance away from the right one, not one scroll.
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    key: const Key('contactDialButton'),
                    // Disabled rather than hidden when there is nothing to dial.
                    // A hidden button leaves the sheet with no primary action and
                    // a driver wondering what to do; a disabled one says "there
                    // is nothing here to call" in the place they are looking.
                    onPressed: contact.callable ? _dial : null,
                    icon: const Icon(Icons.call),
                    label: const Text('Call'),
                  ),
                ),
                SizedBox(width: 12.w),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('contactCopyButton'),
                    onPressed: contact.display == null ? null : _copy,
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy'),
                  ),
                ),
              ],
            ),
            SizedBox(height: 10.h),
            OutlinedButton.icon(
              key: const Key('contactShowButton'),
              onPressed: contact.display == null ? null : _show,
              icon: const Icon(Icons.visibility_outlined),
              label: const Text('Show the number full screen'),
            ),
            SizedBox(height: 8.h),
            TextButton(
              key: const Key('contactCloseButton'),
              onPressed: () => Navigator.of(context).pop(_last),
              child: const Text('Close'),
            ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _dial() async {
    final uri = contact.telUri;
    if (uri == null) {
      _report(CallOutcome.failed, 'That number cannot be called from this phone.');
      return;
    }
    try {
      final launched = await launchUrl(
        Uri.parse(uri),
        mode: LaunchMode.externalApplication,
      );
      // `launchUrl` returns false when a `tel:` intent fired and nothing
      // handled it, which is the exact case this sheet exists for: a device with
      // no dialler. Reporting it here, with the number still on screen above, is
      // the whole design -- the driver reads the number and dials it by hand.
      if (!launched) {
        _report(
          CallOutcome.shown,
          'This phone has no dialler. Read or copy the number above.',
        );
        return;
      }
      _report(CallOutcome.dialled, null);
    } catch (e) {
      // A missing `tel:` handler throws rather than returning false on some
      // platforms, so both failure shapes are handled and neither leaves the
      // driver with a button that did nothing.
      _report(
        CallOutcome.shown,
        'Could not open the dialler. Read or copy the number above.',
      );
    }
  }

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: contact.display ?? contact.phone));
      _report(CallOutcome.copied, 'Copied. Paste it into a message or a call.');
    } catch (e) {
      _report(CallOutcome.failed, 'Could not copy the number.');
    }
  }

  void _show() {
    // A full-screen page rather than a second dialog: the point of "show" is that
    // the digits are readable from arm's length in daylight, which a bottom sheet
    // in a bottom sheet is not.
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _FullScreenNumber(contact: contact),
      ),
    );
  }

  void _report(CallOutcome outcome, String? message) {
    setState(() {
      _last = outcome;
      _message = message;
    });
  }
}

/// The number, alone, as big as the screen allows.
class _FullScreenNumber extends StatelessWidget {
  const _FullScreenNumber({required this.contact});

  final Contact contact;

  @override
  Widget build(BuildContext context) {
    final theme = MngTheme.light.textTheme;
    return Scaffold(
      backgroundColor: MngColors.page,
      appBar: AppBar(
        backgroundColor: MngColors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('Phone number'),
      ),
      body: Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 24.w),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                contact.shortName.isEmpty
                    ? contact.roleLabel
                    : contact.shortName,
                key: const Key('fullScreenName'),
                style: theme.titleMedium,
              ),
              SizedBox(height: 20.h),
              SelectableText(
                contact.display ?? 'No number',
                key: const Key('fullScreenNumber'),
                textAlign: TextAlign.center,
                style: theme.displaySmall?.copyWith(letterSpacing: 2),
              ),
              SizedBox(height: 12.h),
              Text(
                'Read it out, or dial it by hand.',
                style: theme.bodySmall,
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 28.h),
              if (contact.callable)
                FilledButton.icon(
                  key: const Key('fullScreenCallButton'),
                  onPressed: () async {
                    final uri = contact.telUri;
                    if (uri == null) return;
                    await launchUrl(
                      Uri.parse(uri),
                      mode: LaunchMode.externalApplication,
                    );
                  },
                  icon: const Icon(Icons.call),
                  label: Text('Call ${contact.shortName}'.trim()),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
