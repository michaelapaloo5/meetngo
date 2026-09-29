import 'package:flutter/material.dart';
import 'package:mng_core/mng_core.dart';

/// The rider-facing name for a trip state.
///
/// Read off [TripState] rather than written out a second time, so a state
/// added to the database enum cannot be left unlabelled. The four live states
/// are phrased as what is happening now, and the two terminal ones as what
/// happened, because "Cancelled" next to a ride the rider is watching is
/// ambiguous and "Trip cancelled" is not.
String tripStateLabel(TripState state) => switch (state) {
      TripState.requested => 'Finding a driver',
      TripState.matched => 'Driver assigned',
      TripState.arriving => 'Driver arriving',
      TripState.ongoing => 'On the way',
      TripState.completed => 'Trip completed',
      TripState.cancelled => 'Trip cancelled',
    };

/// The colour a state badge is filled with.
///
/// In-progress states take the brand yellow and the two terminal states take
/// green and grey, so a completed ride cannot be mistaken at a glance for one
/// that is still running. A rider scanning the bookings list is looking for the
/// difference between "done" and "live", and that difference has to survive
/// being 8 pixels tall.
Color tripStateColor(TripState state) => switch (state) {
      TripState.requested ||
      TripState.matched ||
      TripState.arriving ||
      TripState.ongoing =>
        MngColors.primary,
      TripState.completed => MngColors.success,
      TripState.cancelled => MngColors.textSub,
    };

/// The text colour that stays legible on top of [tripStateColor].
Color tripStateTextColor(TripState state) => switch (state) {
      TripState.completed || TripState.cancelled => MngColors.page,
      _ => MngColors.onPrimary,
    };

const _months = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// A trip's `created_at` as `12 Sep, 14:30`.
///
/// Written out here rather than pulled from `package:intl`, which is a
/// transitive dependency of `flutter_map` and therefore not in this app's
/// `pubspec.yaml`; importing it is a `depend_on_referenced_packages` info and
/// this repo's CI runs `--fatal-infos`. The two figures are padded to two
/// digits by the GHS fare's own formatting, and 24-hour time is used because
/// the pilot area has one and a 12-hour clock invites a morning/evening
/// mistake at a glance.
String formatTripMoment(DateTime when) {
  final local = when.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '${local.day} ${_months[local.month - 1]}, $hour:$minute';
}

/// Money in the only currency this app quotes.
String formatGhs(double amount) => 'GHS ${amount.toStringAsFixed(2)}';

/// One end of a route, for a list row.
///
/// `TripStop` has no value equality, so nothing compares stops; this reads the
/// field a rider recognises. The fallback used to be the coordinate, and it was
/// wrong twice over: a row of `5.6037, -0.1870` tells a rider nothing they can
/// act on, and it is the one entry in a list of real places that does not look
/// like a place. A stop with no address is a stop this build could not name, so
/// it says the part it does know and stops there.
String stopLabel(TripStop stop) {
  final address = stop.address.trim();
  if (address.isNotEmpty) return address;
  return stop.label.trim().isEmpty ? 'Pickup or drop-off' : stop.label.trim();
}
