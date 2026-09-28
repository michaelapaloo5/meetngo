import 'package:mng_core/mng_core.dart';

/// A failure the driver can be shown.
///
/// Every repository in this app speaks in these rather than in `PostgrestException`
/// or `AuthException`, because a controller that catches only the transport type
/// lets a `TypeError` out of a malformed row as an unhandled async error with
/// nothing on screen for the driver to read.
class DriverAuthFailure implements Exception {
  const DriverAuthFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Everything the driver app needs from the server, behind one port.
///
/// The four screens hold controllers, and the controllers hold this. Nothing
/// below this line reaches for `Supabase.instance`, so every screen is
/// drivable by a fake and nothing here is testable only against a live project.
///
/// There is no create-a-driver method on purpose. `match_offers_for_trip`
/// requires `role = 'driver'`, `kyc_status = 'approved'`, an approved vehicle,
/// `availability = 'online'` and a row in `driver_locations`
/// (`supabase/migrations/20260927000001_init.sql:match_offers_for_trip`), and
/// `role`, `kyc_status` and `vehicles.approved` are all refused to a client --
/// `guard_profile_update` raises on any `kyc_status` other than `pending`, and
/// the vehicles policies pin `approved = false`. A driver is made by an admin
/// through SQL, and this app builds against a driver that already exists.
abstract class DriverRepository {
  /// The signed-in driver's own profile row, or null when there is none.
  ///
  /// A signed-in user with no `profiles` row is a real state, not a failure:
  /// `handle_new_user` creates the row, but a user created by hand through the
  /// auth admin does not have one.
  Future<DriverProfile?> me();

  /// Live updates to the same row [me] reads.
  Stream<DriverProfile> watchMe();

  /// Writes the Ghana Card details and moves `kyc_status` to `pending`.
  ///
  /// `pending` is the only value a client may write: `guard_profile_update`
  /// raises on any other change, so this call can never approve anybody.
  Future<void> submitGhanaCard({
    required String cardNumber,
    required String expiry,
    required String fullName,
  });

  /// Records the selfie the driver captured on this device.
  Future<void> submitSelfie(String path);

  /// Creates or replaces the one vehicle this driver owns.
  Future<void> saveVehicle({
    required String make,
    required String model,
    required String plate,
    required int seats,
    required RideCategory rideCategory,
  });

  Future<void> setAvailability(DriverAvailability value);

  /// The driver's current position, or null when location is unavailable.
  Future<GeoPoint?> currentLocation();

  /// Publishes [point] to `driver_locations`.
  ///
  /// `match_offers_for_trip` requires `exists (select 1 from driver_locations l
  /// where l.driver_id = d.id)`, so a driver who has never published a position
  /// is invisible to the matcher however online and approved they are.
  Future<void> updateLocation(GeoPoint point);

  /// The driver's live trip, or null when they have none.
  Future<Trip?> activeTrip();

  /// Pending offers addressed to this driver.
  Stream<Offer> watchOffers();

  Future<void> acceptOffer(String offerId);

  Future<void> declineOffer(String offerId);

  /// Moves [tripId] to [to], or throws [DriverAuthFailure].
  ///
  /// The database refuses an illegal move in `enforce_trip_transition`, so a
  /// failure here is the transition rule answering and not a network fault.
  Future<void> advanceTripState(String tripId, TripState to);

  /// Throws [DriverAuthFailure] unless [code] is the rider's pickup code.
  Future<void> verifyPickupOtp(String tripId, String code);
}
