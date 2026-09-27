import 'package:mng_core/mng_core.dart';

class TripRequestFailure implements Exception {
  const TripRequestFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class TripRepository {
  Future<Trip?> activeTrip();
  Stream<Trip> watchTrip(String tripId);
  Future<Trip> requestRide({
    required TripStop pickup,
    required TripStop dropoff,
    required RideCategory category,
    String? promoCode,
  });
  Future<void> cancelTrip(String tripId);
  Future<GeoPoint?> currentLocation();
  Future<void> raiseSos(String tripId, String note);
}
