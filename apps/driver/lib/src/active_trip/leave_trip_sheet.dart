import 'package:flutter/material.dart';
import 'package:mng_core/mng_core.dart';

import 'leave_trip_controller.dart';

/// Ask a driver why they are leaving, then leave.
///
/// ## Why a reason is asked at all, and why the list is short
///
/// The reason exists for whoever reads these later. A queue of "rider not at
/// pickup" is a signal about a street; a queue of free text is a signal nobody can
/// act on. So there is a short list of the things that actually happen, and the
/// list is short on purpose -- six entries a driver can scan in one glance in a
/// car park, rather than a taxonomy that turns a two-second action into a form.
///
/// Anything not on the list gets "Something else" and an optional free-text box,
/// because the failure mode of a fixed list is a driver who has a genuinely
/// unusual problem picking the nearest wrong answer.
///
/// ## Why this asks before it acts
///
/// Leaving a trip puts the rider back in the pool and costs them a wait. One
/// careless tap should not do that. A confirmation step is normally the wrong
/// answer -- everybody stops reading confirmations -- so this one is not "are you
/// sure", it is "why", which is a question worth answering on its own and which
/// doubles as the consent. There is no second confirmation after that.
class LeaveTripSheet extends StatefulWidget {
  const LeaveTripSheet({super.key, required this.controller});

  final LeaveTripController controller;

  /// Returns true when the driver left, false when they backed out.
  static Future<bool> show(
    BuildContext context,
    LeaveTripController controller,
  ) async {
    final left = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: LeaveTripSheet(controller: controller),
      ),
    );
    return left ?? false;
  }

  @override
  State<LeaveTripSheet> createState() => _LeaveTripSheetState();
}

class _LeaveTripSheetState extends State<LeaveTripSheet> {
  LeaveReason? _chosen;
  final _detail = TextEditingController();

  @override
  void dispose() {
    _detail.dispose();
    super.dispose();
  }

  Future<void> _leave() async {
    final reason = _chosen;
    if (reason == null) return;
    final ok = await widget.controller.leave(reason, detail: _detail.text);
    if (!mounted || !ok) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = MngTheme.light.textTheme;
    return SafeArea(
      top: false,
      // Animated on the controller, and this is load-bearing rather than tidy.
      // `busy` and `problem` both live on the controller and both change during a
      // send; without a listener here the sheet would sit on its "Leave this trip"
      // button, ignore the refusal, and give the driver no reason at all. The
      // first version of this file read `widget.controller.problem` in `build` and
      // had no `AnimatedBuilder`, and the test that says a refusal is shown failed
      // because of it.
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Why are you leaving?', style: theme.titleLarge),
              const SizedBox(height: 6),
              Text(
                // Says what will happen, before it happens. The rider is put back in
                // the pool and somebody else is offered the trip -- a driver who does
                // not know that is being asked to decide twice.
                'Your rider goes back on the list and we look for another driver.',
                style: theme.bodySmall?.copyWith(color: MngColors.textSub),
              ),
              const SizedBox(height: 16),
              // `RadioGroup`, not `groupValue`/`onChanged` on each tile. Flutter
              // deprecated the per-tile form after 3.32 and it will become a hard
              // error. The comment that used to be here justified keeping it by saying
              // "one idiom, not two, and the deprecated form still works" -- but this
              // sheet was the only `Radio` in the driver app, so there was no second
              // idiom to be consistent with and nothing to gain. The replacement has
              // the same `groupValue`/`onChanged` pair one level up.
              RadioGroup<LeaveReason>(
                groupValue: _chosen,
                onChanged: (v) => setState(() => _chosen = v),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final reason in LeaveReason.values)
                      RadioListTile<LeaveReason>(
                        key: Key('leaveReason_${reason.slug}'),
                        value: reason,
                        title: Text(reason.prompt, style: theme.bodyMedium),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                      ),
                  ],
                ),
              ),
              if (_chosen == LeaveReason.other) ...[
                const SizedBox(height: 8),
                TextField(
                  key: const Key('leaveDetailField'),
                  controller: _detail,
                  maxLines: 2,
                  maxLength: 240,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Tell us what happened',
                    helperText: 'Optional, but it helps whoever looks at this',
                  ),
                ),
              ],
              if (widget.controller.problem != null) ...[
                const SizedBox(height: 4),
                Text(
                  widget.controller.problem!,
                  key: const Key('leaveProblem'),
                  style: theme.bodySmall?.copyWith(color: MngColors.error),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('leaveConfirmButton'),
                onPressed: _chosen == null || widget.controller.busy
                    ? null
                    : _leave,
                style: FilledButton.styleFrom(backgroundColor: MngColors.error),
                child: widget.controller.busy
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Leave this trip'),
              ),
              const SizedBox(height: 6),
              TextButton(
                key: const Key('leaveCancelButton'),
                onPressed: widget.controller.busy
                    ? null
                    : () => Navigator.of(context).pop(false),
                child: const Text('Keep driving'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
