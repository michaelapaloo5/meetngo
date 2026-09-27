import 'package:flutter/material.dart';
import '../theme/tokens.dart';

/// Launch categories. Moto is excluded on purpose, see spec section 3.1.
enum RideCategory {
  standard(label: 'Standard', perKmGhs: 1.80),
  premium(label: 'Premium', perKmGhs: 2.80),
  van(label: 'Van', perKmGhs: 2.20);

  const RideCategory({required this.label, required this.perKmGhs});

  final String label;
  final double perKmGhs;

  Color get color => switch (this) {
        RideCategory.standard => MngColors.standard,
        RideCategory.premium => MngColors.premium,
        RideCategory.van => MngColors.van,
      };
}
