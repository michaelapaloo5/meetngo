import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_driver/src/data/driver_repository.dart';
import 'package:meetngo_driver/src/onboarding/document_checklist.dart';
import 'package:meetngo_driver/src/onboarding/driver_document.dart';
import 'package:mng_core/mng_core.dart';

/// The document checklist a new driver sees straight after signing up.
///
/// The screen's whole job is to make a driver fetch six things before they leave
/// the house, so the tests are about that list being honest and complete: every
/// document present and named, nothing tickable that was not sent, and a refusal
/// leaving the row unticked rather than half-done.
class _StubCapture implements DocumentCapture {
  _StubCapture({this.path = '/tmp/photo.jpg'});

  /// What [capture] answers. Null is a back-out.
  String? path;

  int calls = 0;

  @override
  Future<String?> capture() async {
    calls++;
    return path;
  }
}

Widget wrap(
  List<DriverDocument> sent, {
  DocumentCapture? capture,
  Future<void> Function(DriverDocumentKind, String)? onUpload,
  VoidCallback? onStartLiveness,
  VoidCallback? onContinue,
}) => ScreenUtilInit(
  designSize: const Size(390, 844),
  builder: (_, _) => MaterialApp(
    theme: MngTheme.light,
    home: Scaffold(
      body: DocumentChecklist(
        documents: sent,
        capture: capture ?? _StubCapture(),
        onUpload: onUpload ?? (_, _) async {},
        onStartLiveness: onStartLiveness,
        onContinue: onContinue,
      ),
    ),
  ),
);

DriverDocument sent(DriverDocumentKind kind) => DriverDocument(
  kind: kind,
  path: 'u1/${kind.wire}/1.jpg',
  createdAt: DateTime.utc(2026, 9, 28),
);

