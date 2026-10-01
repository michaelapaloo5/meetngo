import 'package:flutter/material.dart';
import 'package:mng_core/mng_core.dart';

/// Tells a driver they still have a trip, when they come back to the app.
///
/// ## What this is for
///
/// A driver's phone dies, or they force-quit, or Android kills the app to reclaim
/// memory while they are driving. On reopening it, the trip is still theirs: the
/// rider is waiting, the trip clock is running, and nothing has been cancelled.
///
/// Today the shell answers that by putting them straight into the trip screen,
/// which is defensible and unhelpful at once. They arrive with no idea what
/// happened while they were away -- it is now twenty minutes later, the rider has
/// called twice, and the first thing on screen is a map with a pin. A driver
/// cannot tell from that whether they are ten minutes out or an hour, and being
/// unsure is the thing that makes people call somebody instead of driving.
///
/// So they land on the home screen with this above it, and the trip is one tap
/// away. Not a dialog: a dialog is a thing to be dismissed, and dismissing this
/// loses the only statement of what they are in the middle of.
///
/// ## Why it is not louder
///
/// It is not red, and it does not shake. A driver who force-quits their phone
/// mid-journey did something ordinary by accident, and an alarming banner teaches
/// them that reopening the app is punished. Amber and a plain button is enough:
/// visible at the top of the screen, impossible to mistake for anything else,
/// dismissible only by acting on it.
///
/// ## The two states
///
/// [TripState.ongoing] and everything before it read differently, and the
/// difference is the whole point of the banner rather than its styling. A driver
/// with a rider *in the car* needs to know that before anything else, because it
/// changes what they do next -- they are driving, not looking for a phone.
class ReturnTripBanner extends StatelessWidget {
  const ReturnTripBanner({
    super.key,
    required this.trip,
    required this.onOpen,
    this.riderName,
  });

  /// The trip the driver is still holding. Not a count and not a boolean: the
  /// banner's whole job is to say *what* they are in the middle of, and a
  /// "You have an active trip" tells a driver nothing they can act on.
  final Trip trip;

  /// The rider's name, when it is known.
  ///
  /// Passed in rather than read off [Trip], because `Trip` carries only a
  /// `rider_id` -- the driver app has no policy permitting it to read another
  /// user's profile, which is exactly why the rider's phone number comes from the
  /// `contact` Edge Function. Inventing a field here would be a second, wrong
  /// answer to a question the contact controller has already answered.
  ///
  /// Null means the lookup has not landed yet, and the wording falls back to
  /// "your rider" rather than showing a blank or a uuid.
  final String? riderName;

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final text = MngTheme.light.textTheme;
    final withRider = trip.state == TripState.ongoing;
    final who = (riderName ?? '').trim();
    final rider = who.isEmpty ? 'your rider' : who;

    return Container(
      key: const Key('returnTripBanner'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
      decoration: BoxDecoration(
        // The brand colour rather than a warning colour. Not an error: the rider
        // is waiting and the trip is fine, the driver simply lost the thread of it.
        color: MngColors.primary,
        borderRadius: BorderRadius.circular(MngRadius.large),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  withRider ? 'Your rider is in the car' : 'You still have a trip',
                  key: const Key('returnTripTitle'),
                  style: text.titleSmall?.copyWith(color: MngColors.onPrimary),
                ),
                const SizedBox(height: 2),
                // The pickup, not the trip id. A driver who has just reopened the
                // app knows nothing about uuids, and "collect Ama at Osu Junction"
                // is the entire question they are trying to answer.
                Text(
                  withRider
                      ? 'To ${trip.dropoff.label} with $rider'
                      : 'Collect at ${trip.pickup.label}',
                  key: const Key('returnTripDetail'),
                  style: text.bodySmall?.copyWith(color: MngColors.onPrimary),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // `Flexible`, and this is not decoration.
          //
          // A Row lays out its non-flex children with *unbounded* main-axis
          // constraints -- it has to measure them before it knows how much room is
          // left for the flex children. So `Expanded` beside a bare `FilledButton`
          // hands the button `maxWidth: Infinity`, and `RenderPhysicalShape`
          // throws "BoxConstraints forces an infinite width" on the first frame.
          //
          // Every other Row in this app puts `Expanded` on both sides, which is why
          // none of them have hit it. Here only the text should flex, so the button
          // is `Flexible`: it gets the remaining space as a maximum and still sizes
          // to its own label, and it shrinks on a narrow phone instead of
          // overflowing beside a long place name.
          Flexible(
            child: FilledButton(
              key: const Key('returnTripOpenButton'),
              onPressed: onOpen,
              style: FilledButton.styleFrom(
                backgroundColor: MngColors.onPrimary,
                foregroundColor: MngColors.primary,
              ),
              child: Text(withRider ? 'Continue' : 'View trip'),
            ),
          ),
        ],
      ),
    );
  }
}