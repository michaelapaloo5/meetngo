import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_driver/src/onboarding/document_scanner_stub.dart';
import 'package:meetngo_driver/src/onboarding/kyc_controller.dart';
import 'package:meetngo_driver/src/onboarding/kyc_screen.dart';
import 'package:provider/provider.dart';

import '../support/fakes.dart';
import '../support/harness.dart';

/// What a driver is shown once a decision has been made about their identity.
///
/// The rule under test is
/// `supabase/migrations/20260930000006_freeze_kyc_identity.sql`: after
/// `kyc_status` leaves `pending`, the Ghana Card columns and the selfie cannot be
/// rewritten by the client. That was found by measuring, not by reading the
/// schema -- `toolchain/who-actually-writes.mjs` signs in as a real driver and
/// wrote `ghana_card_number` successfully while `kyc_status` was refused.
///
/// A rule the user only discovers by being refused is a rule they do not
/// believe, so the app has to state it. That is what this screen is: not
/// decoration, and not a disabled form.

void main() {
  Widget wrap(KycController c) => appHarness(
    ChangeNotifierProvider<KycController>.value(
      value: c,
      child: KycScreen(controller: c, selfieScanner: ScannerStub(null)),
    ),
  );

  KycController decided({
    KycStep step = KycStep.approved,
    String? cardNumber = 'GHA-123456789-0',
  }) => KycController(StubDriverRepository())
    ..step = step
    ..cardNumber = cardNumber
    ..cardDob = '1994-03-14'
    ..cardExpiry = '2031-07-02'
    ..cardNationality = 'Ghanaian';

  group('once a decision is made, the driver can see what was decided about', () {
    testWidgets('the approved screen shows the card it approved', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(decided()));

      expect(find.byKey(const Key('kycSubmittedIdentity')), findsOneWidget);
      expect(find.byKey(const Key('kycDetail_Cardnumber')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('kycDetail_Cardnumber'))).data,
        'GHA-123456789-0',
      );
      // The rest of the card, not just the number. An employee checks all six
      // against the photograph, so a summary carrying one of six is not the
      // thing they checked.
      expect(find.byKey(const Key('kycDetail_Dateofbirth')), findsOneWidget);
      expect(find.byKey(const Key('kycDetail_Expires')), findsOneWidget);
      expect(find.byKey(const Key('kycDetail_Nationality')), findsOneWidget);
    });

    testWidgets('the under-review screen shows it too', (tester) async {
      useDesignSurface(tester);
      // A driver sitting on "sent for review" has no idea whether the app saved
      // what they scanned, and the freeze means they can no longer go and check
      // by changing it.
      await tester.pumpWidget(wrap(decided(step: KycStep.underReview)));

      expect(find.byKey(const Key('kycSubmittedIdentity')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('kycDetail_Cardnumber'))).data,
        'GHA-123456789-0',
      );
    });

    testWidgets('it says the fields are locked', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(decided()));
      expect(
        tester.widget<Text>(find.byKey(const Key('kycIdentityLockedNote'))).data,
        contains('Locked'),
      );
    });

    testWidgets('the approved note points at an administrator, not a reopen', (
      tester,
    ) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(decided()));
      // Two different sentences, because they mean different things. "Ask staff
      // to reopen it" on the approved screen would be a promise the app cannot
      // keep: the review is closed, and only an administrator can reopen it.
      final note = tester.widget<Text>(find.byKey(const Key('kycIdentityLockedNote'))).data!;
      expect(note, contains('administrator'));
      expect(note, isNot(contains('reopen')));
    });

    testWidgets('the under-review note does offer a reopen', (tester) async {
      useDesignSurface(tester);
      // The reverse. A driver whose card was misread while the review is still
      // open is exactly who should ask for it to be reopened.
      await tester.pumpWidget(wrap(decided(step: KycStep.underReview)));
      final note = tester.widget<Text>(find.byKey(const Key('kycIdentityLockedNote'))).data!;
      expect(note, contains('reopen'));
    });
  });

  group('nothing here is editable', () {
    testWidgets('the summary is text, not fields the driver can type into', (
      tester,
    ) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(decided()));

      // Not a disabled TextField. A greyed box still invites taps and reads as
      // broken; plain text reads as a record.
      expect(find.byType(TextField), findsNothing);
      expect(find.byKey(const Key('ghanaCardNumberField')), findsNothing);
    });

    testWidgets('the summary is not on the review step, which is still editable', (
      tester,
    ) async {
      useDesignSurface(tester);
      final c = decided()..step = KycStep.ghanaCard;
      await tester.pumpWidget(wrap(c));

      // The freeze is conditional on a decision existing. A pending driver must
      // still be able to correct a misread card, or a typo becomes permanent --
      // which would be a worse outcome than the one the freeze prevents.
      expect(find.byKey(const Key('ghanaCardNumberField')), findsOneWidget);
      expect(find.byKey(const Key('kycSubmittedIdentity')), findsNothing);
    });
  });

  group('a driver who never gave a card', () {
    testWidgets('sees no summary at all', (tester) async {
      useDesignSurface(tester);
      // An empty box headed "What we verified" is worse than no box: it claims a
      // verification happened against something.
      await tester.pumpWidget(wrap(decided(cardNumber: null)));

      expect(find.byKey(const Key('kycSubmittedIdentity')), findsNothing);
    });

    testWidgets('sees the lock note nowhere either', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(decided(cardNumber: '')));

      expect(find.byKey(const Key('kycIdentityLockedNote')), findsNothing);
    });
  });

  group('a field that was never filled in', () {
    testWidgets('says "not given" rather than rendering blank', (tester) async {
      useDesignSurface(tester);
      // The same word the review step uses, and for the same reason: an empty
      // row reads as a rendering failure, and a driver would assume the app had
      // lost what they scanned.
      final c = decided();
      await tester.pumpWidget(wrap(c));

      expect(
        tester.widget<Text>(find.byKey(const Key('kycDetail_Dateofissue'))).data,
        'not given',
      );
    });
  });

  group('the screen keeps working', () {
    testWidgets('the approved screen still offers Start driving', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(decided()));

      // The summary is an addition to a page, not a replacement for it. A driver
      // who cannot leave the approved screen is worse off than one who cannot
      // see their card.
      expect(find.byKey(const Key('kycStartDrivingButton')), findsOneWidget);
    });

    testWidgets('the under-review screen still offers Check status', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(decided(step: KycStep.underReview)));

      expect(find.byKey(const Key('kycCheckStatusButton')), findsOneWidget);
    });
  });
}