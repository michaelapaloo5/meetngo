import 'package:mng_core/mng_core.dart';

import 'booked_trip.dart';
import 'location_service.dart';

class TripRequestFailure implements Exception {
  const TripRequestFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The driver's own details, as far as a rider is entitled to them.
///
/// Deliberately a distinct type from the driver's `Contact` rather than a shared
/// one: the two sides of a trip need different fields and, more importantly,
/// different *failures*. A rider asking about a driver wants to know the car is
/// coming and who is driving it. Anything less than a name, a car and a plate
/// is a number they cannot use.
class DriverContact {
  const DriverContact({
    required this.name,
    required this.phone,
    required this.callable,
    required this.carMake,
    required this.carModel,
    required this.plate,
    required this.photoUrl,
    this.rating,
  });

  /// What to show when the lookup could not be completed.
  ///
  /// A screen with nothing is a broken screen; a screen that says "we could not
  /// get your driver's details, try again" is a working one.
  const DriverContact.unavailable()
    : name = '',
      phone = '',
      callable = false,
      carMake = '',
      carModel = '',
      plate = '',
      photoUrl = '',
      rating = null;

  final String name;
  final String phone;

  /// Whether [phone] is one this app is willing to put into a dialler.
  ///
  /// Not `phone.isNotEmpty`. A number that is present and malformed is not
  /// callable, and the server cannot know whether it is a Ghanaian one, so the
  /// check happens here where `isCallableGhanaPhone` lives -- the same rule the
  /// driver app applies to the rider.
  final bool callable;

  final String carMake;
  final String carModel;

  /// The number plate, which is the thing a rider actually looks for at a rank.
  final String plate;

  /// The driver's profile picture, or empty for none.
  final String photoUrl;

  final double? rating;

  /// "Toyota Corolla", or empty when the vehicle is not known.
  String get car => [carMake, carModel].where((s) => s.isNotEmpty).join(' ');

  /// Whether there is enough here to put a card on screen.
  bool get hasCar => plate.isNotEmpty || car.isNotEmpty;
}

abstract class TripRepository {
  Future<Trip?> activeTrip();
  Stream<Trip> watchTrip(String tripId);

  /// How the rider can reach the driver assigned to [tripId].
  ///
  /// The `contact` Edge Function answers both directions -- a driver asking
  /// about their rider and a rider asking about their driver -- and the rider
  /// direction was built and deployed but **never called from this app**. Both
  /// tracking buttons were `onPressed: () {}` while this went unused, which is
  /// the exact pair of facts that let that ship.
  Future<DriverContact> driverContact(String tripId);

  /// The rider's own trips, newest first, filtered.
  ///
  /// Every filter is nullable and they combine with AND, so a rider can ask for
  /// "completed rides from this month" without the controller composing a filter
  /// string. The composition happens here, in Dart, where it can be tested --
  /// rather than in a PostgREST `.or()` that the rider's own typed text reaches.
  ///
  /// [states] is a **set** rather than a single state because "Live" covers
  /// several: a rider whose car is `arriving` must be able to find that ride.
  /// Passing more than one asks PostgREST for `state=in.(...)` rather than for
  /// any state at all -- the empty set is not "everything", because `in.()` with
  /// no members is a syntax error rather than a match-all, so the UI must send
  /// null for "no filter".
  ///
  /// [search] matches the two place names, case-insensitively. It is escaped
  /// before it reaches the query: an unescaped `%` or `,` in a search box would
  /// otherwise change what the query means, and a rider typing "Accra, Kumasi"
  /// would get a syntax error rather than an empty list.
  Future<List<BookedTrip>> history({
    int limit = 50,
    Set<TripState>? states,
    DateTime? since,
    String? search,
  });

  /// Asks for a ride on this route, now or later.
  ///
  /// [scheduledFor] books it for a time instead of immediately. Null means now,
  /// which is the ordinary case and the only one that fans offers out to
  /// drivers -- a scheduled trip is not offerable until its time, which the
  /// database decides in `trips_is_offerable()` rather than being a separate trip
  /// state.
  ///
  /// There is no `promoCode`. RIDE30 was withdrawn rather than reduced, and this
  /// parameter outlived it: a repository that still accepts a promo code is a
  /// repository whose caller can believe the discount exists.
  Future<Trip> requestRide({
    required TripStop pickup,
    required TripStop dropoff,
    required RideCategory category,
    DateTime? scheduledFor,
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