/// Scrolls the checklist until [target] is on screen.
///
/// The list is a `ListView` and six rows plus a footer do not fit on a 360x800
/// phone, which is the point -- the list has to be able to overflow. So a test
/// asserting on the footer has to scroll to it, and a test that cannot find the
/// footer is not evidence the footer is missing, only that it is below the
/// fold. Asserting without this would have been quietly testing a list that
/// happens to be short.
Future<void> reveal(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    120,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

/// The footer's label, which doubles as the count of what is still needed.
Finder get footer => find.byKey(const Key('documentsContinue'));

void main() {
  void useDesignSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  group('every required item is listed, by name', () {
    testWidgets('every one of them is on screen', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(const []));

      // The list is the feature. A driver who is told they need six documents
      // and shown five has driven to the depot for nothing.
      expect(find.byKey(const Key('documentChecklist')), findsOneWidget);
      for (final kind in driverDocumentKinds) {
        expect(
          find.byKey(Key('document-${kind.wire}')),
          findsOneWidget,
          reason: '${kind.wire} is missing from the checklist',
        );
      }
      expect(driverDocumentKinds, hasLength(7));
      expect(
        driverPhotoKinds,
        hasLength(6),
        reason: 'six photographs, plus the face check',
      );
    });

    testWidgets('each row says what the photo has to show', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(const []));

      // Not just a label. "Road worthy certificate" does not tell a driver the
      // expiry has to be readable, and an unreadable expiry is the single most
      // common reason one of these comes back.
      for (final kind in driverDocumentKinds) {
        expect(
          find.text(kind.hint),
          findsOneWidget,
          reason: '${kind.wire} has no instruction',
        );
      }
    });

    testWidgets('the kinds agree with the database check constraint', (
      tester,
    ) async {
      // The wire values are what the `driver_documents` check constraint
      // accepts, and a seventh document added to this enum but not to the SQL
      // would fail on upload with a message about a constraint.
      const allowed = {
        'profilePhoto',
        'vehiclePhoto',
        'ghanaCardPhoto',
        'driversLicence',
        'roadWorthy',
        'insuranceSticker',
        // The face check's proof frame, from
        // `20260929000003_liveness_frame.sql`. A kind in this enum but not in
        // the SQL would fail on upload with a message about a constraint, and a
        // kind in the SQL but not here would mean the app could never produce
        // the one document the admin page most needs to see.
        'livenessFrame',
      };
      expect(driverDocumentKinds.map((k) => k.wire).toSet(), allowed);
    });
  });

  group('progress', () {
    testWidgets('with nothing sent it says how many are needed', (
      tester,
    ) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(const []));
      await reveal(tester, footer);

      expect(find.text('6 still needed'), findsOneWidget);
    });

    testWidgets('the count goes down as documents arrive', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap([sent(DriverDocumentKind.roadWorthy)]));
      await reveal(tester, footer);

      // One of the six required photographs in, so five are still needed.
      // The face check is on the list but is not one of them.
      expect(find.text('5 still needed'), findsOneWidget);
    });

    testWidgets('Continue is dead until all six are in', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap([sent(DriverDocumentKind.roadWorthy)]));
      await reveal(tester, footer);

      final button = tester.widget<FilledButton>(footer);
      expect(button.onPressed, isNull);
    });

    testWidgets('Continue works once all six are in', (tester) async {
      useDesignSurface(tester);
      var continued = 0;
      await tester.pumpWidget(
        wrap([
          for (final kind in driverDocumentKinds) sent(kind),
        ], onContinue: () => continued++),
      );
      await reveal(tester, footer);

      final button = tester.widget<FilledButton>(footer);
      expect(button.onPressed, isNotNull);
      await tester.tap(footer);
      expect(continued, 1);
    });
  });

  group('taking a photo', () {
    testWidgets('a captured photo is uploaded for that document', (
      tester,
    ) async {
      useDesignSurface(tester);
      final sent_ = <DriverDocumentKind>[];
      await tester.pumpWidget(
        wrap(const [], onUpload: (kind, _) async => sent_.add(kind)),
      );

      await tester.tap(find.byKey(const Key('document-roadWorthy')));
      await tester.pumpAndSettle();

      expect(sent_, [DriverDocumentKind.roadWorthy]);
    });

    testWidgets('backing out of the camera uploads nothing', (tester) async {
      useDesignSurface(tester);
      final sent_ = <DriverDocumentKind>[];
      await tester.pumpWidget(
        wrap(
          const [],
          capture: _StubCapture(path: null),
          onUpload: (kind, _) async => sent_.add(kind),
        ),
      );

      await tester.tap(find.byKey(const Key('document-roadWorthy')));
      await tester.pumpAndSettle();

      // Backing out of a camera is not a failure, so there is no error, and
      // nothing is uploaded.
      expect(sent_, isEmpty);
      expect(find.byKey(const Key('documentError')), findsNothing);
    });

    testWidgets('a refused upload leaves the row unticked and says why', (
      tester,
    ) async {
      useDesignSurface(tester);
      await tester.pumpWidget(
        wrap(
          const [],
          onUpload: (_, _) async =>
              throw const DriverAuthFailure('That photo could not be saved'),
        ),
      );

      await tester.tap(find.byKey(const Key('document-roadWorthy')));
      await tester.pumpAndSettle();
      await reveal(tester, find.byKey(const Key('documentError')));

      // The message names the failure rather than a generic error, and the row
      // is not marked sent -- a checklist that ticks on a failed upload is a
      // driver who believes they have sent a licence they have not.
      expect(find.byKey(const Key('documentError')), findsOneWidget);
      expect(find.text('That photo could not be saved'), findsOneWidget);
      expect(find.text('6 still needed'), findsOneWidget);
    });

    testWidgets('a sent row can be replaced, and says so', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap([sent(DriverDocumentKind.driversLicence)]));
      await reveal(tester, footer);

      // A driver who photographed their licence at an angle has to be able to
      // fix it without wondering whether tapping duplicates it.
      expect(find.text('Tap to replace this photo'), findsOneWidget);
      // One required photograph in, so five of the six are still needed.
      expect(find.text('5 still needed'), findsOneWidget);
    });
  });

  group('the face check is a real required item', () {
    testWidgets('it has its own row, like the other six', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(const []));
      await reveal(tester, find.byKey(const Key('document-livenessFrame')));

      // Not a note, not an optional extra. A driver told they need a face
      // check who then finds Continue live without one has been told a lie,
      // and the earlier version of this screen -- where the face check was a
      // grey note and did not count -- is exactly how that happened.
      expect(find.byKey(const Key('document-livenessFrame')), findsOneWidget);
      expect(find.text('Face check'), findsOneWidget);
    });

    testWidgets('tapping it opens the check rather than the camera', (
      tester,
    ) async {
      useDesignSurface(tester);
      var started = 0;
      final capture = _StubCapture();
      await tester.pumpWidget(
        wrap(const [], capture: capture, onStartLiveness: () => started++),
      );
      await reveal(tester, find.byKey(const Key('document-livenessFrame')));

      await tester.tap(find.byKey(const Key('document-livenessFrame')));
      await tester.pumpAndSettle();

      // The system camera cannot run a liveness check: it hands back one
      // photograph and nothing else, and the check has to watch a face move
      // over a second or two. If this ever goes through `capture` again, the
      // check has silently become a selfie.
      expect(started, 1);
      expect(capture.calls, 0);
    });

    testWidgets('it does NOT count towards what is still needed', (
      tester,
    ) async {
      useDesignSurface(tester);
      // All six photographs sent, the face check not done. Continue must be
      // live: a driver is not held at the last step of onboarding by a check
      // whose detector is broken on this build. When `isRequired` goes back to
      // true for the face check, this test fails, and that is the moment it
      // should be updated.
      //
      // `onContinue` is passed because the button is only *wired* to something
      // when the caller supplies it -- a dead Continue on a complete checklist
      // is a different bug and the KYC screen is what supplies the callback in
      // the app.
      var continued = 0;
      await tester.pumpWidget(
        wrap([
          for (final kind in driverPhotoKinds) sent(kind),
        ], onContinue: () => continued++),
      );
      await reveal(tester, footer);

      expect(find.text('Continue'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.byKey(const Key('documentsContinue')),
      );
      expect(button.onPressed, isNotNull);
      await tester.tap(find.byKey(const Key('documentsContinue')));
      expect(continued, 1, reason: 'and it actually goes somewhere');
    });

    testWidgets('but it is still listed, and still tappable', (tester) async {
      useDesignSurface(tester);
      var started = 0;
      await tester.pumpWidget(
        wrap([
          for (final kind in driverPhotoKinds) sent(kind),
        ], onStartLiveness: () => started++),
      );
      await reveal(tester, find.byKey(const Key('document-livenessFrame')));

      // Optional, not removed. A driver who wants to do it now must be able to,
      // and the photo still goes to whoever reviews the documents.
      await tester.tap(find.byKey(const Key('document-livenessFrame')));
      await tester.pumpAndSettle();
      expect(started, 1);
      expect(find.byKey(const Key('document-livenessFrame')), findsOneWidget);
    });

    testWidgets(
      'the note says the photo goes to whoever reviews the documents',
      (tester) async {
        useDesignSurface(tester);
        await tester.pumpWidget(wrap(const []));
        await reveal(tester, find.byKey(const Key('livenessNote')));

        // The check now exists and runs on the device, so the note is no longer
        // apologising for an absence. It is here for the half the check cannot
        // do: it proves somebody live was in front of the camera, and it does
        // not prove the face is the one on the licence.
        expect(find.textContaining('reviewing your documents'), findsOneWidget);
      },
    );

    testWidgets('nothing on the screen claims the face is verified', (
      tester,
    ) async {
      useDesignSurface(tester);
      await tester.pumpWidget(
        wrap([for (final kind in driverDocumentKinds) sent(kind)]),
      );
      await reveal(tester, find.byKey(const Key('livenessNote')));

      // A tick saying "verified" for a check that only proves a live face was
      // present would be the worst lie in the flow, and it would be believed
      // by an admin approving a stranger. The row says "sent".
      expect(find.textContaining('verified'), findsNothing);
    });
  });

  group('layout', () {
    testWidgets('no overflow at 200% text scale', (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
          child: ScreenUtilInit(
            designSize: const Size(390, 844),
            builder: (_, _) => MaterialApp(
              theme: MngTheme.light,
              home: Scaffold(
                body: DocumentChecklist(
                  documents: const [],
                  capture: _StubCapture(),
                  onUpload: (_, _) async {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
