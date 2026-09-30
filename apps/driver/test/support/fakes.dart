import 'package:geolocator/geolocator.dart';
import 'package:mng_core/mng_core.dart';
import 'package:meetngo_driver/src/data/driver_auth_repository.dart';
import 'package:meetngo_driver/src/data/driver_repository.dart';
import 'package:meetngo_driver/src/data/driver_trip.dart';
import 'package:meetngo_driver/src/earnings/earnings_repository.dart';
import 'package:meetngo_driver/src/location/location_reader.dart';
import 'package:meetngo_driver/src/onboarding/driver_document.dart';

/// A driver repository that records what it was asked and answers from memory.
///
/// Every method the driver app can call is here, because a test fake that
/// implements only the methods its own test touches stops compiling the moment
/// the interface grows -- which is a cheap way to be reminded, and a
/// misleading way to learn: a fake that did not implement `activeTrip` would
/// have failed to compile rather than quietly returned null and made every
/// "going offline is refused" test pass for the wrong reason.
class StubDriverRepository implements DriverRepository {
  StubDriverRepository({this.profile, this.trips = const [], this.vehicle});

  DriverProfile? profile;

  /// The history [myTrips] answers with. Mutable so a test can swap it between
  /// a load and a refresh and prove the list is not cached.
  List<DriverTrip> trips;

  Vehicle? vehicle;

  String? cardNumber;
  String? cardExpiry;
  String? cardName;
  String? selfiePath;
  Vehicle? savedVehicle;
  RideCategory? savedRideCategory;
  DriverAvailability? availability;
  Trip? active;
  GeoPoint? lastLocation;
  final List<String> acceptedOfferIds = [];
  final List<String> declinedOfferIds = [];
  final List<String> moves = [];

  int setAvailabilityCalls = 0;
  int updateLocationCalls = 0;
  int otpAttempts = 0;
  int meCalls = 0;
  int currentLocationCalls = 0;

  /// Whether [updateLocation] should fail, for the publish-failure path.
  ///
  /// The write to `driver_locations` can be refused by RLS or by a dropped
  /// connection while the position read succeeded, and the controller has to
  /// keep the position in that case.
  bool locationWriteFails = false;
  int myTripsCalls = 0;
  int myVehicleCalls = 0;

  bool otpPasses = true;
  bool availabilityFails = false;
  bool acceptLoses = false;
  bool declineSucceeds = true;
  bool activeTripFails = false;
  bool meFails = false;
  bool locationAvailable = true;
  bool myTripsFails = false;
  bool myVehicleFails = false;

  @override
  Future<DriverProfile?> me() async {
    meCalls++;
    if (meFails) throw const DriverAuthFailure('profile read failed');
    return profile;
  }

  @override
  Stream<DriverProfile> watchMe() {
    // Answers the same question [me] does, including its refusal. A fake whose
    // watch and whose read disagree is a fake that can hide a gate: a real
    // `SupabaseStreamBuilder` only ever carries a row the server sent, so one
    // that seeds itself from a local field can hand a caller a profile that
    // [me] would have thrown rather than returned -- which is exactly how a
    // failed profile read got overwritten by a watch event and a driver nobody
    // had read reached the offer queue.
    if (meFails) {
      return Stream<DriverProfile>.error(
        const DriverAuthFailure('profile read failed'),
      );
    }
    final current = profile;
    return current == null
        ? const Stream<DriverProfile>.empty()
        : Stream<DriverProfile>.value(current);
  }

  @override
  Future<void> submitGhanaCard({
    required String cardNumber,
    required String expiry,
    required String fullName,
    String dob = '',
    String sex = '',
    String nationality = '',
    String issued = '',
  }) async {
    this.cardNumber = cardNumber;
    cardExpiry = expiry;
    cardName = fullName;
    cardDob = dob;
    cardSex = sex;
    cardNationality = nationality;
    cardIssued = issued;
  }

  /// The card fields the fake was last sent, so a test can assert the write
  /// carried them rather than only that it did not fail.
  String cardDob = '';
  String cardSex = '';
  String cardNationality = '';
  String cardIssued = '';

  @override
  Future<void> submitSelfie(String path) async => selfiePath = path;

  /// The documents the fake repository is answering with, and what it was sent.
  List<DriverDocument> documents = const [];
  final List<DriverDocumentKind> uploaded = [];

  /// Set to refuse an upload, for the "that photo could not be saved" path.
  bool uploadFails = false;

