import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

import '../data/driver_repository.dart';
import 'driver_document.dart';

/// Takes a photograph. Behind an interface so the screen has no plugin in it and
/// a test can drive every state -- captured, cancelled, refused -- without a
/// camera.
abstract class DocumentCapture {
  /// A file path, or null when the driver backed out.
  ///
  /// Null for a cancel rather than an exception: backing out of a camera is not
  /// a failure, and treating it as one is what produces a checklist that says
  /// "the camera failed" when all the driver did was change their mind.
  Future<String?> capture();
}

/// The documents a driver has to send, and how they are going.
///
/// This is the first thing a new driver sees after signing up, and that is the
/// point of it. The alternative -- a sequence of forms that each ask for one
/// thing -- means a driver discovers they need a road worthy certificate at the
/// sixth step, having already driven to the depot for it, or discovers it after
/// an hour of typing. A list first is a packing list, and it is the difference
/// between a verification that completes and one that quietly stalls.
///
/// Two things it deliberately does not do:
///
///   * It does not claim the selfie is verified. Liveness and face-matching
///     against the licence is not something this app can do, and a tick next to
///     "verified" on a screen whose whole job is honesty would be the one lie
///     in the flow. See [LivenessRow].
///   * It does not block on the network before drawing. A driver on a bad
///     connection in a depot basement should see the list, not a spinner.
class DocumentChecklist extends StatefulWidget {
  const DocumentChecklist({
    super.key,
    required this.documents,
    required this.onUpload,
    required this.capture,
    this.onStartLiveness,
    this.onContinue,
  });

  /// What the server already holds, keyed by kind.
  final List<DriverDocument> documents;

  /// Uploads one document. Throws [DriverAuthFailure] on a refusal, and the row
  /// it came from goes back to unticked.
  final Future<void> Function(DriverDocumentKind kind, String filePath)
  onUpload;

  final DocumentCapture capture;

  /// Opens the face check, for [DriverDocumentKind.livenessFrame].
  ///
  /// A separate callback rather than something [capture] handles, because the
  /// two are different mechanisms and hiding that hides the reason: a
  /// photograph is one still from the system camera, while a liveness check
  /// has to watch a face move, so it runs in-app with a live preview and
  /// returns when it has a verdict. `CameraDocumentCapture` cannot do it --
  /// it hands the driver to another app and gets one picture back.
  final VoidCallback? onStartLiveness;

  /// Enabled once every document is in. Wired to the rest of onboarding.
  final VoidCallback? onContinue;

  /// The kinds that have been sent, in checklist order.
  List<DriverDocumentKind> get _have => driverDocumentKinds
      .where((kind) => documents.any((d) => d.kind == kind))
      .toList();

  /// The required kinds still missing, which is what Continue is gated on.
  ///
  /// Counted from [driverRequiredKinds] rather than from [driverDocumentKinds]
  /// so an optional item -- the face check, while its detector is broken -- does
  /// not hold a driver at the last step of onboarding. The face check is still
  /// listed, still offered and still stored when it is done; it just is not
  /// something a driver can be stuck behind.
  List<DriverDocumentKind> get _missing => driverRequiredKinds
      .where((kind) => !documents.any((d) => d.kind == kind))
      .toList();

  bool get isComplete => _missing.isEmpty;

  @override
  State<DocumentChecklist> createState() => _DocumentChecklistState();
}

class _DocumentChecklistState extends State<DocumentChecklist> {
  /// The kind currently uploading, so exactly one row shows a spinner.
  ///
  /// One at a time on purpose: a driver photographing six documents and being
  /// met with six spinners has no way to tell which upload failed, and a list
  /// that flickers six times tells them nothing at all.
  DriverDocumentKind? _busy;

  /// The last failure, kept until the driver does something about it.
  String? _error;

