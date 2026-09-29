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

  /// Where the driver assigned to this trip is, or null when there is none to
  /// show.
  ///
  /// Reads `driver_locations` for [driverId]. The database already permits
  /// exactly this and nothing more: the policy `rider reads driver location
  /// while assigned` allows the read only when a trip whose `rider_id` is
  /// `auth.uid()` names that driver and is in `matched`, `arriving` or
  /// `ongoing`. So before a driver is assigned, and after the trip ends, this
  /// returns null by policy rather than by a check here -- which is the right
  /// place for the rule, because a client-side check is a thing that can be
  /// forgotten and a policy cannot.
  /// Where the driver on this trip is, and which way they are facing.
  ///
  /// A [VehicleFix] and not a [GeoPoint], because the map draws the driver as
  /// a car pointed the way they are driving. A coordinate cannot say which way
  /// that is, and a car that always points north is a decoration rather than a
  /// vehicle.
  ///
  /// Null when there is no driver, no published position, or the read was
  /// refused by policy. All three are answers rather than faults.
  Future<VehicleFix?> assignedDriverLocation(String? driverId);

  Future<void> raiseSos(String tripId, String note);
}
