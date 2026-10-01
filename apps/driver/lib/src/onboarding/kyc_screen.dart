import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

import 'document_capture.dart';
import 'card_reader.dart';
import 'driver_document.dart';
import 'liveness/liveness_screen.dart';
import 'document_checklist.dart';
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
    this.documentCapture,
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

  /// How a document photo is taken.
  ///
  /// Injected rather than reached for, so the checklist can be driven through
  /// captured, cancelled and refused in a test with no camera present. Null is
  /// the real camera.
  final DocumentCapture? documentCapture;

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

  /// How a document photo is taken. Overridable so a test can drive a capture
  /// without a camera; null means the real one.
  DocumentCapture? get documentCapture => widget.documentCapture;

  VoidCallback? get onContinue => widget.onContinue;
  static const _headlines = <KycStep, String>{
    // 'Documents', not the list's own heading. The list opens with "What we
    // need from you", and the app bar saying the same thing put the identical
    // sentence twice on one screen -- found on the device.
    KycStep.documents: 'Documents',
    KycStep.identity: 'Tell us about yourself',
    KycStep.ghanaCard: 'Scan your Ghana Card',
    KycStep.selfie: 'Take a selfie',
    KycStep.vehicle: 'Add your vehicle',
    KycStep.review: 'Review your details',
    KycStep.underReview: 'Sent for review',
    KycStep.approved: 'You are verified',
  };

  /// Whether there is a step behind this one.
  ///
  /// False on the first step, and false once the application has been handed
  /// over: `underReview` and `approved` are states the driver is told about, not
  /// a form they are filling in, and offering a back arrow on them would
  /// suggest they could un-submit something.
  ///
  /// This is the one place that decides what "back" means, and both the app bar
  /// arrow and the hardware gesture read it, so the two cannot disagree.
  static bool _canGoBack(KycController c) =>
      c.step != KycStep.underReview &&
      c.step != KycStep.approved &&
      c.step != KycStep.documents;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<KycController>();
    return PopScope(
      // The hardware back gesture steps back through the wizard rather than
      // dropping the driver out of it.
      //
      // Android users reach for the gesture, and a wizard that treats it as
      // "leave" while its own arrow says "previous step" gives two different
      // answers to the same thumb movement. `canPop` is false above the first
      // step, which both blocks the pop and routes it here; on the first step
      // it stays true so back leaves the screen as a driver expects.
      //
      // Read on every build, because it is compared against the step at the
      // moment the gesture happens and not at the moment the screen opened.
      canPop: !_canGoBack(c),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        c.back();
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: MngColors.page,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          // Back, from the first step onwards.
          //
          // This is a wizard and it was not navigable backwards. `KycController
          // .back()` existed and nothing called it, so a driver who reached the
          // review step with a Ghana Card photo taken at an angle had no way back
          // to the list to retake it: the only way out was forward, into
          // submitting a bad application. That is the whole reason `back()` was
          // written and then left unwired, and it is also why the face check --
          // optional, so a driver can reach `review` without it -- was
          // unreachable after the fact.
          //
          // Not shown on the first step, where there is nowhere to go back to, and
          // not shown once the application is with an admin, where the steps are
          // history rather than a form.
          leading: _canGoBack(c)
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Back',
                  onPressed: c.back,
                )
              : null,
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
                  Text(
                    c.error!,
                    style: const TextStyle(color: MngColors.error),
                  ),
                  SizedBox(height: 8.h),
                ],
                _action(c),
                SizedBox(height: 20.h),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Pushes the face check, and uploads the frame when it passes.
  ///
  /// The upload happens here rather than inside the liveness screen because
  /// the screen's only job is the check; where the proof goes is the checklist's
  /// business, and the checklist is what knows the driver is a driver and which
  /// bucket it is.
  Future<void> _runLiveness(
    BuildContext context,
    KycController controller,
  ) async {
    final proof = await Navigator.of(context).push<File>(
      MaterialPageRoute(
        builder: (_) => LivenessScreen(
          onPassed: (file) async {
            await controller.uploadDocument(
              kind: DriverDocumentKind.livenessFrame,
              filePath: file.path,
            );
          },
        ),
      ),
    );
    // The screen pops with the frame only once the upload has succeeded, so a
    // driver who backs out after a failed upload is not told they passed.
    if (proof != null && context.mounted) {
      // Nothing to do: the controller already recorded it and the checklist is
      // listening. Stated rather than left implicit, because a bare `if` with
      // an empty body is the shape of a bug someone later "tidies away".
      assert(proof.path.isNotEmpty);
    }
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
      // The document list brings its own "Continue", and putting a second one
      // under it would be two controls for one decision. The empty state of
      // that button is the progress: "4 still needed".
      case KycStep.documents:
        return const SizedBox.shrink();
    }
  }

  Widget _body(BuildContext context, KycController c) {    switch (c.step) {
      case KycStep.documents:
        return DocumentChecklist(
          documents: c.documents,
          capture: documentCapture ?? CameraDocumentCapture(),
          onUpload: (kind, path) async {
            await controller.uploadDocument(kind: kind, filePath: path);
          },
          // The face check is its own screen, pushed over this one. Pushed
          // rather than pushed-and-replaced so a driver who backs out lands
          // back on the checklist with their six photos still ticked, instead
          // of at the top of onboarding with nothing to show for it.
          onStartLiveness: () => _runLiveness(context, controller),
          onContinue: c.canAdvance && !c.busy ? c.advance : null,
        );
      case KycStep.identity:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('fullNameField'),
              // Seeded from the controller rather than left empty, so a driver
              // who backs out of a later step and returns sees what they already
              // typed instead of an empty field they have to retype. The same
              // reason the card fields are seeded.
              controller: TextEditingController(text: c.fullName ?? ''),
              onChanged: (v) => c.fullName = v,
              decoration: const InputDecoration(hintText: 'Full legal name'),
            ),
            SizedBox(height: 12.h),
            Text(
              'This is the name on your Ghana Card.',
              style: MngTheme.light.textTheme.bodySmall,
            ),
            SizedBox(height: 20.h),
            TextField(
              key: const Key('phoneField'),
              onChanged: (v) => c.phone = v,
              // The phone keypad, not the default. A number field that brings up
              // a keyboard with no digits is a field every driver has to fight
              // with, and the first thing a driver does with this field is type
              // ten numbers.
              keyboardType: TextInputType.phone,
              // The stored value is normalised, so what is shown back is the
              // driver's own number in the form they typed it. `formatGhanaPhone`
              // regroups it as `024 123 4567` from either form, which is easier
              // to read back and check than either raw spelling.
              decoration: InputDecoration(
                hintText: '024 123 4567',
                helperText: c.phoneProblem,
                // Only red once they have typed something. An empty required
                // field is not an error yet, and painting it red before the
                // driver has touched it is the platform telling them they have
                // already got it wrong.
                errorText: (c.phone ?? '').trim().isEmpty
                    ? null
                    : c.phoneProblem,
                prefixIcon: const Icon(Icons.phone_outlined),
              ),
            ),
            SizedBox(height: 8.h),
            Text(
              'The number a rider will use to reach you while you are driving.',
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
            // The whole Ghana Card, because an employee is about to be handed a
            // photograph of it and asked whether the person in it is who they say
            // they are. Three fields and a shrug gave them nothing to check
            // against, and one line per field with a label and a value run
            // together is easy to skim past.
            //
            // Age sits beside the date of birth rather than instead of it, and is
            // computed rather than typed: it is the number an eye checks fastest
            // and the one that most often catches a card belonging to somebody
            // else. `cardAge` is null when the date cannot be read, and the row
            // then says "not given" rather than showing a guess.
            Text(
              'Ghana Card',
              style: MngTheme.light.textTheme.titleSmall,
            ),
            _kycDetail('Name on card', c.cardName ?? c.fullName ?? ''),
            _kycDetail('Date of birth', c.cardDob ?? ''),
            _kycDetail(
              'Age',
              c.cardAge == null ? 'not given' : '${c.cardAge}',
            ),
            _kycDetail('Sex', c.cardSex ?? ''),
            _kycDetail('Nationality', c.cardNationality ?? ''),
            _kycDetail('Card number', c.cardNumber ?? ''),
            _kycDetail('Date of issue', c.cardIssued ?? ''),
            _kycDetail('Expires', c.cardExpiry ?? ''),
            const SizedBox(height: 20),
            Text(
              'Vehicle',
              style: MngTheme.light.textTheme.titleSmall,
            ),
            _kycDetail(
              'Registered',
              '${c.vehicleMake ?? ''} ${c.vehicleModel ?? ''}',
            ),
            _kycDetail('Number plate', c.vehiclePlate ?? ''),
            const SizedBox(height: 20),
            Text(
              'We check this by hand. Nothing on this screen is decided '
              'automatically.',
              style: MngTheme.light.textTheme.bodySmall,
            ),
          ],
        );
      case KycStep.underReview:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
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
            SizedBox(height: 20.h),
            // What they are checking. The freeze in
            // 20260930000006_freeze_kyc_identity.sql makes these read-only from
            // here on, so showing them is not decoration: a driver who cannot
            // see what was submitted cannot tell a typo from a correct reading,
            // and a typo they cannot fix is a rejection they do not understand.
            // The line saying who can change it is the other half -- "locked"
            // with no way forward is the message that produces a support call.
            _SubmittedIdentity(
              label: 'What we are checking',
              lockedNote: 'These are locked while your review is open. If '
                  'something is wrong, ask an administrator to reopen it.',
              cardNumber: c.cardNumber,
              dob: c.cardDob,
              sex: c.cardSex,
              nationality: c.cardNationality,
              issued: c.cardIssued,
              expiry: c.cardExpiry,
            ),
          ],
        );
      case KycStep.approved:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
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
            SizedBox(height: 20.h),
            // The same summary, for the same reason, and with a different note:
            // this one is not going to be reopened on request, so the sentence
            // has to say that a *correction* now needs an administrator rather
            // than promising a reopen.
            _SubmittedIdentity(
              label: 'What we verified',
              lockedNote: 'Locked, because this is the record your approval was '
                  'made against. If it is wrong, an administrator has to correct '
                  'it -- the app cannot.',
              cardNumber: c.cardNumber,
              dob: c.cardDob,
              sex: c.cardSex,
              nationality: c.cardNationality,
              issued: c.cardIssued,
              expiry: c.cardExpiry,
            ),
          ],
        );
    }
  }
}

