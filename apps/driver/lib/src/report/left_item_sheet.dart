import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

import 'left_item_controller.dart';

/// Report something the rider left in the car.
///
/// A sheet rather than a screen, because it is opened from inside a live trip and
/// the driver has to be able to close it in one gesture to get back to the map.
/// The trip screen underneath keeps running the whole time -- nothing about a
/// report pauses a journey.
///
/// ## Why this is careful about being believed
///
/// The rider will be told about this report by somebody, and the driver will have
/// written it in thirty seconds in a car park. So:
///
/// - It never accuses. The copy is "somebody left this" and "where you found it",
///   not "the rider lost this". A driver who is not sure should be able to send it
///   anyway, and the wording is what lets them.
/// - It does not make the driver prove anything. There is no photo requirement and
///   no "are you sure" step, because a driver who did not photograph the item is
///   not lying and a driver who *is* lying is not going to be caught by a second
///   dialog.
/// - The correction path is obvious. Reopening the sheet after a trip shows the
///   description already filled in, so fixing a typo is one edit rather than a
///   fresh report an employee has to reconcile with the first.
///
/// ## The current state is shown above the form, not after it
///
/// Once a report exists the driver needs to know whether anybody got it back, and
/// that is more important than editing it. So the card sits on top and the form
/// below it reads as a correction rather than as a first report.
class LeftItemSheet extends StatefulWidget {
  const LeftItemSheet({super.key, required this.controller});

  final LeftItemController controller;

  /// Show the sheet and return the saved report, or null if the driver backed out.
  ///
  /// Returns the report rather than a bool because the caller needs to say
  /// something about *what* was reported -- a lost phone and a forgotten jacket do
  /// not warrant the same acknowledgement.
  static Future<LeftItemReport?> show(
    BuildContext context,
    LeftItemController controller,
  ) {
    return showModalBottomSheet<LeftItemReport>(
      context: context,
      isScrollControlled: true,
      // The keyboard covers the bottom half of this sheet on a 390x844 screen, and
      // a field behind the keyboard is a field the driver cannot see they are
      // typing into.
      builder: (_) => Padding(
        // `viewInsets.bottom` is the keyboard's height, so the sheet's content
        // sits above it rather than under it.
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: LeftItemSheet(controller: controller),
      ),
    );
  }

  @override
  State<LeftItemSheet> createState() => _LeftItemSheetState();
}

class _LeftItemSheetState extends State<LeftItemSheet> {
  // Not `late final` assigned in the post-frame callback: `build` runs before that
  // callback does, so a `late final` field is uninitialised on the first frame and
  // throws. Initialised here and seeded later, which is the shape that survives
  // being opened while a profile read is still in flight.
  final _item = TextEditingController();
  final _description = TextEditingController();
  bool _seeded = false;

  @override
  void initState() {
    super.initState();
    // Seeded from the existing report the first time the controller has one, and
    // only the first time. Re-seeding on every rebuild would overwrite whatever
    // the driver is typing with the stored text the moment they changed a
    // character, which is the one thing a form must never do.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await widget.controller.load();
      if (!mounted || _seeded) return;
      final existing = widget.controller.report;
      if (existing != null) {
        _item.text = existing.item;
        _description.text = existing.description;
      }
      _seeded = true;
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _item.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final ok = await widget.controller.save(
      item: _item.text,
      description: _description.text,
    );
    if (!ok || !mounted) return;
    // Pop with the saved row rather than `true`, because the caller wants to know
    // what was reported.
    Navigator.of(context).pop(widget.controller.report);
  }

