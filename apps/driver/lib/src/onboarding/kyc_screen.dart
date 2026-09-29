import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

import 'document_scanner_stub.dart';
import 'kyc_controller.dart';
import 'vehicle_form.dart';

/// The driver's verification flow.
///
/// Reads the server's answer on open, so a driver who force-closed the app
/// half-way through comes back to the step they had reached rather than to the
/// first one. This was found on a device: every completed step looked as though
/// it had never happened, because the step was only ever held in memory.
///
/// The read is fired once, from [initState], and its answer is applied through
/// the controller, so the screen's own rebuilds cannot start a second read.
class KycScreen extends StatefulWidget {
  const KycScreen({
    super.key,
    required this.controller,
    this.cardScanner,
    this.selfieScanner,
    this.onContinue,
  });

  final KycController controller;

  /// Not wired to a card scan. There is no OCR engine in this build, so
  /// `KycScreen` never offers to scan a card: the plan's version had a button
  /// that called `applyScan` on a hard-coded `'GHA-123456789-0 / JANE COOPER'`
  /// string and threw the captured path away, which prefilled every driver's
  /// card with somebody else's card and looked correct. What is here instead
  /// takes the scan text as text, which is honest about where it came from and
  /// exercises the same parser.
  final DocumentScanner? cardScanner;

  final DocumentScanner? selfieScanner;

  /// Called from the `approved` step's button. The shell wires this to a
  /// profile re-read, so the app only leaves the KYC flow when the server
  /// agrees the driver is approved.
  final VoidCallback? onContinue;

  @override
  State<KycScreen> createState() => _KycScreenState();
}

class _KycScreenState extends State<KycScreen> {
  @override
  void initState() {
    super.initState();
    // Unawaited on purpose, and only once. The controller swallows a failed
    // read and leaves the driver on the first step, which is where they would
    // have been anyway, so there is nothing here worth blocking the first
    // frame on and nothing to report if it fails.
    //
    // Not fired from `build`: this screen is watched by the shell, so a
    // `build`-time read would ask the server on every rebuild of the whole app.
    unawaited(widget.controller.resumeFromServer());
  }

  KycController get controller => widget.controller;

  DocumentScanner? get cardScanner => widget.cardScanner;

  DocumentScanner? get selfieScanner => widget.selfieScanner;

  VoidCallback? get onContinue => widget.onContinue;
  static const _headlines = <KycStep, String>{
    KycStep.identity: 'Tell us about yourself',
    KycStep.ghanaCard: 'Scan your Ghana Card',
    KycStep.selfie: 'Take a selfie',
    KycStep.vehicle: 'Add your vehicle',
    KycStep.review: 'Review your details',
    KycStep.underReview: 'Sent for review',
    KycStep.approved: 'You are verified',
  };

