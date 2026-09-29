import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_driver/src/onboarding/kyc_controller.dart';
import 'package:mng_core/mng_core.dart';

import '../support/fakes.dart';

/// Coming back to the app half-way through verification.
///
/// Found on a device: force-closing the driver app sent the driver back to the
/// identity step, and every step already completed looked as though it had
/// never been. The step was only ever held in memory, while [advance] had been
/// writing each one to the server precisely so that a driver who lost their
/// connection would not have to start again.
void main() {
  DriverProfile profileWith(
    KycStatus kyc, {
    String fullName = 'Jane Cooper',
    String? vehicleId,
    String photoUrl = '',
  }) =>
      DriverProfile(
        id: 'd1',
        fullName: fullName,
        phone: '',
        photoUrl: photoUrl,
        rating: 5.0,
        tripCount: 0,
        kyc: kyc,
        availability: DriverAvailability.offline,
        vehicleId: vehicleId,
      );

  Vehicle aVehicle() => const Vehicle(
        id: 'v1',
        ownerId: 'd1',
        category: VehicleCategory.sedan,
        make: 'Toyota',
        model: 'Corolla',
        plate: 'GR-1234-21',
        seats: 4,
        photoUrl: '',
        rideCategory: RideCategory.standard,
      );

  /// A controller that has never moved, as a fresh app launch leaves it.
  KycController fresh(
    StubDriverRepository repo,
  ) =>
      KycController(repo);

  group('a driver who has not started', () {
    test('lands on the identity step', () async {
      final repo = StubDriverRepository(
        profile: profileWith(KycStatus.notStarted),
      );
      final c = fresh(repo);

      await c.resumeFromServer();

      expect(c.step, KycStep.identity);
    });

    test('is not asked for a vehicle it cannot have', () async {
      // A round trip to the server for an answer that is certainly "no" is a
      // cold start that waits for nothing.
      final repo = StubDriverRepository(
        profile: profileWith(KycStatus.notStarted),
      );

      await fresh(repo).resumeFromServer();

      expect(repo.myVehicleCalls, 0);
    });
  });

  group('a driver who has sent their Ghana Card', () {
    // `pending` is written by `submitGhanaCard`, so it means the card is in and
    // the selfie is next -- unless they got further than that.

    test('resumes at the selfie, not the beginning', () async {
      final repo = StubDriverRepository(profile: profileWith(KycStatus.pending));
      final c = fresh(repo);

      await c.resumeFromServer();

      expect(c.step, KycStep.selfie);
    });

    test('and keeps the name the card step already saved', () async {
      // Their name went to the server with the card. Asking for it again is
      // asking a driver to re-type something that is already correct.
      final repo = StubDriverRepository(profile: profileWith(KycStatus.pending));
      final c = fresh(repo);

      await c.resumeFromServer();

      expect(c.fullName, 'Jane Cooper');
    });

    test('a driver with a vehicle saved resumes at review', () async {
      // The card is in, the selfie was sent, the vehicle is saved: there is
      // nothing left to enter, only to submit and wait.
      final repo = StubDriverRepository(
        profile: profileWith(KycStatus.pending, vehicleId: 'v1'),
        vehicle: aVehicle(),
      );
      final c = fresh(repo);

      await c.resumeFromServer();

      expect(c.step, KycStep.review);
    });

    test('a resumed review has the vehicle details filled in', () async {
      // The review step shows what was submitted. Empty fields there would tell
      // the driver their vehicle is blank when it is not.
      final repo = StubDriverRepository(
        profile: profileWith(KycStatus.pending, vehicleId: 'v1'),
        vehicle: aVehicle(),
      );
      final c = fresh(repo);

      await c.resumeFromServer();

      expect(c.vehicleMake, 'Toyota');
      expect(c.vehicleModel, 'Corolla');
      expect(c.vehiclePlate, 'GR-1234-21');
      expect(c.vehicleSeats, 4);
    });
  });

  group('an approved driver', () {
    test('lands on approved, not on a form', () async {
      final repo = StubDriverRepository(
        profile: profileWith(KycStatus.approved, vehicleId: 'v1'),
        vehicle: aVehicle(),
      );
      final c = fresh(repo);

      await c.resumeFromServer();

      expect(c.step, KycStep.approved);
    });
  });

  group('a rejected driver', () {
    test('starts again, because the card is what was refused', () async {
      // Carrying on past a refused identity check would be the wrong move: the
      // document that was rejected is the Ghana Card, so the honest retry is to
      // re-enter the name and scan a new one.
      final repo = StubDriverRepository(
        profile: profileWith(KycStatus.rejected, vehicleId: 'v1'),
        vehicle: aVehicle(),
      );
      final c = fresh(repo);

      await c.resumeFromServer();

      expect(c.step, KycStep.identity);
    });
  });

  group('when the read fails', () {
    test('nothing changes, rather than showing an error', () async {
      // A driver who cannot be read is on the first step, which is where they
      // would have been anyway. A red message about a failed read on an
      // onboarding form is worse than the form.
      final repo = StubDriverRepository()..meFails = true;
      final c = fresh(repo);

      await c.resumeFromServer();

      expect(c.step, KycStep.identity);
      expect(c.error, isNull);
    });

    test('a vehicle read that fails lands on a step that can be completed', () async {
      // Not on review, which is the step where the vehicle is assumed present.
      final repo = StubDriverRepository(
        profile: profileWith(KycStatus.pending, vehicleId: 'v1'),
      )..myVehicleFails = true;
      final c = fresh(repo);

      await c.resumeFromServer();

      expect(c.step, KycStep.selfie);
    });

    test('a driver with no profile at all is left alone', () async {
      final repo = StubDriverRepository();
      final c = fresh(repo);

      await c.resumeFromServer();

      expect(c.step, KycStep.identity);
    });
  });

  group('what it cannot bring back', () {
    // Stated as a test so the limit is written down rather than discovered.
    test('text typed into the current step and not yet submitted is gone', () async {
      // There is no local copy of it, by design: a second store of a driver's
      // identity documents on the phone is the thing to avoid. The cost is one
      // screen's worth of typing.
      final repo = StubDriverRepository(profile: profileWith(KycStatus.pending));
      final c = fresh(repo);
      c.cardNumber = 'GHA-123456789-0';
      c.cardExpiry = '12/29';

      await c.resumeFromServer();

      expect(c.cardNumber, 'GHA-123456789-0',
          reason: 'a submitted field is not cleared by resuming');
    });
  });
}
