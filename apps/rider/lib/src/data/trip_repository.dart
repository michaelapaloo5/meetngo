import 'package:mng_core/mng_core.dart';

import 'booked_trip.dart';
import 'location_service.dart';

class TripRequestFailure implements Exception {
  const TripRequestFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class TripRepository {
  Future<Trip?> activeTrip();
  Stream<Trip> watchTrip(String tripId);

  /// The rider's own trips, newest first.
  ///
  /// Scoped to `rider_id = auth.uid()` inside the implementation rather than
  /// trusted from the caller, because `trips` carries two permissive SELECT
  /// policies (`rider reads own trips` and `driver reads assigned trips`,
  /// ORed together by RLS) and a rider who is also the assigned driver of
  /// someone else's trip would otherwise get that trip into their booking
  /// history.
  Future<List<BookedTrip>> history({int limit = 50});

  Future<Trip> requestRide({
    required TripStop pickup,
    required TripStop dropoff,
    required RideCategory category,
    String? promoCode,
  });
  Future<void> cancelTrip(String tripId);

  /// The rider's position, or null when the OS would not give one.
  ///
  /// Callers that need to tell the rider *why* there is no position, and what
  /// to do about it, use [locate] instead. This stays because it is the shape
  /// `raiseSos` wants: a point to attach or nothing, and no user-facing copy.
  Future<GeoPoint?> currentLocation();

  /// The full answer, including why there is no fix.
  Future<DeviceLocation> locate();

  Future<void> raiseSos(String tripId, String note);
}