  /// Set to refuse the document read, for the "the step survives a failed
  /// document read" path.
  bool myDocumentsFails = false;

  @override
  Future<void> uploadDocument({
    required DriverDocumentKind kind,
    required String filePath,
  }) async {
    if (uploadFails) {
      throw const DriverAuthFailure('That photo could not be saved');
    }
    uploaded.add(kind);
    documents = [
      ...documents.where((d) => d.kind != kind),
      DriverDocument(kind: kind, path: filePath, createdAt: DateTime(2026, 9, 29)),
    ];
  }

  @override
  Future<List<DriverDocument>> myDocuments() async {
    if (myDocumentsFails) {
      throw const DriverAuthFailure('document read failed');
    }
    return documents;
  }

  @override
  Future<void> saveVehicle({
    required String make,
    required String model,
    required String plate,
    required int seats,
    required RideCategory rideCategory,
  }) async {
    savedVehicle = Vehicle(
      id: 'v1',
      ownerId: 'd1',
      category: seats > 4 ? VehicleCategory.van : VehicleCategory.sedan,
      make: make,
      model: model,
      plate: plate,
      seats: seats,
      photoUrl: '',
      rideCategory: rideCategory,
    );
    savedRideCategory = rideCategory;
  }

  @override
  Future<void> setAvailability(DriverAvailability value) async {
    setAvailabilityCalls++;
    if (availabilityFails) {
      throw const DriverAuthFailure('network down');
    }
    availability = value;
    profile = profile?.copyWith(availability: value);
  }

  @override
  Future<GeoPoint?> currentLocation() async {
    currentLocationCalls++;
    return locationAvailable ? const GeoPoint(5.6037, -0.1870) : null;
  }

  @override
  Future<void> updateLocation(GeoPoint point, {double? bearing}) async {
    updateLocationCalls++;
    if (locationWriteFails) {
      throw DriverAuthFailure('row level security refused the write');
    }
    lastLocation = point;
    // Recorded, and normalised the same way the real repository writes it, so a
    // test can assert on what would reach `driver_locations` rather than on
    // what the controller happened to pass in.
    lastHeading = normaliseBearing(bearing);
  }

  /// The heading of the last publish, so a test can check the rider's car would
  /// be drawn pointing the right way.
  double? lastHeading;

  @override
  Future<Trip?> activeTrip() async {
    if (activeTripFails) {
      throw const DriverAuthFailure('could not read your trip');
    }
    return active;
  }

  @override
  Future<List<DriverTrip>> myTrips({int limit = 50}) async {
    myTripsCalls++;
    if (myTripsFails) {
      throw const DriverAuthFailure('could not read your trips');
    }
    return trips;
  }

  @override
  Future<Vehicle?> myVehicle() async {
    myVehicleCalls++;
    if (myVehicleFails) throw const DriverAuthFailure('could not read your car');
    return vehicle;
  }

  @override
  Stream<Offer> watchOffers() => const Stream<Offer>.empty();

  @override
  Future<void> acceptOffer(String offerId) async {
    if (acceptLoses) {
      throw const DriverAuthFailure('That trip was taken by another driver');
    }
    acceptedOfferIds.add(offerId);
  }

  @override
  Future<void> declineOffer(String offerId) async {
    if (!declineSucceeds) {
      throw const DriverAuthFailure('That offer is no longer pending');
    }
    declinedOfferIds.add(offerId);
  }

  @override
  Future<void> advanceTripState(String tripId, TripState to) async {
    moves.add('$tripId->${to.name}');
  }

  @override
  Future<void> verifyPickupOtp(String tripId, String code) async {
    otpAttempts++;
    if (!otpPasses) throw const DriverAuthFailure('That code is not right');
  }
}

class StubEarningsRepository implements EarningsRepository {
  List<LedgerEntry> rows = [];
  final List<double> payouts = [];
  bool failPayout = false;
  bool failLedger = false;

  @override
  Future<List<LedgerEntry>> ledger() async {
    if (failLedger) throw const PayoutFailure('Could not read your ledger');
    return rows;
  }

  @override
  Future<void> requestPayout({required double amountGhs}) async {
    if (failPayout) throw const PayoutFailure('Payouts are paused right now');
    payouts.add(amountGhs);
  }
}

class StubDriverAuthRepository implements DriverAuthRepository {
  String? lastEmail;
  String? lastPassword;
  bool googlePressed = false;
  String? failWith;

