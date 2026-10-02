import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Launch categories. Moto is excluded on purpose, see spec section 3.1.
///
/// `lite` was `van`. The tier is the small-vehicle one, so the name said
/// nothing about what a rider was buying, and `van` is still a real word in
/// this codebase for a different thing: `Vehicle.bodyStyle` keeps
/// `sedan/suv/van/luxury`, which describes the shape of the car and is not a
/// service a driver sells. Conflating the two would have made a body style
/// selectable as a fare tier.
enum RideCategory {
  lite(label: 'Lite', perKmGhs: 6.00, minFareGhs: 17.00),
  standard(label: 'Standard', perKmGhs: 8.00, minFareGhs: 23.00),
  premium(label: 'Premium', perKmGhs: 10.00, minFareGhs: 28.00);

  const RideCategory({
    required this.label,
    required this.perKmGhs,
    required this.minFareGhs,
  });

  final String label;

  /// **GHS 6.00, 8.00 and 10.00 per kilometre.**
  ///
  /// These were 0.28 / 0.35 / 0.46, which were written against a GHS 0.15
  /// minimum fare and were never sane on their own: they priced a real Accra
  /// trip from Tesano to Dansoman at GHS 1.94, 2.43 and 3.19 -- less than the
  /// fuel, and less than the driver's time for the hour it took.
  ///
  /// Fuel is about GHS 0.25 per km at 20 cedis per litre and 8 km per litre, so
  /// the old rates spent about a ninth of the fare on fuel *before* the 30%
  /// launch discount took a third of the rest away. At these rates fuel is about
  /// 4%, 3% and 2.5%, and the rest covers tyres, servicing, wear and the time.
  final double perKmGhs;

  /// What the shortest ride costs: **GHS 17, 23 and 28**.
  ///
  /// Per tier, not one floor for all three. A single floor is what made the tiers
  /// meaningless: with a floor above every real fare, Lite and Standard and
  /// Premium all charged exactly the same number and the rider was choosing
  /// between identical prices.
  ///
  /// This is the number a rider is quoted for a hop across one neighbourhood, so
  /// it is the number that has to be defensible -- it is what a driver earns for
  /// a short trip, and what a rider is told before they commit to anything.
  final double minFareGhs;

  Color get color => switch (this) {
    RideCategory.standard => MngColors.standard,
    RideCategory.premium => MngColors.premium,
    RideCategory.lite => MngColors.lite,
  };
}
