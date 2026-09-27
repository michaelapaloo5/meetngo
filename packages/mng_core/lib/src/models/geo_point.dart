import 'dart:math' as math;

class GeoPoint {
  const GeoPoint(this.lat, this.lng);

  factory GeoPoint.fromJson(Map<String, dynamic> json) => GeoPoint(
        (json['lat'] as num).toDouble(),
        (json['lng'] as num).toDouble(),
      );

  final double lat;
  final double lng;

  static const double _earthRadiusKm = 6371.0088;

  /// Great-circle distance. Used for driver proximity and the fare preview;
  /// routed distance comes from the backend RPC.
  double distanceKmTo(GeoPoint other) {
    final dLat = _rad(other.lat - lat);
    final dLng = _rad(other.lng - lng);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_rad(lat)) *
            math.cos(_rad(other.lat)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return _earthRadiusKm * 2 * math.asin(math.min(1.0, math.sqrt(a)));
  }

  static double _rad(double deg) => deg * math.pi / 180.0;

  Map<String, dynamic> toJson() => {'lat': lat, 'lng': lng};

  @override
  bool operator ==(Object other) =>
      other is GeoPoint && other.lat == lat && other.lng == lng;

  @override
  int get hashCode => Object.hash(lat, lng);

  @override
  String toString() => 'GeoPoint($lat, $lng)';
}
