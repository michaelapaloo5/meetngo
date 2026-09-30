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
  lite(label: 'Lite', perKmGhs: 0.28),
  standard(label: 'Standard', perKmGhs: 0.35),
  premium(label: 'Premium', perKmGhs: 0.46);

  const RideCategory({required this.label, required this.perKmGhs});

  final String label;

  /// 28, 35 and 46 cedis per kilometre. Fuel is about GHS 0.025 per km at
  /// 20 cedis/litre and 8 km/litre, so even the dearest tier spends under a
  /// tenth of the fare on fuel and the rest covers tyres, servicing, wear and
  /// the driver's time.
  final double perKmGhs;

  Color get color => switch (this) {
    RideCategory.standard => MngColors.standard,
    RideCategory.premium => MngColors.premium,
    RideCategory.lite => MngColors.lite,
  };
}
