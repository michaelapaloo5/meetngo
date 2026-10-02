import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

import '../data/trip_report_repository.dart';

/// Telling us a ride went wrong.
///
/// Shown on a **finished** ride, not a live one. Mid-ride the rider has the SOS
/// button and the driver's number, and a support ticket raised while the car is
/// still arriving is something nobody reads until it is over. The button is
/// absent on a live ride for that reason, and the sheet says so rather than
/// being there and refusing.
///
/// The reasons are suggestions and the field is editable, because a rider whose
/// problem is not on the list should not have to pick the nearest one. There is
/// deliberately no "Other" chip: typing something else is one tap fewer than
/// finding Other and then typing anyway.
class ReportProblemSheet extends StatefulWidget {
  const ReportProblemSheet({
    super.key,
    required this.tripId,
    required this.repository,
    this.existing,
  });

  final String tripId;
  final TripReportRepository repository;

  /// What this rider already reported about this ride, if anything.
  ///
  /// Shown as the starting text, so a rider adding detail to a report they made
  /// yesterday is editing their own words rather than retyping them.
  final RideReport? existing;

  static Future<void> show(
    BuildContext context, {
    required String tripId,
    required TripReportRepository repository,
    RideReport? existing,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ReportProblemSheet(
        tripId: tripId,
        repository: repository,
        existing: existing,
      ),
    );
  }

  @override
  State<ReportProblemSheet> createState() => _ReportProblemSheetState();
}

class _ReportProblemSheetState extends State<ReportProblemSheet> {
  late final TextEditingController _reason = TextEditingController(
    text: widget.existing?.reason ?? '',
  );
  late final TextEditingController _detail = TextEditingController(
    text: widget.existing?.detail ?? '',
  );
  bool _busy = false;
  String? _problem;

  @override
  void dispose() {
    _reason.dispose();
    _detail.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await widget.repository.save(
        RideReport(
          tripId: widget.tripId,
          reason: _reason.text,
          detail: _detail.text,
        ),
      );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            key: Key('reportSentSnack'),
            content: Text('Thank you. We have that on the ride.'),
          ),
        );
    } catch (e) {
      if (!mounted) return;
      // The text stays in the fields. Somebody's description of a bad ride is the
      // most valuable thing on this screen and it must not be lost to a write
      // that did not land.
      setState(() {
        _busy = false;
        _problem = e is ReportFailure
            ? e.message
            : 'Could not send that. Try again in a moment.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = MngTheme.light.textTheme;
    final editing = widget.existing != null;

    return SafeArea(
      child: Padding(
        // Bottom inset, or the keyboard covers the send button on a 390x844
        // screen and the rider cannot report anything.
        padding: EdgeInsets.fromLTRB(
          20.w,
          20.h,
          20.w,
          20.h + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                editing ? 'Add to your report' : 'Report a problem',
                style: theme.titleLarge,
              ),
              SizedBox(height: 4.h),
              Text(
                'Your driver is not told about this.',
                style: theme.bodySmall?.copyWith(color: MngColors.textSub),
              ),
              SizedBox(height: 16.h),
              Wrap(
                spacing: 8.w,
                runSpacing: 8.h,
                children: [
                  for (final reason in RideReport.suggestions)
                    ChoiceChip(
                      key: Key('reasonChip-$reason'),
                      label: Text(reason),
                      selected: _reason.text.trim() == reason,
                      onSelected: (_) => setState(() => _reason.text = reason),
                    ),
                ],
              ),
              SizedBox(height: 14.h),
              TextField(
                key: const Key('reportReasonField'),
                controller: _reason,
                enabled: !_busy,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: 'What went wrong',
                  hintText: 'Driver never arrived',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              SizedBox(height: 10.h),
              TextField(
                key: const Key('reportDetailField'),
                controller: _detail,
                enabled: !_busy,
                minLines: 2,
                maxLines: 4,
                maxLength: 1000,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: 'Anything else',
                  // Optional, and deliberately with no minimum length: a rider who
                  // writes "the driver was rude" has reported something.
                  hintText: 'Optional',
                  border: const OutlineInputBorder(),
                  counterText: '',
                ),
              ),
              if (_problem != null) ...[
                SizedBox(height: 8.h),
                Text(
                  _problem!,
                  key: const Key('reportProblem'),
                  style: theme.bodySmall?.copyWith(color: MngColors.error),
                ),
              ],
              SizedBox(height: 16.h),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('reportSendButton'),
                  onPressed: _busy ? null : _send,
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: MngColors.onPrimary,
                          ),
                        )
                      : Text(editing ? 'Update report' : 'Send report'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
