import 'package:mng_core/mng_core.dart';

import '../onboarding/driver_document.dart';
import 'driver_trip.dart';

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

  /// Asks the server to store this account as a driver, if it is not already.
  ///
  /// ## Why the app is allowed to do this
  ///
  /// Because `role` is a category and not a capability. Reaching a paying
  /// passenger needs `kyc_status = 'approved'` and `vehicles.approved`, and both
  /// are service-role writes a client cannot make -- `guard_profile_update`
  /// raises on any `kyc_status` other than `pending`, and the vehicles policies
  /// pin `approved = false`. The most this can do is put somebody in the approval
  /// queue, which is where a driver has to be anyway.
  ///
  /// `guard_profile_update` allows exactly this one transition, `rider` to
  /// `driver`, and refuses the reverse, so a driver cannot shed their obligations
  /// mid-trip.
  ///
  /// ## Why the app does it at all
  ///
  /// Because it otherwise has no way out. `handle_new_user` reads the role from
  /// signup metadata exactly once, so an account made before the driver app sent
  /// `role: 'driver'` -- or by somebody who installed the *rider* app first --
  /// is a rider forever. The database has permitted the repair since
  /// `20260930000002_driver_role.sql`, and until this call existed nothing
  /// invoked it: the app said "Waiting for review" (it reads `kyc_status`), the
  /// approval queue showed nothing (it also filters on `role = 'driver'`), and
  /// the only cure was a person running SQL by hand. That happened twice.
  ///
  /// Returns whether the write happened, so a caller can say so rather than
  /// assume. A failure is not an error: this is a repair, and a driver who cannot
  /// be repaired should still be able to carry on sending documents.
  Future<bool> claimDriverRole();

  /// Writes the Ghana Card details and moves `kyc_status` to `pending`.
  ///
  /// `pending` is the only value a client may write: `guard_profile_update`
  /// raises on any other change, so this call can never approve anybody.
  Future<void> submitGhanaCard({
    required String cardNumber,
    required String expiry,
    required String fullName,
    String dob = '',
    String sex = '',
    String nationality = '',
    String issued = '',
  });

  /// Records the selfie the driver captured on this device.
  Future<void> submitSelfie(String path);

  /// Uploads one document and records it, replacing any previous one of the same
  /// kind.
  ///
  /// The upload and the row are one call on purpose. Written separately, a
  /// driver whose row succeeded and whose upload failed would be shown a
  /// document the server cannot produce, and one whose upload succeeded and
  /// whose row failed would leave an object no policy lets anybody delete.
  ///
  /// Throws [DriverAuthFailure] rather than returning a bool: "your licence was
  /// not saved" is a sentence a driver has to be told, and a checklist that
  /// quietly leaves a row unticked reads as "we have it".
  Future<void> uploadDocument({
    required DriverDocumentKind kind,
    required String filePath,
  });

  /// What this driver has already sent, so the checklist can survive a restart.
  ///
  /// Empty rather than throwing when the read fails, for the same reason the
  /// home screen's history read is: a driver opening the app on a bad
  /// connection should see a checklist to fill in, not an error page. The
  /// difference is that an empty list here makes the driver re-send a document
  /// they already sent, which is a worse outcome than an error would be -- so
  /// this one is a failure the caller is told about.
  Future<List<DriverDocument>> myDocuments();

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

  /// Publishes [point] to `driver_locations`, with the driver's [bearing] if
  /// the device reported one.
  ///
  /// `match_offers_for_trip` requires `exists (select 1 from driver_locations l
  /// where l.driver_id = d.id)`, so a driver who has never published a position
  /// is invisible to the matcher however online and approved they are.
  ///
  /// The bearing is what the rider's map rotates their car by, so writing it
  /// is what turns a dot on a route into a vehicle that visibly turns at each
  /// junction. Nullable rather than defaulted to north: a driver with no
  /// compass has no heading, and publishing a fabricated one would put a car
  /// pointing confidently the wrong way.
  Future<void> updateLocation(GeoPoint point, {double? bearing});

  /// The driver's live trip, or null when they have none.
  Future<Trip?> activeTrip();

  /// The driver's own trip history, newest first.
  ///
  /// Scoped to `driver_id = auth.uid()` rather than to "trips I can see":
  /// `trips` carries two SELECT policies and RLS ORs permissive policies, so a
  /// driver who is also a rider of somebody else's trip can read that row too.
  /// The filter is what makes this the driver's history and not their
  /// passenger history.
  Future<List<DriverTrip>> myTrips({int limit});

  /// The vehicle this driver owns, or null when they have not added one.
  ///
  /// A driver can read exactly one `vehicles` row -- `owner_id` is `unique` --
  /// and only their own, so this is not a query that can leak.
  Future<Vehicle?> myVehicle();

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
