import 'category.dart';

enum VehicleCategory { sedan, suv, van, luxury }

class Vehicle {
  const Vehicle({
    required this.id,
    required this.ownerId,
    required this.category,
    required this.make,
    required this.model,
    required this.plate,
    required this.seats,
    required this.photoUrl,
    required this.rideCategory,
  });

  factory Vehicle.fromJson(Map<String, dynamic> json) => Vehicle(
        id: json['id'] as String,
        ownerId: json['owner_id'] as String,
        category:
            VehicleCategory.values.byName(json['vehicle_category'] as String),
        make: json['make'] as String,
        model: json['model'] as String,
        plate: json['plate'] as String,
        seats: (json['seats'] as num).toInt(),
        photoUrl: (json['photo_url'] as String?) ?? '',
        rideCategory: RideCategory.values.byName(json['ride_category'] as String),
      );

  final String id;
  final String ownerId;
  final VehicleCategory category;
  final String make;
  final String model;
  final String plate;
  final int seats;
  final String photoUrl;
  final RideCategory rideCategory;

  String get displayName => '$make $model';

  Map<String, dynamic> toJson() => {
        'id': id,
        'owner_id': ownerId,
        'vehicle_category': category.name,
        'make': make,
        'model': model,
        'plate': plate,
        'seats': seats,
        'photo_url': photoUrl,
        'ride_category': rideCategory.name,
      };
}
