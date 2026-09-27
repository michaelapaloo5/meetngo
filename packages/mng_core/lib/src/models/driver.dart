import 'geo_point.dart';

enum DriverAvailability { offline, online, onTrip }

enum KycStatus { notStarted, pending, approved, rejected }

class DriverProfile {
  const DriverProfile({
    required this.id,
    required this.fullName,
    required this.phone,
    required this.rating,
    required this.tripCount,
    required this.kyc,
    required this.availability,
    this.photoUrl = '',
    this.vehicleId,
    this.location,
  });

  factory DriverProfile.fromJson(Map<String, dynamic> json) => DriverProfile(
        id: json['id'] as String,
        fullName: (json['full_name'] as String?) ?? '',
        phone: (json['phone'] as String?) ?? '',
        photoUrl: (json['photo_url'] as String?) ?? '',
        rating: ((json['rating'] as num?) ?? 5.0).toDouble(),
        tripCount: (json['trip_count'] as num?)?.toInt() ?? 0,
        kyc: KycStatus.values
            .byName((json['kyc_status'] as String?) ?? 'notStarted'),
        availability: DriverAvailability.values
            .byName((json['availability'] as String?) ?? 'offline'),
        vehicleId: json['vehicle_id'] as String?,
        location: json['lat'] == null
            ? null
            : GeoPoint(
                (json['lat'] as num).toDouble(),
                (json['lng'] as num).toDouble(),
              ),
      );

  final String id;
  final String fullName;
  final String phone;
  final String photoUrl;
  final double rating;
  final int tripCount;
  final KycStatus kyc;
  final DriverAvailability availability;
  final String? vehicleId;
  final GeoPoint? location;

  bool get isApproved => kyc == KycStatus.approved;

  bool get canAcceptOffers =>
      isApproved && availability == DriverAvailability.online;

  DriverProfile copyWith({
    DriverAvailability? availability,
    KycStatus? kyc,
    GeoPoint? location,
    String? vehicleId,
  }) =>
      DriverProfile(
        id: id,
        fullName: fullName,
        phone: phone,
        photoUrl: photoUrl,
        rating: rating,
        tripCount: tripCount,
        kyc: kyc ?? this.kyc,
        availability: availability ?? this.availability,
        vehicleId: vehicleId ?? this.vehicleId,
        location: location ?? this.location,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'full_name': fullName,
        'phone': phone,
        'photo_url': photoUrl,
        'rating': rating,
        'trip_count': tripCount,
        'kyc_status': kyc.name,
        'availability': availability.name,
        'vehicle_id': vehicleId,
        if (location != null) 'lat': location!.lat,
        if (location != null) 'lng': location!.lng,
      };
}