  Future<void> _take(DriverDocumentKind kind) async {
    // The face check is not a photograph and does not go through the camera
    // seam. Dispatched here so every row has one tap handler and the row
    // cannot be wired to the wrong mechanism for one kind.
    if (kind.isLiveness) {
      widget.onStartLiveness?.call();
      return;
    }
    setState(() {
      _busy = kind;
      _error = null;
    });
    try {
      final path = await widget.capture.capture();
      if (!mounted) return;
      // A cancel is a cancel. Returning to the unticked row with no message is
      // the whole of what should happen, because nothing went wrong.
      if (path == null) {
        setState(() => _busy = null);
        return;
      }
      await widget.onUpload(kind, path);
      if (!mounted) return;
      setState(() => _busy = null);
    } on DriverAuthFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = null;
        _error = e.message;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _busy = null;
        _error = 'That photo could not be saved. Try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final have = widget._have;
    return ListView(
      key: const Key('documentChecklist'),
      padding: EdgeInsets.fromLTRB(20.w, 8.h, 20.w, 24.h),
      children: [
        Text(
          'What we need from you',
          style: MngTheme.light.textTheme.titleMedium,
        ),
        SizedBox(height: 6.h),
        Text(
          'Six photos, and a face check you can do later. Take them now if '
          'you can -- nothing you have already sent is lost.',
          style: MngTheme.light.textTheme.bodySmall,
        ),
        SizedBox(height: 16.h),
        for (final kind in driverDocumentKinds)
          Padding(
            padding: EdgeInsets.only(bottom: 10.h),
            child: _DocumentRow(
              kind: kind,
              sent: have.contains(kind),
              busy: _busy == kind,
              // A row is not tappable while another upload runs, so a driver
              // cannot queue six of them and find out at the end that five
              // failed.
              enabled: _busy == null,
              onTap: () => _take(kind),
            ),
          ),
        const _LivenessNote(),
        if (_error != null) ...[
          SizedBox(height: 8.h),
          Container(
            key: const Key('documentError'),
            padding: EdgeInsets.all(12.w),
            decoration: BoxDecoration(
              color: MngColors.error.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(MngRadius.small),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.error_outline,
                  size: 18,
                  color: MngColors.error,
                ),
                SizedBox(width: 8.w),
                Expanded(
                  child: Text(
                    _error!,
                    style: MngTheme.light.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ],
        SizedBox(height: 20.h),
        FilledButton(
          key: const Key('documentsContinue'),
          onPressed: widget.isComplete ? widget.onContinue : null,
          child: Text(
            widget.isComplete
                ? 'Continue'
                // The count of what is still required, so it can never disagree
                // with whether the button works. A footer reading "1 still
                // needed" above a live Continue is a bug somebody would report,
                // and rightly.
                : '${widget._missing.length} still needed',
          ),
        ),
      ],
    );
  }
}

class _DocumentRow extends StatelessWidget {
  const _DocumentRow({
    required this.kind,
    required this.sent,
    required this.busy,
    required this.enabled,
    required this.onTap,
  });

  final DriverDocumentKind kind;
  final bool sent;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: MngColors.surface,
      borderRadius: BorderRadius.circular(MngRadius.small),
      child: InkWell(
        key: Key('document-${kind.wire}'),
        borderRadius: BorderRadius.circular(MngRadius.small),
        onTap: enabled && !busy ? onTap : null,
        child: Container(
          padding: EdgeInsets.all(12.w),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(MngRadius.small),
            border: Border.all(
              color: sent ? MngColors.success : MngColors.divider,
              width: sent ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 24,
                child: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        sent ? Icons.check_circle : _iconFor(kind),
                        size: 22,
                        color: sent ? MngColors.success : MngColors.textSub,
                      ),
              ),
              SizedBox(width: 12.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      kind.label,
                      style: MngTheme.light.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 2.h),
                    Text(
                      // A sent row says how to replace the photo, not just that
                      // it is there: a driver who photographed their licence at
                      // an angle needs to be able to fix it without wondering
                      // whether tapping would duplicate it.
                      sent ? 'Tap to replace this photo' : kind.hint,
                      style: MngTheme.light.textTheme.bodySmall,
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

  static IconData _iconFor(DriverDocumentKind kind) => switch (kind) {
    DriverDocumentKind.profilePhoto => Icons.person_outline,
    DriverDocumentKind.vehiclePhoto => Icons.directions_car_outlined,
    DriverDocumentKind.ghanaCardPhoto => Icons.credit_card,
    DriverDocumentKind.driversLicence => Icons.badge_outlined,
    DriverDocumentKind.roadWorthy => Icons.verified_outlined,
    DriverDocumentKind.insuranceSticker => Icons.shield_outlined,
    DriverDocumentKind.livenessFrame => Icons.face_retouching_natural,
  };
}

/// What the face check does, and what it does not.
///
/// The check is real and it runs on the device -- ML Kit's face detection, no
/// network, no provider -- so this note is not here to apologise for it. It is
/// here because of the one thing the check genuinely does not do, and a driver
/// who has just been asked to turn their head and blink deserves to know which
/// half of "this is really me" they have actually done.
///
///   * It proves somebody live was in front of the camera. A printed photograph
///     cannot turn its head, blink or smile, and a driver holding up a picture
///     of themselves is caught because the detector sees two faces.
///
///   * It does NOT prove the face is the one on your licence. That is a face
///     match, it needs an embedding model, and a bundled model on a budget
///     phone in a vehicle at night gets it wrong in the direction that blocks
///     a real driver from earning. So the photo the check takes goes to the
///     person reviewing your documents, beside your licence photo, and they
///     compare the two.
///
/// So the honest summary is: we checked somebody real was there, and a person
/// will check it is you. Anything stronger is a claim this app cannot support.
class _LivenessNote extends StatelessWidget {
  const _LivenessNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('livenessNote'),
      padding: EdgeInsets.all(12.w),
      decoration: BoxDecoration(
        color: MngColors.muted,
        borderRadius: BorderRadius.circular(MngRadius.small),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.face_retouching_natural,
            size: 22,
            color: MngColors.textSub,
          ),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'About the face check',
                  style: MngTheme.light.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 2.h),
                Text(
                  'It runs on your phone, with nobody else seeing it. It proves '
                  'somebody real was in front of the camera, and the photo it '
                  'takes goes to the person reviewing your documents so they '
                  'can check it is you.',
                  style: MngTheme.light.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
