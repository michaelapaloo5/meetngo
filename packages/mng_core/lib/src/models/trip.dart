import 'category.dart';
import 'geo_point.dart';
import '../trip/trip_state.dart';

class TripStop {
  const TripStop(this.label, this.point, this.address);

  factory TripStop.fromJson(Map<String, dynamic> json) => TripStop(
        (json['label'] as String?) ?? '',
        GeoPoint.fromJson(json['point'] as Map<String, dynamic>),
        (json['address'] as String?) ?? '',
      );

  final String label;
  final GeoPoint point;
  final String address;

  Map<String, dynamic> toJson() => {
        'label': label,
        'point': point.toJson(),
        'address': address,
      };
}

class Trip {
  const Trip({
    required this.id,
    required this.riderId,
    required this.driverId,
    required this.category,
    required this.state,
    required this.pickup,
    required this.dropoff,
    required this.distanceKm,
    required this.fareGhs,
    this.isDemo = true,
    this.etaMinutes,
  });

  factory Trip.fromJson(Map<String, dynamic> json) => Trip(
        id: json['id'] as String,
        riderId: json['rider_id'] as String,
        driverId: json['driver_id'] as String?,
        category: RideCategory.values.byName(json['category'] as String),
        state: TripState.values.byName(json['state'] as String),
        pickup: TripStop.fromJson(json['pickup'] as Map<String, dynamic>),
        dropoff: TripStop.fromJson(json['dropoff'] as Map<String, dynamic>),
        distanceKm: (json['distance_km'] as num).toDouble(),
        fareGhs: (json['fare_ghs'] as num).toDouble(),
        isDemo: (json['is_demo'] as bool?) ?? true,
        etaMinutes: (json['eta_minutes'] as num?)?.toInt(),
      );

  final String id;
  final String riderId;
  final String? driverId;
  final RideCategory category;
  final TripState state;
  final TripStop pickup;
  final TripStop dropoff;
  final double distanceKm;
  final double fareGhs;
  final bool isDemo;
  final int? etaMinutes;

  bool get hasDriver => driverId != null;

  Trip copyWith({
    TripState? state,
    String? driverId,
    bool clearDriver = false,
    int? etaMinutes,
  }) =>
      Trip(
        id: id,
        riderId: riderId,
        driverId: clearDriver ? null : (driverId ?? this.driverId),
        category: category,
        state: state ?? this.state,
        pickup: pickup,
        dropoff: dropoff,
        distanceKm: distanceKm,
        fareGhs: fareGhs,
        isDemo: isDemo,
        etaMinutes: etaMinutes ?? this.etaMinutes,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'rider_id': riderId,
        'driver_id': driverId,
        'category': category.name,
        'state': state.name,
        'pickup': pickup.toJson(),
        'dropoff': dropoff.toJson(),
        'distance_km': distanceKm,
        'fare_ghs': fareGhs,
        'is_demo': isDemo,
        'eta_minutes': etaMinutes,
      };
}