  @override
  Widget build(BuildContext context) {
    final c = context.watch<KycController>();
    return Scaffold(
      appBar: AppBar(
        backgroundColor: MngColors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(_headlines[c.step] ?? 'Verification'),
      ),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 20.w),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LinearProgressIndicator(
                value: (c.step.index + 1) / KycStep.values.length,
                backgroundColor: MngColors.muted,
                color: MngColors.primary,
              ),
              SizedBox(height: 24.h),
              Expanded(child: _body(context, c)),
              if (c.error != null) ...[
                Text(c.error!, style: const TextStyle(color: MngColors.error)),
                SizedBox(height: 8.h),
              ],
              _action(c),
              SizedBox(height: 20.h),
            ],
          ),
        ),
      ),
    );
  }

  Widget _action(KycController c) {
    switch (c.step) {
      case KycStep.review:
        return FilledButton(
          key: const Key('kycSubmitButton'),
          onPressed: c.busy ? null : c.submit,
          child: const Text('Submit for review'),
        );
      case KycStep.underReview:
        return FilledButton(
          key: const Key('kycCheckStatusButton'),
          onPressed: c.busy ? null : c.checkStatus,
          child: const Text('Check status'),
        );
      case KycStep.approved:
        return FilledButton(
          key: const Key('kycStartDrivingButton'),
          onPressed: c.busy ? null : onContinue,
          child: const Text('Start driving'),
        );
      case KycStep.identity:
      case KycStep.ghanaCard:
      case KycStep.selfie:
      case KycStep.vehicle:
        return FilledButton(
          key: const Key('kycNextButton'),
          onPressed: c.canAdvance && !c.busy ? c.advance : null,
          child: const Text('Continue'),
        );
    }
  }

  Widget _body(BuildContext context, KycController c) {
    switch (c.step) {
      case KycStep.identity:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('fullNameField'),
              onChanged: (v) => c.fullName = v,
              decoration: const InputDecoration(hintText: 'Full legal name'),
            ),
            SizedBox(height: 12.h),
            Text(
              'This is the name on your Ghana Card.',
              style: MngTheme.light.textTheme.bodySmall,
            ),
          ],
        );
      case KycStep.ghanaCard:
        return _CardStep(controller: c);
      case KycStep.selfie:
        return ListView(
          children: [
            Text(
              'Hold your face in the light. This is a demo, so the selfie is '
              'only stored, never matched against anything.',
              style: MngTheme.light.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            CaptureButton(
              key: const Key('selfieButton'),
              label: 'Take selfie',
              // The real camera, not a stub.
              //
              // This fell back to `ScannerStub('/tmp/selfie.jpg')`, which is
              // the bug that made onboarding impossible: the stub returns that
              // path immediately without opening anything, the screen saw a
              // non-null path and said "Selfie captured", and then Continue
              // called `submitSelfie`, which checks the file is readable and
              // correctly refused -- so the driver was told their photo had been
              // taken, then told it could not be read, with no way forward. A
              // `/tmp` path is not a place on Android anyway.
              //
              // `submitSelfie`'s existence check is the thing that caught this
              // and it is right to keep it: a path that cannot be read must not
              // be reported as a selfie. The fix is to hand it a real one.
              scanner: selfieScanner ?? ImagePickerScanner(),
              onCaptured: (path) => c.selfiePath = path,
            ),
            if (c.selfiePath != null) ...[
              const SizedBox(height: 12),
              Text(
                'Selfie captured. Press Continue.',
                style: MngTheme.light.textTheme.bodySmall,
              ),
            ],
          ],
        );
      case KycStep.vehicle:
        return SingleChildScrollView(child: VehicleForm(controller: c));
      case KycStep.review:
        return ListView(
          children: [
            Text(
              'Name: ${c.cardName ?? c.fullName ?? ''}',
              style: MngTheme.light.textTheme.bodyMedium,
            ),
            Text(
              'Ghana Card: ${c.cardNumber ?? ''} (${c.cardExpiry ?? ''})',
              style: MngTheme.light.textTheme.bodyMedium,
            ),
            Text(
              'Vehicle: ${c.vehicleMake ?? ''} ${c.vehicleModel ?? ''} '
              '(${c.vehiclePlate ?? ''})',
              style: MngTheme.light.textTheme.bodyMedium,
            ),
            Text(
              'Demo verification. A human reviews this before launch.',
              style: MngTheme.light.textTheme.bodySmall,
            ),
          ],
        );
      case KycStep.underReview:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.hourglass_top,
                color: MngColors.primary,
                size: 64,
              ),
              SizedBox(height: 12.h),
              Text(
                'An administrator checks every driver by hand. You can go '
                'online as soon as they approve you.',
                textAlign: TextAlign.center,
                style: MngTheme.light.textTheme.bodySmall,
              ),
            ],
          ),
        );
      case KycStep.approved:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.check_circle,
                color: MngColors.success,
                size: 64,
              ),
              SizedBox(height: 12.h),
              // Not the step's headline: the app bar already carries it. The
              // plan's version rendered 'You are verified' in both, which made
              // its own `findsOneWidget` unsatisfiable and gave the driver the
              // same sentence twice on the same screen.
              Text(
                'Start driving below. We will stop asking for these.',
                textAlign: TextAlign.center,
                style: MngTheme.light.textTheme.bodySmall,
              ),
            ],
          ),
        );
    }
  }
}

/// The three Ghana Card fields, bound to the controller in both directions.
///
/// A `TextField` with only an `onChanged` shows what the driver typed and
/// nothing else, so a value that arrived any other way -- `applyScan` filling
/// the fields from parsed text -- was applied to the model and never appeared on
/// screen. The driver watched three empty boxes, pressed Continue, and was
/// walked to the selfie step with a card the screen claimed was empty and the
/// server had accepted.
class _CardStep extends StatefulWidget {
  const _CardStep({required this.controller});

  final KycController controller;

  @override
  State<_CardStep> createState() => _CardStepState();
}

