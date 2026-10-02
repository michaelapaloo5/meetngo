import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

import 'navigation_controller.dart';
import 'route_progress.dart';

/// The instruction the driver is about to act on, and what it costs them.
///
/// ## Why this is a banner and not a card
///
/// A card is a thing you read. A driver reads this while going forty in a bus with
/// a phone in a mount, at a junction they are already committed to. So: one
/// instruction, the largest text the app has, a distance in the corner, and nothing
/// else competing for attention. No map controls, no dismiss, no scroll.
///
/// ## Why the distance leads on the first step
///
/// The first instruction of a route is "head out", and its distance is the whole
/// first leg. "Head out" with no number is the one instruction that tells a driver
/// nothing, so the banner swaps it for the distance to the first real manoeuvre --
/// which is the question they actually have at that moment.
///
/// ## Why it is one line
///
/// The instruction and the road name were stacked, which made the banner two
/// rows tall. On a phone in a mount, that is two rows of the one thing a driver
/// reads while driving, and it put the road name -- the part that changes as they
/// move -- directly under words they had already read, so the text they were
/// part-way through reading moved out from under them.
///
/// The road name stays, after the instruction on the same line, because it is
/// context a driver needs and not decoration. It is not the biggest thing on the
/// banner and it is what gives way when the line is too long: it is on the map in
/// front of them, and the instruction is not.
class TurnBanner extends StatelessWidget {
  const TurnBanner({super.key, required this.controller, this.onMuteToggle});

  final NavigationController controller;

  /// Mutes and unmutes. Null hides the control, which is what a build without
  /// voice does rather than showing a button that cannot work.
  final VoidCallback? onMuteToggle;