/// One label-and-value row for the review screen and for the locked summary.
///
/// A row rather than a sentence, and the label above the value rather than
/// beside it. The reason is that these are being checked against a photograph
/// by a person in a hurry, one field at a time: "Date of birth / 14/03/1994" is
/// something you can scan down a column of, and "Date of birth: 14/03/1994,
/// Sex: M, Nationality: Ghanaian" is a sentence you have to parse.
///
/// A blank value says "not given" rather than rendering as nothing. An empty row
/// reads as a rendering failure, and a driver would retype a field that is
/// perfectly fine -- or worse, would assume the app had lost it.
///
/// Top level rather than a static on `_KycScreenState`, because
/// [_SubmittedIdentity] needs the same row and a locked summary that looks
/// different from the review it came from is exactly the sort of small
/// inconsistency that makes a driver think they are looking at different data.
Widget _kycDetail(String label, String value) {
  final shown = value.trim().isEmpty ? 'not given' : value.trim();
  return Padding(
    padding: EdgeInsets.only(bottom: 10.h),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: MngTheme.light.textTheme.labelSmall,
        ),
        SizedBox(height: 2.h),
        Text(
          shown,
          key: Key('kycDetail_${label.replaceAll(' ', '')}'),
          style: MngTheme.light.textTheme.bodyMedium,
        ),
      ],
    ),
  );
}

