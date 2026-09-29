import '../models/geo_point.dart';

/// A vehicle's position and which way it is pointing.
///
/// A [GeoPoint] alone cannot express the second half, and that half is the
/// difference between a car and a dot: a dot on a route is a position, while a
/// car that turns as it approaches the pickup is the only thing on the screen
/// that tells a rider which end of the journey they are watching. Modelling it
/// as a separate type rather than adding a `heading` field to [GeoPoint] keeps
/// a coordinate a coordinate — [GeoPoint] is compared, hashed and used as a map
/// key in several places, and a mutable heading would make "same place" a
/// question with two answers.
class VehicleFix {
  const VehicleFix(this.point, [this.bearing]);

  /// Where it is.
  final GeoPoint point;

  /// Which way it is facing, in degrees clockwise from north, or null when
  /// there is no compass reading to be had.
  ///
  /// Null is a real value, not an error to be papered over. A phone lying flat
  /// on a seat has no heading, a desktop has no compass at all, and a phone
  /// indoors reports a heading it invented. Drawing a car pointed north in
  /// those cases is a small lie the rider cannot detect, which is why the
  /// consumer is documented to fall back rather than why the value is faked
  /// here.
  final double? bearing;

  /// [bearing] normalised into 0-360, or 0 when there is none.
  ///
  /// A compass reports -1 and 360 as well as 0-359 depending on the device and
  /// on whether it has ever had a fix, and a rotation of -1 or 360 is a car
  /// spun nearly all the way round for no reason. Normalising at the boundary
  /// means the style's `icon-rotate` only ever sees a sane angle.
  double get headingDegrees {
    final b = bearing;
    if (b == null || b.isNaN) return 0;
    return ((b % 360) + 360) % 360;
  }

  @override
  bool operator ==(Object other) =>
      other is VehicleFix &&
      other.point == point &&
      other.headingDegrees == headingDegrees;

  @override
  int get hashCode => Object.hash(point, headingDegrees);

  @override
  String toString() => 'VehicleFix($point, ${headingDegrees.toStringAsFixed(1)}deg)';
}

/// A reading's heading, or null when the reading carries no usable one.
///
/// Geolocator reports a heading of -1 for "no compass" and occasionally a NaN,
/// and both have to be turned into null before they reach [VehicleFix] --
/// otherwise a car on a desk spins to 359 degrees. Shared here because the
/// driver's reader and any future reader are exactly the same check, and
/// duplicated it is duplicated with a different bug in each copy.
double? normaliseBearing(num? raw) {
  if (raw == null) return null;
  final d = raw.toDouble();
  if (d.isNaN || d < 0) return null;
  return d;
}
