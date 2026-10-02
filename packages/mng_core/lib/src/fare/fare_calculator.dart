import 'dart:math' as math;

import '../models/category.dart';

class FareQuote {
  const FareQuote({
    required this.fareGhs,
    required this.surge,
    required this.discountGhs,
    required this.distanceKm,
  });

  final double fareGhs;
  final double surge;
  final double discountGhs;
  final double distanceKm;
}

class FareCalculator {
  FareCalculator({
    this.baseGhs = 0.0,
    this.bookingFeeGhs = 0.0,
    this.commissionRate = 0.15,
    this.maxSurge = 2.0,
  });

  /// Zero, deliberately. See the note on [BASE_GHS] in
  /// `supabase/functions/request-ride/fare.ts`, which is the authority for
  /// this model and carries the arithmetic.
  final double baseGhs;

  /// Zero, deliberately. See [baseGhs].
  final double bookingFeeGhs;

  // There is no `minFareGhs` here any more. It was a single 0.15 applied to
  // every tier, and it was the reason the whole price scale was wrong: a
  // per-kilometre rate of 0.28 with a floor of 0.15 means a real Accra trip costs
  // whatever the distance says and nothing else, which priced Tesano to Dansoman
  // at GHS 1.94. The floor is now per tier and lives on `RideCategory.minFareGhs`
  // -- 17, 23 and 28 -- because one floor for all three tiers made the tiers
  // indistinguishable.
  //
  // It is not optional and it is not a default here because a default is how it
  // was wrong in the first place: a caller who forgot to set it got a 15-cedi
  // floor and a price no driver would accept.

  final double commissionRate;
  final double maxSurge;

  /// fare = max(category minimum, (base + perKm * distance) * surge) + booking.
  ///
  /// The floor is the tier's own [RideCategory.minFareGhs] -- 17, 23 or 28 -- and
  /// not one number for all of them. That is the change that makes the tiers
  /// mean anything: with a single floor above every real fare, all three
  /// charged exactly the same.
  ///
  /// There is no discount parameter any more. `RIDE30` took 30% off every ride
  /// for every rider, capped at GHS 40 server-side and not at all client-side --
  /// so above GHS 133.33 the rider agreed to a price lower than the one they
  /// were charged. Removing the offer removes the second calculation, and with
  /// it the only place in this app where the number on screen and the number on
  /// the bill could disagree.
  ///
  /// A negative distance collapses to zero so a reversed pin never yields a
  /// negative fare. A non-finite distance is a caller bug and throws.
  FareQuote quote({
    required RideCategory category,
    required double distanceKm,
    double surge = 1.0,
  }) {
    if (distanceKm.isNaN || distanceKm.isInfinite) {
      throw ArgumentError.value(distanceKm, 'distanceKm', 'must be finite');
    }
    final km = math.max(0.0, distanceKm);
    final appliedSurge = surge.clamp(1.0, maxSurge).toDouble();
    // The floor is the tier's, and it is applied *inside* the surge so a
    // surge-priced ride never dips below what the tier guarantees.
    final distanceFare = math.max(
      category.minFareGhs,
      (baseGhs + category.perKmGhs * km) * appliedSurge,
    );
    final raw = distanceFare + bookingFeeGhs;
    return FareQuote(
      fareGhs: round2(math.max(0.0, raw)),
      surge: appliedSurge,
      discountGhs: 0,
      distanceKm: km,
    );
  }

  /// What a driver takes home once [rate] is deducted, which is [rate] and not
  /// this calculator's own [commissionRate] so a trip inside the launch promo
  /// settles at zero.
  double driverPayoutGhsAt(FareQuote quote, double rate) {
    if (rate.isNaN || rate.isInfinite) {
      throw ArgumentError.value(rate, 'rate', 'must be finite');
    }
    return round2(quote.fareGhs * (1 - rate));
  }

  double driverPayoutGhs(FareQuote quote) =>
      driverPayoutGhsAt(quote, commissionRate);

  static double round2(double value) => (value * 100).roundToDouble() / 100;
}
