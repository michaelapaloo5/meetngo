import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';
import 'package:meetngo_driver/src/data/driver_repository.dart';
import 'package:meetngo_driver/src/onboarding/document_scanner_stub.dart';
import 'package:meetngo_driver/src/onboarding/kyc_controller.dart';
import 'package:meetngo_driver/src/onboarding/kyc_screen.dart';
import 'package:provider/provider.dart';

import '../support/fakes.dart';
import '../support/harness.dart';

Widget wrap(
  KycController c, {
  VoidCallback? onContinue,
  DocumentScanner? selfieScanner,
}) =>
    appHarness(
      ChangeNotifierProvider<KycController>.value(
        value: c,
        child: KycScreen(
          controller: c,
          onContinue: onContinue,
          selfieScanner: selfieScanner,
        ),
      ),
    );

const _scan = 'REPUBLIC OF GHANA\nGHA-123456789-0\nJANE COOPER\nEXP 04/29';

void main() {
  group('GhanaCardParser', () {
    test('parses a well-formed card number, expiry and name', () {
      final r = GhanaCardParser.parse(rawText: _scan);
      expect(r.cardNumber, 'GHA-123456789-0');
      expect(r.expiry, '04/29');
      expect(r.name, 'JANE COOPER');
      expect(r.error, isNull);
    });

    // The header of a Ghana Card is `REPUBLIC OF GHANA` in capitals and it is
    // the first all-capitals line in the scan. A first-match name regex returns
    // it for every card ever scanned, and the field is prefilled and looks
    // right, so the driver has a name field they must correct and never do.
    test('the card header is not offered as the name', () {
      final r = GhanaCardParser.parse(
        rawText: 'REPUBLIC OF GHANA\nGHA-123456789-0\nEXP 04/29',
      );
      expect(r.name, isNot('REPUBLIC OF GHANA'));
      expect(r.name, isNull);
    });

    test('a name on the card is found below the header', () {
      final r = GhanaCardParser.parse(
        rawText: 'GHANA\nGHA-123456789-0\nKWAME MENSAH\nEXP 04/29',
      );
      expect(r.name, 'KWAME MENSAH');
    });

    test('a card-number line is never taken as the name', () {
      final r = GhanaCardParser.parse(
        rawText: 'GHA-123456789-0\nJANE COOPER\nEXP 04/29',
      );
      expect(r.name, 'JANE COOPER');
    });

    test('a blank scan is an error, not a crash', () {
      final r = GhanaCardParser.parse(rawText: '   ');
      expect(r.error, isNotNull);
      expect(r.cardNumber, isNull);
    });

    test('reports an error when the card number is missing', () {
      final r = GhanaCardParser.parse(rawText: 'REPUBLIC OF GHANA\nEXP 04/29');
      expect(r.cardNumber, isNull);
      expect(r.error, isNotNull);
    });

    // `EXP 4-29` has no `MM/YY` in it. The plan's expiry regex was
    // `(\d{2})\/(\d{2})`, which is right; what is pinned here is that the
    // malformed form is refused rather than matched loosely.
    test('reports an error when the expiry is malformed', () {
      final r = GhanaCardParser.parse(
        rawText: 'GHA-123456789-0\nJANE COOPER\nEXP 4-29',
      );
      expect(r.expiry, isNull);
      expect(r.error, isNotNull);
    });

    test('rejects an impossible expiry month', () {
      final r = GhanaCardParser.parse(
        rawText: 'GHA-123456789-0\nJANE COOPER\nEXP 13/29',
      );
      expect(r.error, isNotNull);
      expect(r.expiry, isNull);
    });

    test('rejects a zero month', () {
      final r = GhanaCardParser.parse(
        rawText: 'GHA-123456789-0\nJANE COOPER\nEXP 00/29',
      );
      expect(r.error, isNotNull);
    });

    test('a card number that is one digit short is not a card number', () {
      final r = GhanaCardParser.parse(
        rawText: 'GHA-12345678-0\nJANE COOPER\nEXP 04/29',
      );
      expect(r.error, isNotNull);
    });

    test('spaces around the expiry slash are tolerated', () {
      final r = GhanaCardParser.parse(
        rawText: 'GHA-123456789-0\nJANE COOPER\nEXP 04 / 29',
      );
      expect(r.expiry, '04/29');
    });
  });

  group('KycController', () {
    test('starts on the identity step', () {
      final c = KycController(StubDriverRepository());
      expect(c.step, KycStep.identity);
    });

    test('cannot advance past identity with no name', () {
      final c = KycController(StubDriverRepository());
      expect(c.canAdvance, isFalse);
    });

    test('a one-letter name is not a name', () {
      final c = KycController(StubDriverRepository())..fullName = 'J';
      expect(c.canAdvance, isFalse);
    });

    test('advances once the identity name is set', () {
      final c = KycController(StubDriverRepository())..fullName = 'Jane Cooper';
      expect(c.canAdvance, isTrue);
    });

    // The plan's fields were plain public fields, so `onChanged: (v) =>
    // c.fullName = v` mutated one with no `notifyListeners` and the Continue
    // button below it -- which reads `canAdvance` -- stayed disabled for the
    // whole time the driver was typing.
    test('typing a name wakes the Continue button', () {
      final c = KycController(StubDriverRepository());
      var notifications = 0;
      c.addListener(() => notifications++);
      c.fullName = 'Jane Cooper';
      expect(notifications, 1);
      expect(c.canAdvance, isTrue);
    });

    test('card step requires a parsed card before advancing', () {
      final c = KycController(StubDriverRepository())..step = KycStep.ghanaCard;
      expect(c.canAdvance, isFalse);
      c
        ..cardNumber = 'GHA-123456789-0'
        ..cardExpiry = '04/29';
      expect(c.canAdvance, isTrue);
    });

    test('the card step wants both halves of the card', () {
      final c = KycController(StubDriverRepository())..step = KycStep.ghanaCard;
      c.cardNumber = 'GHA-123456789-0';
      expect(c.canAdvance, isFalse);
    });

    test('selfie step requires a capture', () {
      final c = KycController(StubDriverRepository())..step = KycStep.selfie;
      expect(c.canAdvance, isFalse);
      c.selfiePath = '/tmp/selfie.jpg';
      expect(c.canAdvance, isTrue);
    });

    test('vehicle step requires make, model, plate and a sane seat count', () {
      final c = KycController(StubDriverRepository())..step = KycStep.vehicle;
      expect(c.canAdvance, isFalse);
      c
        ..vehicleMake = 'Toyota'
        ..vehicleModel = 'Corolla'
        ..vehiclePlate = 'GR-1234-22'
        ..vehicleSeats = 4;
      expect(c.canAdvance, isTrue);
    });

    test('zero seats is not a vehicle', () {
      final c = KycController(StubDriverRepository())
        ..step = KycStep.vehicle
        ..vehicleMake = 'Toyota'
        ..vehicleModel = 'Corolla'
        ..vehiclePlate = 'GR-1234-22'
        ..vehicleSeats = 0;
      expect(c.canAdvance, isFalse);
    });

    // Clearing the seats field runs `int.tryParse('') ?? 0`, so a driver who
    // selects the field and deletes the 4 lands on 0 rather than keeping 4.
    test('clearing the seats field does not leave the previous count', () {
      final c = KycController(StubDriverRepository())..vehicleSeats = 4;
      c.vehicleSeats = int.tryParse('') ?? 0;
      expect(c.vehicleSeats, 0);
      expect(c.canAdvance, isFalse, reason: 'step is identity, not vehicle');
    });

    // Each step writes as it is left, so a driver who loses their connection on
    // the vehicle step keeps the card they already sent.
    test('walking the whole flow writes each document once, in order', () async {
      final repo = StubDriverRepository();
      final c = KycController(repo)
        ..fullName = 'Jane Cooper'
        ..step = KycStep.ghanaCard
        ..cardNumber = 'GHA-123456789-0'
        ..cardExpiry = '04/29'
        ..cardName = 'JANE COOPER';
      await c.advance();
      expect(repo.cardNumber, 'GHA-123456789-0');
      expect(c.step, KycStep.selfie);

      c.selfiePath = '/tmp/selfie.jpg';
      await c.advance();
      expect(repo.selfiePath, '/tmp/selfie.jpg');
      expect(c.step, KycStep.vehicle);

      c
        ..vehicleMake = 'Toyota'
        ..vehicleModel = 'Corolla'
        ..vehiclePlate = 'GR-1234-22'
        ..vehicleSeats = 4;
      await c.advance();
      expect(repo.savedVehicle!.plate, 'GR-1234-22');
      expect(c.step, KycStep.review);
    });

    // `guard_profile_update` raises on any `kyc_status` other than `pending`, so
    // a client can never approve itself. A controller whose `submit()` landed on
    // `approved` from its own writes would tell a driver they can drive when the
    // row says they cannot.
    test('submitting never reports approval the server did not give', () async {
      final repo = StubDriverRepository()
        ..profile = driverProfile(kyc: KycStatus.pending);
      final c = KycController(repo)
        ..step = KycStep.review
        ..cardNumber = 'GHA-123456789-0'
        ..cardExpiry = '04/29'
        ..cardName = 'JANE COOPER'
        ..selfiePath = '/tmp/selfie.jpg'
        ..vehicleMake = 'Toyota'
        ..vehicleModel = 'Corolla'
        ..vehiclePlate = 'GR-1234-22'
        ..vehicleSeats = 4;
      await c.submit();
      expect(c.step, KycStep.underReview);
      expect(c.error, isNull);
    });

    test('submitting reports approval when the server has approved', () async {
      final repo = StubDriverRepository()
        ..profile = driverProfile(kyc: KycStatus.approved);
      final c = KycController(repo)..step = KycStep.review;
      await c.submit();
      expect(c.step, KycStep.approved);
    });

    // The plan's `submit()` uploaded the same selfie a second time and wrote
    // the same vehicle row a second time on every submit.
    test('submitting does not write the documents a second time', () async {
      final repo = StubDriverRepository()
        ..profile = driverProfile(kyc: KycStatus.pending);
      final c = KycController(repo)..step = KycStep.review;
      await c.submit();
      expect(repo.selfiePath, isNull);
      expect(repo.savedVehicle, isNull);
      expect(repo.cardNumber, isNull);
    });

    test('a failed read during submit is shown and holds the step', () async {
      final repo = StubDriverRepository()..meFails = true;
      final c = KycController(repo)..step = KycStep.review;
      await c.submit();
      expect(c.step, KycStep.review);
      expect(c.error, isNotNull);
    });

    test('a failed card write is shown and holds the step', () async {
      final c = KycController(_FailingDriverRepository())
        ..step = KycStep.ghanaCard
        ..cardNumber = 'GHA-123456789-0'
        ..cardExpiry = '04/29';
      await c.advance();
      expect(c.step, KycStep.ghanaCard);
      expect(c.error, isNotNull);
      expect(c.busy, isFalse);
    });

    test('checkStatus moves under review to approved when it is approved now',
        () async {
      final repo = StubDriverRepository()
        ..profile = driverProfile(kyc: KycStatus.pending);
      final c = KycController(repo)..step = KycStep.underReview;
      repo.profile = driverProfile(kyc: KycStatus.approved);
      await c.checkStatus();
      expect(c.step, KycStep.approved);
    });

    test('checkStatus says so when there is no driver profile at all', () async {
      final c = KycController(StubDriverRepository())..step = KycStep.underReview;
      await c.checkStatus();
      expect(c.step, KycStep.underReview);
      expect(c.error, isNotNull);
    });

    test('back walks the steps and stops at the first', () async {
      final c = KycController(StubDriverRepository())..step = KycStep.vehicle;
      c.back();
      expect(c.step, KycStep.selfie);
      c.back();
      expect(c.step, KycStep.ghanaCard);
      c.back();
      expect(c.step, KycStep.identity);
      c.back();
      expect(c.step, KycStep.identity);
    });

    test('a scan fills the three card fields', () {
      final c = KycController(StubDriverRepository())..step = KycStep.ghanaCard;
      c.applyScan(_scan);
      expect(c.cardNumber, 'GHA-123456789-0');
      expect(c.cardExpiry, '04/29');
      expect(c.cardName, 'JANE COOPER');
      expect(c.error, isNull);
    });

    test('a failed scan changes nothing and says why', () {
      final c = KycController(StubDriverRepository())..step = KycStep.ghanaCard;
      c
        ..cardNumber = 'GHA-000000000-0'
        ..cardExpiry = '01/30';
      c.applyScan('nonsense');
      expect(c.error, isNotNull);
      expect(c.cardNumber, 'GHA-000000000-0', reason: 'the typed value is kept');
      expect(c.cardExpiry, '01/30');
    });

    test('advance does nothing when the step is not ready', () async {
      final repo = StubDriverRepository();
      final c = KycController(repo)..step = KycStep.vehicle;
      await c.advance();
      expect(c.step, KycStep.vehicle);
      expect(repo.savedVehicle, isNull);
    });
  });

  group('KycScreen', () {
    testWidgets('the identity step shows the name field', (tester) async {
      useDesignSurface(tester);
      final c = KycController(StubDriverRepository());
      await tester.pumpWidget(wrap(c));
      expect(find.byKey(const Key('fullNameField')), findsOneWidget);
      expect(find.byKey(const Key('kycNextButton')), findsOneWidget);
    });

    testWidgets('typing a name enables Continue', (tester) async {
      useDesignSurface(tester);
      final c = KycController(StubDriverRepository());
      await tester.pumpWidget(wrap(c));

      await tester.enterText(find.byKey(const Key('fullNameField')), 'Jane Cooper');
      await tester.pumpAndSettle();

      final button = tester.widget<FilledButton>(find.byKey(const Key('kycNextButton')));
      expect(button.onPressed, isNotNull);
    });

    testWidgets('the card step renders the three fields and next button',
        (tester) async {
      useDesignSurface(tester);
      final c = KycController(StubDriverRepository())..step = KycStep.ghanaCard;
      await tester.pumpWidget(wrap(c));
      expect(find.byKey(const Key('ghanaCardNumberField')), findsOneWidget);
      expect(find.byKey(const Key('ghanaCardExpiryField')), findsOneWidget);
      expect(find.byKey(const Key('ghanaCardNameField')), findsOneWidget);
      expect(find.byKey(const Key('kycNextButton')), findsOneWidget);
    });

    // There is no OCR engine in this build. The plan's version had a button
    // that called `applyScan` on a hard-coded 'GHA-123456789-0 / JANE COOPER'
    // string and threw the captured path away, which prefilled every driver's
    // card with somebody else's card and looked right.
    testWidgets('the card step does not offer to scan a card into existence',
        (tester) async {
      useDesignSurface(tester);
      final c = KycController(StubDriverRepository())..step = KycStep.ghanaCard;
      await tester.pumpWidget(wrap(c));
      expect(find.byKey(const Key('scanTextButton')), findsOneWidget);
      expect(find.textContaining('not switched on'), findsOneWidget);

      final controller = tester
          .widget<TextField>(find.byKey(const Key('ghanaCardNumberField')));
      expect(controller.controller?.text ?? '', isEmpty);
    });

    testWidgets('pasted scan text fills the three fields', (tester) async {
      useDesignSurface(tester);
      final c = KycController(StubDriverRepository())..step = KycStep.ghanaCard;
      await tester.pumpWidget(wrap(c));

      await tester.tap(find.byKey(const Key('scanTextButton')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('scanTextField')), _scan);
      await tester.tap(find.byKey(const Key('scanTextConfirmButton')));
      await tester.pumpAndSettle();

      expect(find.text('GHA-123456789-0'), findsOneWidget);
      expect(find.text('04/29'), findsOneWidget);
      expect(find.text('JANE COOPER'), findsOneWidget);
    });

    testWidgets('an unreadable paste says so and fills nothing', (tester) async {
      useDesignSurface(tester);
      final c = KycController(StubDriverRepository())..step = KycStep.ghanaCard;
      await tester.pumpWidget(wrap(c));

      await tester.tap(find.byKey(const Key('scanTextButton')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('scanTextField')), 'nonsense');
      await tester.tap(find.byKey(const Key('scanTextConfirmButton')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not read the card number'), findsOneWidget);
    });

    testWidgets('the selfie step captures and says so', (tester) async {
      useDesignSurface(tester);
      final c = KycController(StubDriverRepository())..step = KycStep.selfie;
      // A scanner has to be injected for this one. The default is now the real
      // camera, which cannot open under `flutter test`, so without this the
      // capture correctly returns null and there is nothing to announce. The
      // default being the camera is the point of the next test down.
      await tester.pumpWidget(
        wrap(c, selfieScanner: ScannerStub('/tmp/selfie.jpg')),
      );

      expect(find.text('Selfie captured. Press Continue.'), findsNothing);
      await tester.tap(find.byKey(const Key('selfieButton')));
      await tester.pumpAndSettle();
      expect(find.text('Selfie captured. Press Continue.'), findsOneWidget);
    });

    testWidgets('a cancelled capture is not a capture', (tester) async {
      useDesignSurface(tester);
      final c = KycController(StubDriverRepository())..step = KycStep.selfie;
      await tester.pumpWidget(
        appHarness(
          ChangeNotifierProvider<KycController>.value(
            value: c,
            child: KycScreen(controller: c, selfieScanner: ScannerStub(null)),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('selfieButton')));
      await tester.pumpAndSettle();
      expect(find.text('Selfie captured. Press Continue.'), findsNothing);
    });

    // This is the bug that stopped a driver dead, pinned so it cannot come
    // back.
    //
    // The screen defaulted to `ScannerStub('/tmp/selfie.jpg')`. A stub returns
    // that path without opening a camera, so the step reported "Selfie
    // captured" for a file that was never created -- and `submitSelfie`, which
    // checks the path is a readable file, then refused it with "The selfie
    // could not be read back". Onboarding was impossible and every test passed,
    // because the tests that exercise this inject their own scanner and never
    // looked at the default.
    testWidgets('with no scanner injected the button opens the real camera', (
      tester,
    ) async {
      useDesignSurface(tester);
      final c = KycController(StubDriverRepository())..step = KycStep.selfie;
      await tester.pumpWidget(
        appHarness(
          ChangeNotifierProvider<KycController>.value(
            value: c,
            child: KycScreen(controller: c),
          ),
        ),
      );

      final button =
          tester.widget<CaptureButton>(find.byKey(const Key('selfieButton')));

      // Not merely "not a ScannerStub" but positively the camera: a stub of
      // some other shape would still be a stub.
      expect(button.scanner, isA<ImagePickerScanner>());
      expect(button.scanner, isNot(isA<ScannerStub>()));
    });

    // A path that is not a readable file is already covered where it belongs,
    // in `data_layer_test.dart`, against the real `SupabaseDriverRepository`.
    // `StubDriverRepository` does no I/O, so a test here would only be pinning
    // the fake's behaviour.

    testWidgets('the vehicle step shows the vehicle form', (tester) async {
      useDesignSurface(tester);
      final c = KycController(StubDriverRepository())..step = KycStep.vehicle;
      await tester.pumpWidget(wrap(c));
      expect(find.byKey(const Key('vehicleMakeField')), findsOneWidget);
      expect(find.byKey(const Key('vehicleModelField')), findsOneWidget);
      expect(find.byKey(const Key('vehiclePlateField')), findsOneWidget);
      expect(find.byKey(const Key('vehicleSeatsField')), findsOneWidget);
      expect(find.byKey(const Key('vehicleCategoryField')), findsOneWidget);
    });

    testWidgets('a plate is upper-cased as it is typed', (tester) async {
      useDesignSurface(tester);
      final c = KycController(StubDriverRepository())..step = KycStep.vehicle;
      await tester.pumpWidget(wrap(c));

      await tester.enterText(find.byKey(const Key('vehiclePlateField')), 'gr-1234-22');
      await tester.pumpAndSettle();
      expect(c.vehiclePlate, 'GR-1234-22');
    });

    testWidgets('the review step shows what was collected', (tester) async {
      useDesignSurface(tester);
      final c = KycController(StubDriverRepository())
        ..step = KycStep.review
        ..cardName = 'JANE COOPER'
        ..cardNumber = 'GHA-123456789-0'
        ..cardExpiry = '04/29'
        ..vehicleMake = 'Toyota'
        ..vehicleModel = 'Corolla'
        ..vehiclePlate = 'GR-1234-22';
      await tester.pumpWidget(wrap(c));
      expect(find.byKey(const Key('kycSubmitButton')), findsOneWidget);
      expect(find.textContaining('JANE COOPER'), findsOneWidget);
      expect(find.textContaining('GHA-123456789-0 (04/29)'), findsOneWidget);
      expect(find.textContaining('Toyota Corolla (GR-1234-22)'), findsOneWidget);
    });

    testWidgets('the approved step shows the confirmation once', (tester) async {
      useDesignSurface(tester);
      final c = KycController(StubDriverRepository())..step = KycStep.approved;
      await tester.pumpWidget(wrap(c));
      // The plan put the step's headline in the app bar *and* the same string in
      // the body, so its own `findsOneWidget` could never pass.
      expect(find.text('You are verified'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.byKey(const Key('kycStartDrivingButton')), findsOneWidget);
    });

    testWidgets('no step renders its headline twice', (tester) async {
      useDesignSurface(tester);
      const headlines = {
        KycStep.identity: 'Tell us about yourself',
        KycStep.ghanaCard: 'Scan your Ghana Card',
        KycStep.selfie: 'Take a selfie',
        KycStep.vehicle: 'Add your vehicle',
        KycStep.review: 'Review your details',
        KycStep.underReview: 'Sent for review',
        KycStep.approved: 'You are verified',
      };
      for (final entry in headlines.entries) {
        final c = KycController(StubDriverRepository())..step = entry.key;
        await tester.pumpWidget(wrap(c));
        expect(
          find.text(entry.value).evaluate().length,
          1,
          reason: '${entry.key.name}: "${entry.value}" is rendered more than once',
        );
      }
    });

    testWidgets('under review says a human decides, not the app',
        (tester) async {
      useDesignSurface(tester);
      final c = KycController(StubDriverRepository())..step = KycStep.underReview;
      await tester.pumpWidget(wrap(c));
      expect(find.byKey(const Key('kycCheckStatusButton')), findsOneWidget);
      expect(find.textContaining('administrator'), findsOneWidget);
    });

    testWidgets('Start driving is wired to the shell callback', (tester) async {
      useDesignSurface(tester);
      var continued = 0;
      final c = KycController(StubDriverRepository())..step = KycStep.approved;
      await tester.pumpWidget(wrap(c, onContinue: () => continued++));

      await tester.tap(find.byKey(const Key('kycStartDrivingButton')));
      await tester.pumpAndSettle();
      expect(continued, 1);
    });

    testWidgets('a controller error is shown on the screen', (tester) async {
      useDesignSurface(tester);
      final c = KycController(StubDriverRepository())
        ..step = KycStep.vehicle
        ..error = 'That vehicle was not saved';
      await tester.pumpWidget(wrap(c));
      expect(find.text('That vehicle was not saved'), findsOneWidget);
    });

    testWidgets('the progress bar advances with the step', (tester) async {
      useDesignSurface(tester);
      final c = KycController(StubDriverRepository());
      await tester.pumpWidget(wrap(c));
      final first = tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value;

      c.step = KycStep.vehicle;
      await tester.pumpAndSettle();
      final later = tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value;

      expect(first, isNotNull);
      expect(later!, greaterThan(first!));
    });
  });
}

class _FailingDriverRepository extends StubDriverRepository {
  @override
  Future<void> submitGhanaCard({
    required String cardNumber,
    required String expiry,
    required String fullName,
  }) async {
    throw const DriverAuthFailure('Upload failed, try again');
  }
}