  @override
  Widget build(BuildContext context) {
    // Listen to the controller here, rather than expecting every caller to
    // remember to.
    //
    // This is the third bug of this exact shape in this app -- a value read in
    // `build` with nothing listening for the thing that changes it -- and it is
    // the one that made navigation look broken on the handset. `TurnBanner` reads
    // `currentStep`, `failure`, `distanceToStepM`, `now` and `speakInstructions`
    // off the controller, and it was a `StatelessWidget` reading all of them with
    // no listener at all.
    //
    // `ActiveTripScreen` put its `ListenableBuilder` on the *host*, and the host
    // notifies once, before the fetch is awaited. The route then arrived and the
    // controller notified *its own* listeners, of which there were none. The
    // banner kept whatever it last drew.
    //
    // It worked often enough to look fine. The trip screen also rebuilds on every
    // position fix, so while the driver is moving the banner refreshed by
    // accident and picked up the instruction. Parked, GPS stops ticking, and the
    // banner sat on "Working out the route" indefinitely -- verified on the
    // handset, with the `route` function answering 200 in 200 ms over the same
    // network and the phone demonstrably not rebuilding.
    //
    // Fixed inside the widget, not at the call site. The two earlier instances of
    // this bug were each fixed where they happened to be found, and the third
    // turned up somewhere else entirely -- which is what a call-site fix costs.
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _banner(context),
    );
  }

  Widget _banner(BuildContext context) {
    final text = MngTheme.light.textTheme;
    final step = controller.currentStep;

    return Container(
      key: const Key('turnBanner'),
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(16.w, 12.h, 8.w, 12.h),
      decoration: BoxDecoration(
        color: MngColors.primary,
        borderRadius: BorderRadius.circular(MngRadius.large),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: _body(context, text, step)),
          if (onMuteToggle != null)
            _MuteButton(controller: controller, onTap: onMuteToggle!),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, TextTheme text, RouteStep? step) {
    final isDepart = step?.maneuver == 'depart';
    if (controller.recalculating) {
      return Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: MngColors.onPrimary,
            ),
          ),
          SizedBox(width: 12.w),
          Text(
            'Finding a new route',
            key: const Key('turnBannerRecalculating'),
            style: text.titleMedium?.copyWith(color: MngColors.onPrimary),
          ),
        ],
      );
    }

    // A failure outranks the instruction.
    //
    // The one case this whole widget exists to avoid is a banner confidently telling a
    // driver to turn left when they have already left the route and the new one could
    // not be fetched. The line stays drawn -- a driver off-route is better off on a
    // stale line than with none -- but the instruction stops, because the instruction
    // is the thing that would be wrong.
    //
    // So this is `failure != null`, not `failure != null && route == null`. A route
    // that is present and a failure are not exclusive: they are exactly the situation
    // this branch is for.
    if (step == null || controller.failure != null) {
      final failure = controller.failure;
      return Row(
        children: [
          const Icon(Icons.location_off, color: MngColors.onPrimary),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  failure == null
                      ? 'Working out the route'
                      : 'Route could not be updated',
                  key: const Key('turnBannerMessage'),
                  style: text.titleMedium?.copyWith(color: MngColors.onPrimary),
                ),
                if (failure != null)
                  Text(
                    // The engine's own sentence, and the fallback is an instruction
                    // rather than an apology: a driver who is lost needs to know what
                    // to do next.
                    failure.offline
                        ? 'No connection. Follow the map, or stop and ask.'
                        : failure.message,
                    key: const Key('turnBannerMessageDetail'),
                    style: text.bodySmall?.copyWith(color: MngColors.onPrimary),
                  ),
              ],
            ),
          ),
        ],
      );
    }

    // The first step says "head out", whose distance is the whole first leg. Swapped
    // for the distance to the first real manoeuvre, which is what a driver is
    // actually asking at that moment -- and falls back to the leg's own distance
    // when there is no later step to measure to.
    final toNextManoeuvre = isDepart
        ? _distanceToNextManoeuvre(controller)
        : null;
    final lead = toNextManoeuvre ?? controller.distanceToStepM;
    final leadText = formatDistance(lead);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _ManoeuverIcon(maneuver: step.maneuver),
        SizedBox(width: 14.w),
        Expanded(
          // One line, not two.
          //
          // The instruction and the road name were stacked, which made the
          // banner two rows tall -- and on a phone in a mount, two rows of the
          // one thing a driver reads while driving. It also put the road name,
          // the part that changes as they move, directly under words they had
          // already read, so the text they were part-way through reading moved
          // out from under them.
          //
          // They are one paragraph on one line now, with the weight and colour
          // that say which is the instruction and the road name after it. When
          // the two will not both fit at driving size it is the road name that
          // gives way: it is context, and it is on the map in front of them.
          child: RichText(
            key: const Key('turnBannerInstruction'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              children: [
                TextSpan(
                  text: step.instruction,
                  style: text.titleLarge?.copyWith(
                    color: MngColors.onPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (step.name.isNotEmpty)
                  TextSpan(
                    text: ' \u00b7 ${step.name}',
                    style: text.bodySmall?.copyWith(color: MngColors.onPrimary),
                  ),
              ],
            ),
          ),
        ),
        SizedBox(width: 10.w),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              leadText,
              key: const Key('turnBannerDistance'),
              style: text.titleLarge?.copyWith(
                color: MngColors.onPrimary,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (controller.arrivalAt != null)
              Text(
                formatArrivalClock(controller.now, controller.route!.durationS),
                key: const Key('turnBannerArrival'),
                style: text.labelSmall?.copyWith(color: MngColors.onPrimary),
              ),
          ],
        ),
      ],
    );
  }

  /// Distance along the route to the first step after a `depart`.
  ///
  /// Null when there is no such step, in which case the caller falls back to the
  /// step's own distance rather than showing a number it does not have.
  double? _distanceToNextManoeuvre(NavigationController controller) {
    final route = controller.route;
    final progress = controller.progress;
    if (route == null || progress == null) return null;
    final next = progress.stepIndex + 1;
    if (next >= route.steps.length) return null;
    // The steps' distances are legs in order, so what is left of this leg is what
    // is left of the route before the next manoeuvre.
    final remainingInLeg =
        route.steps[progress.stepIndex].distanceM - progress.distanceToStepM;
    final ahead = route.steps
        .sublist(next)
        .fold<double>(0, (sum, s) => sum + s.distanceM);
    final total = remainingInLeg + ahead;
    return total.isFinite && total > 0 ? total : null;
  }
}

/// The turn glyph.
///
/// Drawn from the engine's `maneuver` rather than from the instruction text,
/// because OSRM's vocabulary is a fixed set and matching on it is exact. A glyph
/// chosen by looking for "left" in a sentence is a glyph that silently vanishes the
/// first time the wording changes.
class _ManoeuverIcon extends StatelessWidget {
  const _ManoeuverIcon({required this.maneuver});

  final String maneuver;

  @override
  Widget build(BuildContext context) {
    final icon = switch (maneuver) {
      'arrive' => Icons.flag_outlined,
      'depart' => Icons.navigation,
      'roundabout' => Icons.rotate_right,
      'merge' => Icons.merge,
      'fork' => Icons.call_split,
      'end of road' => Icons.turn_left,
      'on ramp' => Icons.trending_up,
      'off ramp' => Icons.exit_to_app,
      'continue' => Icons.straight,
      _ => Icons.turn_slight_right,
    };
    return Icon(icon, size: 34, color: MngColors.onPrimary);
  }
}

class _MuteButton extends StatelessWidget {
  const _MuteButton({required this.controller, required this.onTap});

  final NavigationController controller;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const Key('turnBannerMute'),
      onPressed: onTap,
      tooltip: controller.speakInstructions
          ? 'Turn voice off'
          : 'Turn voice on',
      icon: Icon(
        controller.speakInstructions ? Icons.volume_up : Icons.volume_off,
        color: MngColors.onPrimary,
      ),
    );
  }
}
