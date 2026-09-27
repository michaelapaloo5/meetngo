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
    this.baseGhs = 5.00,
    this.bookingFeeGhs = 1.00,
    this.commissionRate = 0.15,
    this.maxSurge = 2.0,
  });

  final double baseGhs;
  final double bookingFeeGhs;
  final double commissionRate;
  final double maxSurge;

  /// fare = (base + perKm * distance) * surge + bookingFee - discount.
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
    final raw = (baseGhs + category.perKmGhs * km) * appliedSurge +
        bookingFeeGhs -
        discountGhs;
    return FareQuote(
      fareGhs: round2(math.max(0.0, raw)),
      surge: appliedSurge,
      discountGhs: math.max(0.0, discountGhs),
      distanceKm: km,
    );
  }

  double driverPayoutGhs(FareQuote quote) =>
      round2(quote.fareGhs * (1 - commissionRate));

  static double round2(double value) =>
      (value * 100).roundToDouble() / 100;
}