/// The identity evidence the driver submitted, shown read-only once a decision
/// has been made about it.
///
/// This exists because the freeze changed what the app can do, and a rule the
/// user only discovers by being refused is a rule they do not believe. Before
/// the freeze the driver could edit these at any time; after it, they cannot,
/// and the app owes them an answer to "what is locked, and who do I ask".
///
/// Three properties, each of which is a decision rather than styling:
///
/// **No editable field.** Not a disabled `TextField` -- a greyed box looks
/// broken and still invites taps. Plain text, laid out as the `review` step
/// already lays out the same six fields, so the driver sees the same thing they
/// saw on the way in.
///
/// **A field with no value says "not given",** the same word the review step
/// uses. Not blank, and not a dash: a driver looking at an empty row cannot tell
/// whether the app failed to save it or saved nothing because the card did not
/// say. Naming it is the difference between a question and an accusation.
///
/// **The note is passed in, not derived from the status.** "While your review is
/// open, ask an administrator to reopen it" and "an administrator has to correct
/// it" are both true and mean different things to the driver, and which one is
/// right depends on the step, not on anything this widget could work out.
class _SubmittedIdentity extends StatelessWidget {
  const _SubmittedIdentity({
    required this.label,
    required this.lockedNote,
    this.cardNumber,
    this.dob,
    this.sex,
    this.nationality,
    this.issued,
    this.expiry,
  });

