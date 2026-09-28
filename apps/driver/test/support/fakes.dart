import 'package:mng_core/mng_core.dart';
import 'package:meetngo_driver/src/data/driver_auth_repository.dart';
import 'package:meetngo_driver/src/data/driver_repository.dart';
import 'package:meetngo_driver/src/earnings/earnings_repository.dart';

/// A driver repository that records what it was asked and answers from memory.
///
/// Every method the driver app can call is here, because a test fake that
/// implements only the methods its own test touches stops compiling the moment
/// the interface grows -- which is a cheap way to be reminded, and a
/// misleading way to learn: a fake that did not implement `activeTrip` would
/// have failed to compile rather than quietly returned null and made every
/// "going offline is refused" test pass for the wrong reason.
class StubDriverRepository implements DriverRepository {
  StubDriverRepository({this.profile});

  DriverProfile? profile;

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

  bool otpPasses = true;
  bool availabilityFails = false;
  bool acceptLoses = false;
  bool declineSucceeds = true;
  bool activeTripFails = false;
  bool meFails = false;
  bool locationAvailable = true;

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
  }) async {
    this.cardNumber = cardNumber;
    cardExpiry = expiry;
    cardName = fullName;
  }

  @override
  Future<void> submitSelfie(String path) async => selfiePath = path;

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
  Future<void> updateLocation(GeoPoint point) async {
    updateLocationCalls++;
    lastLocation = point;
  }

  @override
  Future<Trip?> activeTrip() async {
    if (activeTripFails) {
      throw const DriverAuthFailure('could not read your trip');
    }
    return active;
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

  @override
  Future<void> signInWithPassword(String email, String password) async {
    lastEmail = email;
    lastPassword = password;
    if (failWith != null) throw DriverAuthFailure(failWith!);
  }

  @override
  Future<void> signInWithGoogle() async {
    googlePressed = true;
    if (failWith != null) throw DriverAuthFailure(failWith!);
  }
}
