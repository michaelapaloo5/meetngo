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
  VoidCallback? onContinue,
}) =>
    ScreenUtilInit(
      designSize: const Size(390, 844),
      builder: (_, _) => MaterialApp(
        theme: MngTheme.light,
        home: Scaffold(
          body: DocumentChecklist(
            documents: sent,
            capture: capture ?? _StubCapture(),
            onUpload: onUpload ?? (_, _) async {},
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

  group('all six documents are listed, by name', () {
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
      expect(driverDocumentKinds, hasLength(6));
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

    testWidgets('the kinds agree with the database check constraint', (tester) async {
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
      };
      expect(driverDocumentKinds.map((k) => k.wire).toSet(), allowed);
    });
  });

  group('progress', () {
    testWidgets('with nothing sent it says how many are needed', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(const []));
      await reveal(tester, footer);

      expect(find.text('6 still needed'), findsOneWidget);
    });

    testWidgets('the count goes down as documents arrive', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap([sent(DriverDocumentKind.roadWorthy)]));
      await reveal(tester, footer);

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
        wrap(
          [for (final kind in driverDocumentKinds) sent(kind)],
          onContinue: () => continued++,
        ),
      );
      await reveal(tester, footer);

      final button = tester.widget<FilledButton>(footer);
      expect(button.onPressed, isNotNull);
      await tester.tap(footer);
      expect(continued, 1);
    });
  });

  group('taking a photo', () {
    testWidgets('a captured photo is uploaded for that document',
        (tester) async {
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

    testWidgets('a refused upload leaves the row unticked and says why',
        (tester) async {
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
      expect(find.text('5 still needed'), findsOneWidget);
    });
  });

  group('the face check', () {
    testWidgets('it is on the screen, so a driver knows it is coming',
        (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(const []));
      await reveal(tester, find.byKey(const Key('livenessRow')));

      expect(find.byKey(const Key('livenessRow')), findsOneWidget);
    });

    testWidgets('it does not claim the face has been verified', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(
        wrap([for (final kind in driverDocumentKinds) sent(kind)]),
      );
      await reveal(tester, find.byKey(const Key('livenessRow')));

      // The one thing this screen must not do. Liveness and a face match
      // against the licence are bought from a provider; a tick saying "verified"
      // on a screen whose whole job is honesty would be the worst lie in the
      // flow, and it would be believed by an admin approving a stranger.
      expect(find.textContaining('verified'), findsNothing);
      expect(find.textContaining('not connected yet'), findsOneWidget);
    });

    testWidgets('it does not count towards the six', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(const []));
      await reveal(tester, footer);

      // Six is six. If the face check counted, a driver would be told they had
      // sent a document they cannot send from this screen.
      expect(find.text('6 still needed'), findsOneWidget);
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