  final String label;
  final String lockedNote;
  final String? cardNumber;
  final String? dob;
  final String? sex;
  final String? nationality;
  final String? issued;
  final String? expiry;

  @override
  Widget build(BuildContext context) {
    final theme = MngTheme.light.textTheme;
    // Nothing on this screen if the driver never gave a card number. An empty
    // box titled "What we verified" is worse than no box: it says a verification
    // happened against something.
    if ((cardNumber ?? '').trim().isEmpty) return const SizedBox.shrink();

    return Container(
      key: const Key('kycSubmittedIdentity'),
      padding: EdgeInsets.all(16.w),
      decoration: BoxDecoration(
        color: MngColors.page,
        borderRadius: BorderRadius.circular(12.w),
        border: Border.all(color: MngColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.titleSmall),
          SizedBox(height: 12.h),
          _kycDetail('Card number', cardNumber ?? ''),
          _kycDetail('Date of birth', dob ?? ''),
          _kycDetail('Sex', sex ?? ''),
          _kycDetail('Nationality', nationality ?? ''),
          _kycDetail('Date of issue', issued ?? ''),
          _kycDetail('Expires', expiry ?? ''),
          SizedBox(height: 4.h),
          // The lock is stated as a fact with a way forward, not as an error.
          // No icon and no red: nothing has gone wrong, and a driver who reads a
          // warning here concludes they did something wrong with their own card.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.lock_outline, size: 16, color: MngColors.textSub),
              SizedBox(width: 8.w),
              Expanded(
                child: Text(
                  lockedNote,
                  key: const Key('kycIdentityLockedNote'),
                  style: theme.bodySmall?.copyWith(color: MngColors.textSub),
                ),
              ),
            ],
          ),
        ],
      ),
    );
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
  /// Whether a read is in flight, so the button shows a spinner and cannot be
  /// pressed twice. Two reads racing would interleave two `applyScan` calls and
  /// the second would overwrite the first with a worse read of the same card.
  bool _reading = false;

  CardReader? _reader;
  DocumentScanner? _scanner;

  /// The reader, and the camera, are built on first use rather than in
  /// `initState`.
  ///
  /// `TextRecognizer` is a native object with a lifetime, and constructing one
  /// for a driver who never taps the button is a native call on every screen
  /// build for nothing. `dispose` closes whichever was made.
  CardReader get _cardReader => _reader ??= MlKitCardReader();
  DocumentScanner get _cardScanner =>
      _scanner ??= ImagePickerScanner();

  Future<void> _readCard() async {
    setState(() => _reading = true);
    try {
      await readCardFromCamera(
        reader: _cardReader,
        capture: _cardScanner.capture,
        controller: widget.controller,
        onMessage: _say,
        onRead: () => setState(() {}),
      );
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  final _number = TextEditingController();  final _expiry = TextEditingController();
  final _name = TextEditingController();
  final _dob = TextEditingController();
  final _sex = TextEditingController();
  final _nationality = TextEditingController();
  final _issued = TextEditingController();
  final _numberFocus = FocusNode();
  final _expiryFocus = FocusNode();
  final _nameFocus = FocusNode();
  final _dobFocus = FocusNode();
  final _sexFocus = FocusNode();
  final _nationalityFocus = FocusNode();
  final _issuedFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _pull();
    widget.controller.addListener(_pull);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_pull);
    // Only whichever was actually built, and only if it is the real one: a test
    // that injected a stub has nothing to close, and calling close() on it would
    // be a method it does not have.
    if (_reader is MlKitCardReader) (_reader! as MlKitCardReader).dispose();
    for (final f in <TextEditingController>[
      _number,
      _expiry,
      _name,
      _dob,
      _sex,
      _nationality,
      _issued,
    ]) {
      f.dispose();
    }
    for (final n in <FocusNode>[
      _numberFocus,
      _expiryFocus,
      _nameFocus,
      _dobFocus,
      _sexFocus,
      _nationalityFocus,
      _issuedFocus,
    ]) {
      n.dispose();
    }
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
    // The four that a card reader can fill, restored the same way. Without these
    // in `_pull` a resumed driver's date of birth would sit on the server and
    // show as "not given" on the review screen -- the review being the one place
    // it is read.
    _sync(_dob, _dobFocus, c.cardDob);
    _sync(_sex, _sexFocus, c.cardSex);
    _sync(_nationality, _nationalityFocus, c.cardNationality);
    _sync(_issued, _issuedFocus, c.cardIssued);
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
        // The rest of the card, after the three that were always here.
        //
        // Optional and unvalidated, both deliberately. The gate is still
        // `cardNumber` and `cardExpiry`: a driver who cannot read or type a date
        // of birth must still be able to hand in a licence photo and a car, since
        // the alternative is a person who cannot drive over a form field. And an
        // unreadable date is stored as typed rather than refused -- see
        // `20260930000003_ghana_card_fields.sql` for why a `date` column would
        // have thrown away the entire submission over one mistyped digit.
        TextField(
          key: const Key('ghanaCardDobField'),
          controller: _dob,
          focusNode: _dobFocus,
          onChanged: (v) => c.cardDob = v,
          decoration:
              const InputDecoration(hintText: 'Date of birth, DD/MM/YYYY'),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('ghanaCardSexField'),
          controller: _sex,
          focusNode: _sexFocus,
          onChanged: (v) => c.cardSex = v,
          decoration: const InputDecoration(hintText: 'Sex, M or F'),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('ghanaCardNationalityField'),
          controller: _nationality,
          focusNode: _nationalityFocus,
          onChanged: (v) => c.cardNationality = v,
          decoration: const InputDecoration(hintText: 'Nationality'),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('ghanaCardIssuedField'),
          controller: _issued,
          focusNode: _issuedFocus,
          onChanged: (v) => c.cardIssued = v,
          decoration:
              const InputDecoration(hintText: 'Date of issue, DD/MM/YYYY'),
        ),
        const SizedBox(height: 12),
        // Read the card off its photograph, on the phone. Fills the fields
        // below; never required, and a failure leaves every one of them
        // editable. See `card_reader.dart` for why a plugin failure is not
        // allowed to be a driver's problem.
        OutlinedButton.icon(
          key: const Key('ghanaCardReadButton'),
          onPressed: _reading ? null : _readCard,
          icon: _reading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.document_scanner, size: 18),
          label: Text(_reading ? 'Reading the card' : 'Read my card'),
        ),
        const SizedBox(height: 12),
        Text(
          'Reading the card fills these in from the photograph. Check every one '
          'against the card before you continue -- an employee checks them '
          'against the same photograph, and a wrong value here is a rejection.',
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
