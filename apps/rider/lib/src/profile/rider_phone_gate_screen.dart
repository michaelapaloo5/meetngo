import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

/// Shown when a rider has everything except a phone number.
///
/// The rider app's sign-up form asks for a name, an email and a password, and
/// nothing else. `profiles.phone` is `NOT NULL` **with a default of `''`**, so
/// the row is written, nothing fails, and the rider is told they have an account
/// -- with no number on it and no prompt to add one. The profile screen shows
/// "Not set" and stops there.
///
/// That is a live failure, not a cosmetic one. Every driver on every ride of
/// theirs hits the driver app's own designed path for it -- `contact` answers
/// `callable: false` and the driver's contact sheet says "This rider has not
/// added a phone number." A rider who cannot be called cannot be picked up, and
/// the cost lands on the driver, in traffic, with a stranger.
///
/// So the rider gets the gate the driver already has: one field, one screen,
/// and no way past it until it is filled. Nothing is deleted and no existing
/// account is disturbed -- this is asked for, not re-issued, for the same reason
/// the driver's gate asks rather than deletes.
///
/// Not dismissible and no back button, on purpose: it is a gate, not a prompt.
class RiderPhoneGateScreen extends StatefulWidget {
  const RiderPhoneGateScreen({super.key, required this.onSaved});

  /// Called once the number is written, so the shell can let them through.
  final Future<void> Function(String phone) onSaved;

  @override
  State<RiderPhoneGateScreen> createState() => _RiderPhoneGateScreenState();
}

class _RiderPhoneGateScreenState extends State<RiderPhoneGateScreen> {
  final _controller = TextEditingController();
  String? _problem;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The same rule the driver gate uses, from the same function, so two screens
  /// cannot disagree about what a Ghanaian number is. A second one that
  /// disagreed would be the one silently writing a number nothing can dial.
  String? _validate(String typed) {
    final trimmed = typed.trim();
    if (trimmed.isEmpty) {
      return 'Enter the number your driver would use to reach you';
    }
    if (isCallableGhanaPhone(trimmed)) return null;
    final digits = trimmed.replaceAll(RegExp(r'[^0-9]'), '').length;
    if (digits < 9) {
      return 'That looks too short. Enter 10 digits, e.g. 0241234567';
    }
    if (digits > 10) {
      return 'That looks too long. Enter 10 digits, e.g. 0241234567';
    }
    return 'That does not start like a Ghanaian number. It should begin 020, 024, 050, 055 or 059.';
  }

  Future<void> _save() async {
    final typed = _controller.text;
    final problem = _validate(typed);
    setState(() => _problem = problem);
    if (problem != null) return;

    setState(() => _busy = true);
    try {
      await widget.onSaved(normaliseGhanaPhone(typed)!);
      // The shell replaces this screen when the profile reports the number, so
      // there is nothing to pop. The flag is cleared anyway: if the write landed
      // but the profile stream has not been read back, this becomes a spinner
      // that never stops on the one screen the rider cannot leave.
      if (!mounted) return;
      setState(() => _busy = false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // A write failure, not a validation failure, so it does not sit under
        // the field pretending to be about what they typed.
        _problem = 'Could not save. Check your connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = MngTheme.light.textTheme;
    return Scaffold(
      backgroundColor: MngColors.page,
      // No AppBar and no back button: there is nowhere to go back to that is
      // usable, and a back arrow into an app a rider cannot use teaches them the
      // app is broken.
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            // Scrollable rather than fixed, because the keyboard covers the
            // bottom half of a 390x844 screen and a field behind the keyboard is
            // a field nobody can see they are typing into.
            padding: EdgeInsets.fromLTRB(24.w, 24.h, 24.w, 24.h),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.phone_in_talk_outlined,
                  size: 48,
                  color: MngColors.textSub,
                ),
                SizedBox(height: 20.h),
                Text(
                  'Add your phone number',
                  textAlign: TextAlign.center,
                  style: theme.titleLarge,
                ),
                SizedBox(height: 8.h),
                Text(
                  'Your driver cannot reach you without it. Add one before you '
                  'book.',
                  textAlign: TextAlign.center,
                  style: theme.bodyMedium?.copyWith(color: MngColors.textSub),
                ),
                SizedBox(height: 28.h),
                TextField(
                  key: const Key('riderPhoneGateField'),
                  controller: _controller,
                  enabled: !_busy,
                  keyboardType: TextInputType.phone,
                  // The phone keypad. A number field with a full keyboard is a
                  // field everyone fights with.
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9+ ]')),
                  ],
                  decoration: InputDecoration(
                    labelText: 'Phone number',
                    hintText: '0241234567',
                    border: const OutlineInputBorder(),
                    errorText: _problem,
                  ),
                ),
                SizedBox(height: 24.h),
                FilledButton(
                  key: const Key('riderPhoneGateSave'),
                  onPressed: _busy ? null : _save,
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: MngColors.onPrimary,
                          ),
                        )
                      : const Text('Save'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