  /// What [signUp] was asked for, so a test can prove the name reached the
  /// repository rather than being validated and dropped on the way.
  String? signUpEmail;
  String? signUpPassword;
  String? signUpName;
  int signUpCalls = 0;

  /// Answer "there is no session" the way a project with email confirmation on
  /// does, so the screen's handling of that case is drivable.
  bool signUpReturnsNoSession = false;

  bool signedOut = false;
  String? failSignOutWith;

  /// What [currentEmail] answers. Null by default, which is the signed-out
  /// case: the Profile tab omits its email row rather than rendering a blank,
  /// so a test that wants the row has to say the account has an address.
  String? email;

  @override
  String? get currentEmail => email;

  @override
  Future<void> signInWithPassword(String email, String password) async {
    lastEmail = email;
    lastPassword = password;
    if (failWith != null) throw DriverAuthFailure(failWith!);
  }

  @override
  Future<void> signUp(String email, String password, String fullName) async {
    signUpCalls++;
    signUpEmail = email;
    signUpPassword = password;
    signUpName = fullName;
    if (failWith != null) throw DriverAuthFailure(failWith!);
    if (signUpReturnsNoSession) {
      // The repository's own copy of this rule is in
      // `SupabaseDriverAuthRepository.signUp`; the fake throws the same
      // sentence rather than a bespoke one, so a test asserting on the text
      // holds against both.
      throw const DriverAuthFailure(
        'Account created. Confirm the email we sent, then log in.',
      );
    }
  }

  @override
  Future<void> signOut() async {
    if (failSignOutWith != null) throw DriverAuthFailure(failSignOutWith!);
    signedOut = true;
  }

  @override
  Future<void> signInWithGoogle() async {
    googlePressed = true;
    if (failWith != null) throw DriverAuthFailure(failWith!);
  }
}

/// A `LocationReader` that answers from fields rather than from the operating
/// system.
///
/// `Geolocator` is a plugin: every call goes over a platform channel, and a test
/// binding has no channel to answer on, so the real reader reports a missing
/// plugin and nothing else. Every branch `LocationController` has -- service
/// off, refused, refused permanently, no fix, failed -- has to be reachable, and
/// a fake is the only way to reach them.
class StubLocationReader implements LocationReader {
  StubLocationReader({
    this.serviceEnabled = true,
    this.permission = LocationPermission.whileInUse,
    this.requested = LocationPermission.whileInUse,
    this.point = const GeoPoint(5.6037, -0.1870),
    this.pointThrows,
    this.heading = 90,
    this.headingThrows,
  });

  bool serviceEnabled;
  LocationPermission permission;

  /// What [requestPermission] answers. Separate from [permission] because the
  /// case worth testing is "denied, then the driver is asked and says yes".
  LocationPermission requested;

  GeoPoint? point;

  /// Held open by [gatePoint], so a test can have two refreshes overlap.
  Future<void>? gatePoint;

  /// Thrown by [currentPoint] when the test wants a failure or a timeout.
  Object? pointThrows;

  /// Thrown by [checkPermission], for the "something else broke" path.
  Object? checkPermissionThrows;

  /// The compass reading, or null for a device with none.
  ///
  /// Defaults to 90, not null, so that an existing test about a location fix
  /// does not quietly stop publishing a heading. Tests about the no-compass
  /// case set it to null explicitly.
  double? heading;

  /// Thrown by [currentHeading]. Separate from [pointThrows] because the two
  /// are independently unavailable and the controller has to survive either.
  Object? headingThrows;

  int checkCalls = 0;
  int requestCalls = 0;
  int pointCalls = 0;
  int headingCalls = 0;

  @override
  Future<bool> isServiceEnabled() async => serviceEnabled;

  @override
  Future<LocationPermission> checkPermission() async {
    checkCalls++;
    if (checkPermissionThrows != null) throw checkPermissionThrows!;
    return permission;
  }

  @override
  Future<LocationPermission> requestPermission() async {
    requestCalls++;
    return requested;
  }

  @override
  Future<GeoPoint> currentPoint() async {
    pointCalls++;
    await gatePoint;
    if (pointThrows != null) throw pointThrows!;
    return point!;
  }

  @override
  Future<double?> currentHeading() async {
    headingCalls++;
    if (headingThrows != null) throw headingThrows!;
    return heading;
  }
}

