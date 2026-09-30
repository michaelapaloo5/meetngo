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
    this.minFareGhs = 0.15,
    this.commissionRate = 0.15,
    this.maxSurge = 2.0,
  });

  /// Zero, deliberately. See the note on [BASE_GHS] in
  /// `supabase/functions/request-ride/fare.ts`, which is the authority for
  /// this model and carries the arithmetic.
  final double baseGhs;

  /// Zero, deliberately. See [baseGhs].
  final double bookingFeeGhs;

  /// The floor: 15 cedis. A ride shorter than about half a kilometre costs
  /// this, so the thinnest possible margin still covers the driver moving the
  /// car.
  final double minFareGhs;

  final double commissionRate;
  final double maxSurge;

  /// fare = max(minFare, (base + perKm * distance) * surge) + booking - discount.
  ///
  /// The floor goes on the distance-priced fare and the discount comes off
  /// afterwards, in that order. Flooring last would let a promo push a fare
  /// below the cost of the drive; flooring first and discounting inside the
  /// `max` would make a promo code unable to reduce any short trip at all,
  /// because the floor would swallow it and the rider would be told they paid
  /// less when they did not.
  ///
  /// A negative distance collapses to zero so a reversed pin never yields a
  /// negative fare. A non-finite distance is a caller bug and throws.
  FareQuote quote({
    required RideCategory category,
    required double distanceKm,
    double surge = 1.0,
    double discountGhs = 0.0,
  }) {
    if (distanceKm.isNaN || distanceKm.isInfinite) {
      throw ArgumentError.value(distanceKm, 'distanceKm', 'must be finite');
    }
    final km = math.max(0.0, distanceKm);
    final appliedSurge = surge.clamp(1.0, maxSurge).toDouble();
    final discount = math.max(0.0, discountGhs);
    final distanceFare = math.max(
      minFareGhs,
      (baseGhs + category.perKmGhs * km) * appliedSurge,
    );
    final raw = distanceFare + bookingFeeGhs - discount;
    return FareQuote(
      fareGhs: round2(math.max(0.0, raw)),
      surge: appliedSurge,
      discountGhs: discount,
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
