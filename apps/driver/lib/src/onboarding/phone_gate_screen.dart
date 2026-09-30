import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

/// Shown when a driver has everything except a phone number.
///
/// Every driver signed up before the phone field existed has `phone = ''`, and
/// every one of them is reachable by nobody. This is the screen they get on the
/// next app open, and it is the whole of what the "force them to add it" asks
/// for: one field, one screen, no deletion and no re-verification.
///
/// Two decisions worth stating, both of which came from what deleting would have
/// cost:
///
/// **Nothing is deleted, and nothing else is touched.** The alternative was to
/// remove the driver accounts so they would re-register and get a fresh form with
/// a phone on it. That would have taken, at the time it was considered, 14
/// documents, 3 vehicles, 2 trips, 2 ledger entries and GHS 6.07 of completed
/// work with them -- because `profiles` is the parent of `driver_documents`,
/// `vehicles`, `trips`, `ledger_entries` and `payouts`, and `trips.rider_id`
/// cascades too, so a driver who had also ridden would have lost those rides.
/// A driver's verified identity is the one thing the business cannot re-issue at
/// a keystroke. So the missing field is asked for instead.
///
/// **It appears after onboarding, not during it.** A driver who is already
/// approved should not be sent back through six document uploads to add one
/// field; that is what makes a driver give up. This screen is one screen, after
/// the approval they already have.
///
/// The screen is not dismissible and has no back button, on purpose: it is a
/// gate, not a prompt. A driver who cannot be called cannot take a passenger, so
/// the app has nothing to offer them until the number exists. Skipping it would
/// mean being reachable by nobody for as long as they skip it.
class PhoneGateScreen extends StatefulWidget {
  const PhoneGateScreen({super.key, required this.onSaved});

  /// Called once the number is written, so the shell can let them through.
  final Future<void> Function(String phone) onSaved;

  @override
  State<PhoneGateScreen> createState() => _PhoneGateScreenState();
}

class _PhoneGateScreenState extends State<PhoneGateScreen> {
  final _controller = TextEditingController();
  String? _problem;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Same rule as the sign-up form, from the same function. Two screens cannot
  /// disagree about what a Ghanaian number is, and the second one to disagree
  /// would be the one that silently writes a number nothing can dial.
  String? _validate(String typed) {
    final trimmed = typed.trim();
    if (trimmed.isEmpty) return 'Enter the number a rider would use to reach you';
    if (isCallableGhanaPhone(trimmed)) return null;
    final digits = trimmed.replaceAll(RegExp(r'[^0-9]'), '').length;
    if (digits < 9) return 'That looks too short. Enter 10 digits, e.g. 0241234567';
    if (digits > 10) return 'That looks too long. Enter 10 digits, e.g. 0241234567';
    // Ten digits and still refused, so the prefix is not one Ghana issues. Saying
    // so is better than asking a driver who has just typed ten digits to type ten
    // digits.
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
      // The shell replaces this screen the moment the profile stream reports the
      // number, so there is nothing to pop and no success message: the next
      // thing the driver sees is the home screen.
      //
      // The busy flag is cleared anyway, on the off chance that the write
      // landed but the screen is still here. That happens if the realtime stream
      // drops the event, or if `onSaved` returns before the new profile has been
      // read. Left set, this becomes a spinner that never stops and a button
      // that never re-enables -- a driver staring at a dead screen with no
      // indication of what went wrong, on the one screen they cannot leave.
      // Clearing it means they can simply tap Save again.
      if (!mounted) return;
      setState(() => _busy = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // The failure is a write failure, not a validation failure, so it does
        // not sit under the field pretending to be about what they typed.
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
      // usable, and a back arrow that returns a driver to an empty home screen
      // with a disabled Call button teaches them the app is broken.
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            // Scrollable rather than centred-and-fixed, because the keyboard
            // covers the bottom half of a 390x844 screen and a field behind the
            // keyboard is a field the driver cannot see they are typing into.
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
                  'Riders cannot reach you without it. Add one to carry '
                  'passengers.',
                  textAlign: TextAlign.center,
                  style: theme.bodyMedium?.copyWith(color: MngColors.textSub),
                ),
                SizedBox(height: 28.h),
                TextField(
                  key: const Key('phoneGateField'),
                  controller: _controller,
                  autofocus: true,
                  enabled: !_busy,
                  keyboardType: TextInputType.phone,
                  // The phone keypad: a number field with a full keyboard is a
                  // field every driver fights with, and the first thing anyone
                  // does here is type ten numbers.
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9+ ]')),
                    LengthLimitingTextInputFormatter(20),
                  ],
                  onChanged: (v) {
                    // Clear the error as soon as they start fixing it, so the
                    // message is not still accusing them of the thing they are
                    // halfway through correcting.
                    if (_problem != null) setState(() => _problem = _validate(v));
                  },
                  onSubmitted: (_) => _save(),
                  decoration: InputDecoration(
                    hintText: '024 123 4567',
                    prefixIcon: const Icon(Icons.phone_outlined),
                    helperText: _problem == null ? 'Any format is fine' : null,
                    errorText: _problem,
                  ),
                ),
                SizedBox(height: 20.h),
                FilledButton(
                  key: const Key('phoneGateSaveButton'),
                  onPressed: _busy ? null : _save,
                  child: _busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save and continue'),
                ),
                SizedBox(height: 12.h),
                Text(
                  'You do not need to upload anything again. Your documents '
                  'are already approved.',
                  textAlign: TextAlign.center,
                  style: theme.bodySmall?.copyWith(color: MngColors.textSub),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}