  @override
  Widget build(BuildContext context) {
    final theme = MngTheme.light.textTheme;
    return SafeArea(
      top: false,
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final c = widget.controller;
          final existing = c.report;
          final itemProblem = LeftItemController.problemFor(
            item: _item.text,
            description: _description.text,
          );

          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(20.w, 20.h, 20.w, 20.h),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  existing == null ? 'Something left behind?' : 'Your report',
                  style: theme.titleLarge,
                ),
                SizedBox(height: 6.h),
                Text(
                  existing == null
                      // "Somebody" rather than "the rider". A driver who is not
                      // certain whose it was must be able to send this, and the
                      // word is what lets them.
                      ? 'Tell us what somebody left in your car. An administrator '
                            'will contact them.'
                      : 'You can change what you wrote at any time.',
                  style: theme.bodySmall?.copyWith(color: MngColors.textSub),
                ),
                if (existing != null) ...[
                  SizedBox(height: 16.h),
                  _StatusCard(report: existing),
                ],
                SizedBox(height: 20.h),
                TextField(
                  key: const Key('leftItemField'),
                  controller: _item,
                  autofocus: existing == null,
                  maxLength: LeftItemController.kMaxItem,
                  textCapitalization: TextCapitalization.sentences,
                  inputFormatters: [
                    LengthLimitingTextInputFormatter(LeftItemController.kMaxItem),
                  ],
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'What was it',
                    hintText: 'Blue rucksack',
                  ),
                ),
                SizedBox(height: 12.h),
                TextField(
                  key: const Key('leftItemDescriptionField'),
                  controller: _description,
                  minLines: 2,
                  maxLines: 4,
                  maxLength: LeftItemController.kMaxDescription,
                  textCapitalization: TextCapitalization.sentences,
                  inputFormatters: [
                    LengthLimitingTextInputFormatter(LeftItemController.kMaxDescription),
                  ],
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Where you found it',
                    hintText: 'In the back, under the floor mat',
                    // Optional in the sentence rather than as an asterisk, because
                    // "her blue bag" is a complete report and insisting on a second
                    // sentence only produces "yes".
                    helperText: 'Optional, but it helps',
                  ),
                ),
                if (c.problem != null) ...[
                  SizedBox(height: 4.h),
                  Text(
                    c.problem!,
                    key: const Key('leftItemProblem'),
                    style: theme.bodySmall?.copyWith(color: MngColors.error),
                  ),
                ],
                SizedBox(height: 16.h),
                FilledButton(
                  key: const Key('leftItemSendButton'),
                  onPressed: c.saving ||
                          !LeftItemController.isSendable(
                            item: _item.text,
                            description: _description.text,
                          )
                      ? null
                      : _send,
                  child: c.saving
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(c.actionLabel),
                ),
                if (itemProblem != null && itemProblem.contains('What was left'))
                  SizedBox(height: 0.h)
                else
                  // A hint about the constraint only once something has been typed,
                  // so an untouched form does not open by telling the driver about
                  // a limit they have not reached.
                  const SizedBox.shrink(),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// What has happened to the report, if there is one.
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.report});

  final LeftItemReport report;

  @override
  Widget build(BuildContext context) {
    final theme = MngTheme.light.textTheme;
    return Container(
      key: const Key('leftItemStatus'),
      padding: EdgeInsets.all(14.w),
      decoration: BoxDecoration(
        color: MngColors.muted,
        borderRadius: BorderRadius.circular(12.w),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                report.isReturned ? Icons.check_circle_outline : Icons.schedule,
                size: 18,
                color: report.isReturned ? MngColors.success : MngColors.textSub,
              ),
              SizedBox(width: 8.w),
              Expanded(
                child: Text(
                  report.stateLabel,
                  key: const Key('leftItemStateLabel'),
                  style: theme.titleSmall?.copyWith(
                    color: report.isReturned ? MngColors.success : MngColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          // The employee's words, shown verbatim and attributed. A driver told
          // "answered" with nothing under it has been told nothing, and this is
          // the only channel a driver has to hear what happened.
          if (report.staffNote.trim().isNotEmpty) ...[
            SizedBox(height: 8.h),
            Text(
              report.staffNote,
              key: const Key('leftItemStaffNote'),
              style: theme.bodyMedium,
            ),
          ],
        ],
      ),
    );
  }
}