class _CardStepState extends State<_CardStep> {
  final _number = TextEditingController();
  final _expiry = TextEditingController();
  final _name = TextEditingController();
  final _numberFocus = FocusNode();
  final _expiryFocus = FocusNode();
  final _nameFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _pull();
    widget.controller.addListener(_pull);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_pull);
    _number.dispose();
    _expiry.dispose();
    _name.dispose();
    _numberFocus.dispose();
    _expiryFocus.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  /// Pushes the controller's values into the fields, skipping any the driver is
  /// part-way through typing into: a notification fires for every keystroke, and
  /// writing the field's own text back over it would fight the driver's cursor.
  void _pull() {
    final c = widget.controller;
    _sync(_number, _numberFocus, c.cardNumber);
    _sync(_expiry, _expiryFocus, c.cardExpiry);
    _sync(_name, _nameFocus, c.cardName);
  }

  void _sync(TextEditingController field, FocusNode node, String? value) {
    if (_isFocused(node)) return;
    if (field.text == (value ?? '')) return;
    field.value = TextEditingValue(
      text: value ?? '',
      selection: TextSelection.collapsed(offset: (value ?? '').length),
    );
  }

  /// True while the driver is typing in this field, which is the only time a
  /// notification must not overwrite it.
  static bool _isFocused(FocusNode node) => node.hasFocus;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return ListView(
      children: [
        OutlinedButton.icon(
          key: const Key('scanTextButton'),
          onPressed: () => _enterScanText(context),
          icon: const Icon(Icons.text_snippet_outlined, size: 18),
          label: const Text('Enter scan text'),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('ghanaCardNumberField'),
          controller: _number,
          focusNode: _numberFocus,
          onChanged: (v) => c.cardNumber = v,
          decoration: const InputDecoration(hintText: 'GHA-000000000-0'),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('ghanaCardExpiryField'),
          controller: _expiry,
          focusNode: _expiryFocus,
          onChanged: (v) => c.cardExpiry = v,
          decoration: const InputDecoration(hintText: 'MM/YY'),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('ghanaCardNameField'),
          controller: _name,
          focusNode: _nameFocus,
          onChanged: (v) => c.cardName = v,
          decoration: const InputDecoration(hintText: 'Name on card'),
        ),
        const SizedBox(height: 12),
        Text(
          'Automatic card reading is not switched on in this build. Enter '
          'the three fields by hand, or paste the text a scan produced.',
          style: MngTheme.light.textTheme.bodySmall,
        ),
      ],
    );
  }

  Future<void> _enterScanText(BuildContext context) async {
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _ScanTextDialog(
        onCancel: () => Navigator.of(dialogContext).pop(),
        onUse: (value) => Navigator.of(dialogContext).pop(value),
      ),
    );
    if (text != null && text.trim().isNotEmpty) {
      widget.controller.applyScan(text);
    }
  }
}

/// The dialog owns the controller, and that is the whole point of it being a
/// widget.
///
/// A controller created in the caller and disposed as soon as `showDialog`
/// returns is disposed one frame too early: the route is still animating out,
/// so the `TextField` rebuilds once more against a disposed controller and
/// throws "A TextEditingController was used after being disposed" during a
/// frame. The throw lands in the middle of the pop, so the screen below is left
/// half-built and the fields the driver had just filled never appear. A
/// `StatefulWidget`'s `dispose` runs when the element is actually torn down,
/// which is after that frame.
class _ScanTextDialog extends StatefulWidget {
  const _ScanTextDialog({required this.onCancel, required this.onUse});

  final VoidCallback onCancel;
  final void Function(String text) onUse;

  @override
  State<_ScanTextDialog> createState() => _ScanTextDialogState();
}

class _ScanTextDialogState extends State<_ScanTextDialog> {
  final _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('scanTextDialog'),
      title: const Text('Scan text'),
      content: TextField(
        key: const Key('scanTextField'),
        controller: _field,
        maxLines: 5,
        decoration: const InputDecoration(
          hintText: 'REPUBLIC OF GHANA\nGHA-...\nNAME\nEXP MM/YY',
        ),
      ),
      actions: [
        TextButton(onPressed: widget.onCancel, child: const Text('Cancel')),
        TextButton(
          key: const Key('scanTextConfirmButton'),
          onPressed: () => widget.onUse(_field.text),
          child: const Text('Use this'),
        ),
      ],
    );
  }
}
