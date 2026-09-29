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
    this.onContinue,
  });

  /// What the server already holds, keyed by kind.
  final List<DriverDocument> documents;

  /// Uploads one document. Throws [DriverAuthFailure] on a refusal, and the row
  /// it came from goes back to unticked.
  final Future<void> Function(DriverDocumentKind kind, String filePath) onUpload;

  final DocumentCapture capture;

  /// Enabled once every document is in. Wired to the rest of onboarding.
  final VoidCallback? onContinue;

  /// The kinds that have been sent, in checklist order.
  List<DriverDocumentKind> get _have => driverDocumentKinds
      .where((kind) => documents.any((d) => d.kind == kind))
      .toList();

  bool get isComplete => _have.length == driverDocumentKinds.length;

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
          'Six photos. Take them now if you can, or come back to this list '
          'later — nothing you have already sent is lost.',
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
        const _LivenessRow(),
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
                const Icon(Icons.error_outline,
                    size: 18, color: MngColors.error),
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
                : '${driverDocumentKinds.length - have.length} still needed',
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
      };
}

/// The liveness check, shown honestly.
///
/// Not a tick, and not one of the six. It is on the same screen because a driver
/// has to know it is coming, and finding out at the last step is the thing this
/// screen exists to prevent.
///
/// What it says is that the check is not performed by this app. Liveness --
/// proving the person in front of the camera is a person and not a photograph --
/// and a face match against the licence photo are both things every real
/// ride-hailing app buys from a provider (Veriff, Onfido, Jumio, Sumsub), because
/// a version written here would be both unreliable and trivially defeated: a
/// replay attack, a video of someone else, a mask. Claiming otherwise on a
/// screen whose purpose is to be trustworthy would be the single worst lie in
/// the flow.
///
/// So this row is informational until a provider is configured, and it says
/// that. Wiring one in is [LivenessRow.provider] and one server call.
class _LivenessRow extends StatelessWidget {
  const _LivenessRow();

  /// The provider that performs the check, or null when none is configured.
  ///
  /// Null is the honest default for this build, and it is why the row below
  /// reads as "not yet" rather than as a failure. Setting this to a real
  /// provider's session bootstrap is the whole of the integration on the client;
  /// the verification itself is server-side and needs the vendor's SDK.
  static const String? provider = null;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('livenessRow'),
      padding: EdgeInsets.all(12.w),
      decoration: BoxDecoration(
        color: MngColors.muted,
        borderRadius: BorderRadius.circular(MngRadius.small),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.face_retouching_natural, size: 22,
              color: MngColors.textSub),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Face check',
                  style: MngTheme.light.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 2.h),
                Text(
                  provider == null
                      ? 'A short in-app check that your face is a real one, '
                          'matched to your licence. This has to be done by a '
                          'verification provider, and it is not connected yet — '
                          'it is a separate step before your documents are '
                          'reviewed.'
                      : 'A short in-app check that your face is a real one, '
                          'matched to your licence.',
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
