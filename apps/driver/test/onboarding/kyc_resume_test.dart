import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_driver/src/onboarding/driver_document.dart';
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
  }) => DriverProfile(
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
  KycController fresh(StubDriverRepository repo) => KycController(repo);

  /// A repository that already holds all six documents.
  ///
  /// The six documents outrank every other step for an unapproved driver, so a
  /// test whose subject is a *later* step has to hand it a driver who has got
  /// past that gate. Without this the tests would all collapse onto
  /// `KycStep.documents` and stop testing what they were written for, which is
  /// a green suite that stopped meaning anything.
  StubDriverRepository sentAllSix(DriverProfile? profile, {Vehicle? vehicle}) =>
      StubDriverRepository(profile: profile, vehicle: vehicle)
        ..documents = [
          for (final kind in driverDocumentKinds)
            DriverDocument(
              kind: kind,
              path: 'u1/${kind.wire}/1.jpg',
              createdAt: DateTime.utc(2026, 9, 28),
            ),
        ];

  group('a driver who has not started', () {
    test(
      'lands on the document list, which is where a new driver starts',
      () async {
        final repo = StubDriverRepository(
          profile: profileWith(KycStatus.notStarted),
        );
        final c = fresh(repo);

        await c.resumeFromServer();

        expect(c.step, KycStep.documents);
      },
    );

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
      final repo = sentAllSix(profileWith(KycStatus.pending));
      final c = fresh(repo);

      await c.resumeFromServer();

      expect(c.step, KycStep.selfie);
    });

    test('and keeps the name the card step already saved', () async {
      // Their name went to the server with the card. Asking for it again is
      // asking a driver to re-type something that is already correct.
      final repo = sentAllSix(profileWith(KycStatus.pending));
      final c = fresh(repo);

      await c.resumeFromServer();

      expect(c.fullName, 'Jane Cooper');
    });

    test('a driver with a vehicle saved resumes as sent for review', () async {
      // The card is in, the selfie was sent, the vehicle is saved: there is
      // nothing left to enter, only to wait.
      //
      // This asserted `KycStep.review`, and it was pinning the bug rather than
      // the behaviour. `submit()` writes nothing to the server -- it checks the
      // six documents, re-reads the profile and sets the step in memory -- so
      // `underReview` could only ever be reached by pressing the button, and
      // never by reopening the app. A driver who had submitted, quit, and came
      // back was told "Submit for review" on every launch, which is how this was
      // found: reported as the app forgetting that it had been used.
      final repo = sentAllSix(
        profileWith(KycStatus.pending, vehicleId: 'v1'),
        vehicle: aVehicle(),
      );
      final c = fresh(repo);

      await c.resumeFromServer();

      expect(c.step, KycStep.underReview);
    });

    test('resuming twice does not move a submitted driver backwards', () async {
      // The same question asked twice, because the second launch is the one that
      // used to fail: a driver who opens the app, it resumes, and then something
      // re-reads. Nothing should drag them back to a form they have finished.
      final repo = sentAllSix(
        profileWith(KycStatus.pending, vehicleId: 'v1'),
        vehicle: aVehicle(),
      );
      final c = fresh(repo);

      await c.resumeFromServer();
      expect(c.step, KycStep.underReview);
      await c.resumeFromServer();
      expect(c.step, KycStep.underReview);
    });

    test('a submitted driver can still be told they were approved', () async {
      // `checkStatus` is the only thing available on this step, and it returns
      // immediately unless the step is `underReview`. If a resume could not
      // reach it, the driver would be stuck on the hourglass with a button that
      // does nothing -- so the poll has to work from a resumed state, not only
      // from one reached by pressing submit.
      final repo = sentAllSix(
        profileWith(KycStatus.approved, vehicleId: 'v1'),
        vehicle: aVehicle(),
      );
      final c = fresh(repo);

      await c.resumeFromServer();
      await c.checkStatus();

      expect(c.step, KycStep.approved);
    });

    test('a driver stored as a rider claims the role on resume', () async {
      // The bug that was reported twice, and it is worth being precise about the
      // shape of it: the app said "Waiting for review" and the approval queue
      // showed nothing, with no error anywhere.
      //
      // `handle_new_user` reads the role from signup metadata exactly once, so an
      // account made before the driver app sent `role: 'driver'` -- or by
      // somebody who installed the rider app first -- is a rider forever. The app
      // reads `kyc_status` and so says waiting; the queue filters on `role` as
      // well and so does not list them. The only cure was a person running SQL.
      final repo = sentAllSix(
        profileWith(KycStatus.approved, vehicleId: 'v1'),
        vehicle: aVehicle(),
      );
      // The one thing that makes this a rider rather than a driver. The model
      // defaults to `rider`, which is why a fixture that does not say otherwise
      // is one -- and that default is itself worth knowing about.
      expect(repo.profile?.isDriver, isFalse, reason: 'the fixture is a rider');
      final c = KycController(repo);

      await c.resumeFromServer();

      expect(repo.driverRoleClaims, 1, reason: 'the rider should have claimed');
    });

    test('a driver already stored as a driver does not claim', () async {
      // Claiming is safe to do every launch precisely because the write is
      // conditional on the role being `rider`, so this is a no-op rather than an
      // error -- and the app must not spend a write on every cold start.
      final repo = sentAllSix(
        profileWith(KycStatus.approved, vehicleId: 'v1'),
        vehicle: aVehicle(),
      );
      repo.profile = repo.profile?.copyWith(role: 'driver');
      final c = KycController(repo);

      await c.resumeFromServer();

      expect(repo.driverRoleClaims, 0);
    });

    test('a failed claim does not stop the driver carrying on', () async {
      // The claim is a repair, not a step. If it throws and the resume gives up,
      // a driver is stuck behind an error with no way past it -- and the thing
      // being repaired is only a queue listing, not their ability to work.
      final repo = sentAllSix(
        profileWith(KycStatus.pending, vehicleId: 'v1'),
        vehicle: aVehicle(),
      )..driverRoleClaimFails = true;
      final c = KycController(repo);

      await c.resumeFromServer();

      expect(c.step, KycStep.underReview, reason: 'onboarding still resolved');
      expect(c.error, isNull, reason: 'and nothing was said to the driver');
    });

    test('a resumed review has the vehicle details filled in', () async {
      // The review step shows what was submitted. Empty fields there would tell
      // the driver their vehicle is blank when it is not.
      final repo = sentAllSix(
        profileWith(KycStatus.pending, vehicleId: 'v1'),
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
      final repo = sentAllSix(
        profileWith(KycStatus.approved, vehicleId: 'v1'),
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
      final repo = sentAllSix(
        profileWith(KycStatus.rejected, vehicleId: 'v1'),
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

      // Wherever it lands, it lands on the first step and says nothing: a
      // driver who cannot be read is in the position they would have been in
      // anyway, and a red message on an onboarding form is worse than the form.
      expect(c.step, KycStep.documents);
      expect(c.error, isNull);
    });

    test('a vehicle read that fails lands on a step that can be completed', () async {
      // Not on review, which is the step where the vehicle is assumed present.
      final repo = sentAllSix(profileWith(KycStatus.pending, vehicleId: 'v1'))
        ..myVehicleFails = true;
      final c = fresh(repo);

      await c.resumeFromServer();

      expect(c.step, KycStep.selfie);
    });

    test('a driver with no profile at all is left alone', () async {
      final repo = StubDriverRepository();
      final c = fresh(repo);

      await c.resumeFromServer();

      // `null` profile means "carry on from wherever this controller already is",
      // which for a fresh launch is the document list. The point is that a
      // missing profile is not a crash and not a redirect somewhere odd.
      expect(c.step, KycStep.documents);
    });
  });

  group('the documents survive a restart too', () {
    test('a driver who has sent some sends only the rest', () async {
      // The same bug as the step, one level down: a licence photographed
      // yesterday and a force-close overnight should not mean photographing it
      // again today.
      final repo =
          StubDriverRepository(profile: profileWith(KycStatus.notStarted))
            ..documents = [
              DriverDocument(
                kind: DriverDocumentKind.ghanaCardPhoto,
                path: 'u1/ghanaCardPhoto/1.jpg',
                createdAt: DateTime.utc(2026, 9, 28),
              ),
              DriverDocument(
                kind: DriverDocumentKind.insuranceSticker,
                path: 'u1/insuranceSticker/1.jpg',
                createdAt: DateTime.utc(2026, 9, 28),
              ),
            ];
      final c = fresh(repo);

      await c.resumeFromServer();

      expect(c.documents, hasLength(2));
      expect(c.canAdvance, isFalse, reason: 'four documents are still missing');
    });

    test('a driver who has sent all six can move on', () async {
      final repo =
          StubDriverRepository(profile: profileWith(KycStatus.notStarted))
            ..documents = [
              for (final kind in driverDocumentKinds)
                DriverDocument(
                  kind: kind,
                  path: 'u1/${kind.wire}/1.jpg',
                  createdAt: DateTime.utc(2026, 9, 28),
                ),
            ];
      final c = fresh(repo);

      await c.resumeFromServer();

      expect(c.canAdvance, isTrue);
    });

    test('a failed document read is read as none sent, and says nothing', () async {
      // This is the one place a failed read is allowed to move the driver, and
      // it is deliberate. The documents gate an approval, so a read that fails
      // must not be treated as "all six are in" -- the two mistakes cost very
      // differently. Wrong this way asks a driver to re-send a licence they
      // already sent. Wrong the other way puts an application in front of an
      // admin who has nothing to look at.
      final repo = StubDriverRepository(
        profile: profileWith(KycStatus.pending, vehicleId: 'v1'),
        vehicle: aVehicle(),
      )..myDocumentsFails = true;
      final c = fresh(repo);

      await c.resumeFromServer();

      expect(c.documents, isEmpty);
      expect(c.step, KycStep.documents);
      expect(
        c.error,
        isNull,
        reason: 'a failed read is not the driver anything to act on',
      );
    });
  });

  group('the documents gate an approval, not just the first step', () {
    // Found on a device: a driver who signed up before the documents existed
    // resumed at review with a saved vehicle and nothing else, and the button
    // under it said Submit for review. That application reaches a human with no
    // licence, no road worthy and no insurance to look at.
    test(
      'a driver with a card and a vehicle but no documents goes to the list',
      () async {
        final repo = StubDriverRepository(
          profile: profileWith(KycStatus.pending, vehicleId: 'v1'),
          vehicle: aVehicle(),
        );
        final c = fresh(repo);

        await c.resumeFromServer();

        expect(c.step, KycStep.documents);
      },
    );

    test(
      'four of the six is the list, not a review they cannot finish',
      () async {
        final repo =
            StubDriverRepository(
                profile: profileWith(KycStatus.pending, vehicleId: 'v1'),
                vehicle: aVehicle(),
              )
              ..documents = [
                for (final kind in driverDocumentKinds.take(4))
                  DriverDocument(
                    kind: kind,
                    path: 'u1/${kind.wire}/1.jpg',
                    createdAt: DateTime.utc(2026, 9, 28),
                  ),
              ];
        final c = fresh(repo);

        await c.resumeFromServer();

        expect(c.step, KycStep.documents);
        expect(c.canAdvance, isFalse);
      },
    );

    test('an approved driver is not sent back for documents', () async {
      // The gate is on approval, not on being a driver. A driver who is already
      // approved and re-opens the app is not made to re-photograph a licence
      // because the server was slow for a second.
      final repo = sentAllSix(
        profileWith(KycStatus.approved, vehicleId: 'v1'),
        vehicle: aVehicle(),
      );
      final c = fresh(repo);

      await c.resumeFromServer();

      expect(c.step, KycStep.approved);
    });
  });

  group('submitting for review', () {
    test('is refused with no documents, and says where to go', () async {
      final repo = StubDriverRepository(
        profile: profileWith(KycStatus.pending, vehicleId: 'v1'),
        vehicle: aVehicle(),
      );
      final c = fresh(repo)..step = KycStep.review;

      await c.submit();

      // Refused, not ignored: the driver is walked back to the list rather than
      // left pressing a button that does nothing.
      expect(c.step, KycStep.documents);
      expect(c.error, contains('documents'));
    });

    test('goes through once all six are in', () async {
      final repo = sentAllSix(
        profileWith(KycStatus.pending, vehicleId: 'v1'),
        vehicle: aVehicle(),
      );
      // Resumed first, because `submit` reads the controller's own document list
      // and that list is empty until a resume has filled it. A test that only set
      // the step would be testing a controller that had never heard of the six
      // documents.
      //
      // The resume now lands on `underReview` rather than `review`, which is the
      // fix above, so the step is set explicitly afterwards. What this test is
      // for is the press: a driver sitting on the review screen with all six
      // documents sent presses the button and lands on "Sent for review". The
      // resume behaviour has its own tests, and asserting `review` here would put
      // the old bug back in as a second pin.
      final c = fresh(repo);
      await c.resumeFromServer();
      expect(
        c.step,
        KycStep.underReview,
        reason:
            'a resume with all six documents and a vehicle is already '
            'submitted, and submit() writes nothing to the server',
      );
      c.step = KycStep.review;

      await c.submit();

      expect(c.step, KycStep.underReview);
      expect(c.error, isNull);
    });
  });

  group('what it cannot bring back', () {
    // Stated as a test so the limit is written down rather than discovered.
    test('text typed into the current step and not yet submitted is gone', () async {
      // There is no local copy of it, by design: a second store of a driver's
      // identity documents on the phone is the thing to avoid. The cost is one
      // screen's worth of typing.
      final repo = sentAllSix(profileWith(KycStatus.pending));
      final c = fresh(repo);
      c.cardNumber = 'GHA-123456789-0';
      c.cardExpiry = '12/29';

      await c.resumeFromServer();

      expect(
        c.cardNumber,
        'GHA-123456789-0',
        reason: 'a submitted field is not cleared by resuming',
      );
    });
  });
}
