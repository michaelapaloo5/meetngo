import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_driver/src/data/driver_repository.dart';
import 'package:meetngo_driver/src/onboarding/phone_gate_screen.dart';

import '../support/fakes.dart';
import '../support/harness.dart';

/// The screen an approved driver with no phone number gets.
///
/// This exists because of a measurement, not a hunch: at the point it was
/// written, 2 of the 3 driver profiles in the live database had
/// `phone = ''`, and deleting them instead would have taken 14 documents,
/// 3 vehicles, 2 trips, 2 ledger entries and GHS 6.07 of completed work --
/// and re-verification with it. So the missing field is asked for.

void main() {
  late StubDriverRepository repo;
  late List<String> saved;

  /// [holdSave] is the seam for testing an in-flight write. The stub repository
  /// completes synchronously, so without something to hold the future open there
  /// is no moment where `_busy` is true by the time a frame is drawn -- and a
  /// test that cannot observe the busy state cannot check that a second tap is
  /// refused. Real writes take a round trip; this makes the test take one too.
  Widget wrap({Object? saveError, Completer<void>? holdSave}) {
    repo.savePhoneError = saveError;
    return appHarness(
      PhoneGateScreen(onSaved: (phone) async {
        saved.add(phone);
        await repo.savePhone(phone);
        if (holdSave != null) await holdSave.future;
      }),
    );
  }

  setUp(() {
    repo = StubDriverRepository();
    saved = <String>[];
  });

  group('it asks for one thing', () {
    testWidgets('shows a phone field and one button', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap());
      expect(find.byKey(const Key('phoneGateField')), findsOneWidget);
      expect(find.byKey(const Key('phoneGateSaveButton')), findsOneWidget);
    });

    // Double-quoted because the name carries an apostrophe, and a single-quoted
    // Dart string cannot hold one unescaped. The compiler reported it as
    // "String starting with ' must end with '", which reads like a formatting
    // complaint and is not one.
    testWidgets("says why a rider needs it, in the driver's terms", (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap());
      // "Riders cannot reach you without it" rather than "this field is
      // required". A driver reads the first and acts; the second is a form
      // field talking to itself.
      expect(find.textContaining('cannot reach you'), findsOneWidget);
    });

    testWidgets('says they do not need to upload anything again', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap());
      // The single most important line on this screen. A driver who thinks
      // they are about to re-send six documents closes the app, and a verified
      // driver is not something this business can re-issue.
      expect(find.textContaining('do not need to upload'), findsOneWidget);
    });

    testWidgets('has no back button, because there is nowhere usable to go', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap());
      expect(find.byType(BackButton), findsNothing);
      expect(find.byTooltip('Back'), findsNothing);
    });

    testWidgets('uses the phone keyboard, not a full one', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap());
      // A number field with a full keyboard is a field every driver fights with.
      final field = tester.widget<TextField>(find.byKey(const Key('phoneGateField')));
      expect(field.keyboardType, TextInputType.phone);
    });
  });

  group('the same rule as the sign-up form', () {
    testWidgets('an empty field is unanswered, not malformed', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap());
      await tester.tap(find.byKey(const Key('phoneGateSaveButton')));
      await tester.pump();
      expect(find.textContaining('Enter the number'), findsOneWidget);
    });

    testWidgets('a half-typed number says what a complete one looks like', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap());
      await tester.enterText(find.byKey(const Key('phoneGateField')), '024123');
      await tester.tap(find.byKey(const Key('phoneGateSaveButton')));
      await tester.pump();
      expect(find.textContaining('0241234567'), findsWidgets);
      expect(saved, isEmpty, reason: 'nothing may be written from an incomplete number');
    });

    testWidgets('ten digits with an impossible prefix is refused, and says why', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap());
      await tester.enterText(find.byKey(const Key('phoneGateField')), '0191234567');
      await tester.tap(find.byKey(const Key('phoneGateSaveButton')));
      await tester.pump();
      expect(find.textContaining('020'), findsOneWidget);
      expect(saved, isEmpty);
    });

    testWidgets('a foreign number is refused', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap());
      await tester.enterText(find.byKey(const Key('phoneGateField')), '+1 202 555 0143');
      await tester.tap(find.byKey(const Key('phoneGateSaveButton')));
      await tester.pump();
      expect(saved, isEmpty);
    });
  });

  group('saving', () {
    testWidgets('reduces every local spelling to the same ten digits', (tester) async {
      // The whole point of normalising: a rider who dials `+233 24 123 4567`
      // and a driver who typed `0241234567` are the same number, so the column
      // has to hold one spelling or the Call button rings nobody.
      for (final typed in ['0241234567', '024 123 4567', '0024 123 4567']) {
        useDesignSurface(tester);
        await tester.pumpWidget(wrap());
        await tester.enterText(find.byKey(const Key('phoneGateField')), typed);
        await tester.tap(find.byKey(const Key('phoneGateSaveButton')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(repo.phone, '0241234567', reason: typed);
        saved.clear();
      }
    });

    testWidgets('keeps the international form when the driver typed a plus', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap());
      await tester.enterText(find.byKey(const Key('phoneGateField')), '+233 24 123 4567');
      await tester.tap(find.byKey(const Key('phoneGateSaveButton')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // Not rewritten to `0241234567`. A `+` is the driver telling us how they
      // write their own number, and both Android and iOS dial the international
      // form identically, so there is nothing to gain by overriding their choice
      // and a name they recognise on their own profile to lose.
      expect(repo.phone, '233241234567');
    });

    testWidgets('stores it normalised, not as typed', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap());
      await tester.enterText(find.byKey(const Key('phoneGateField')), '024 123 4567');
      await tester.tap(find.byKey(const Key('phoneGateSaveButton')));
      // Not `pumpAndSettle`: the field is `autofocus`, so its cursor blinks on a
      // timer forever and the tree never settles. That is right for a driver
      // landing on a one-field gate -- the keyboard is already up -- and it means
      // any test here has to advance frames explicitly.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // The column holds one spelling per number. This is what the call feature
      // and the contact function both read.
      expect(repo.phone, '0241234567');
    });

    testWidgets('a failed save is reported and keeps the driver on the screen', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(
        saveError: DriverAuthFailure('Could not save your number. Try again.'),
      ));
      await tester.enterText(find.byKey(const Key('phoneGateField')), '0241234567');
      await tester.tap(find.byKey(const Key('phoneGateSaveButton')));
      // Not `pumpAndSettle`: the field is `autofocus`, so its cursor blinks on a
      // timer forever and the tree never settles. That is right for a driver
      // landing on a one-field gate -- the keyboard is already up -- and it means
      // any test here has to advance frames explicitly.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // Still here, with a way forward. A silent failure on a gate screen is a
      // driver who taps Save repeatedly and concludes the app is broken.
      expect(find.byKey(const Key('phoneGateField')), findsOneWidget);
      expect(find.textContaining('Check your connection'), findsOneWidget);
    });

    testWidgets('the button is disabled while the write is in flight', (tester) async {
      // A second tap while the first write is open would write the same row
      // twice and, on a slow connection, leave the driver watching a button
      // that appears to do nothing twice.
      final hold = Completer<void>();
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(holdSave: hold));
      await tester.enterText(find.byKey(const Key('phoneGateField')), '0241234567');
      await tester.tap(find.byKey(const Key('phoneGateSaveButton')));
      await tester.pump(); // one frame: busy is now true, and still is
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('phoneGateSaveButton'))).onPressed,
        isNull,
      );

      // A second tap on the same spot while the write is open must not write a
      // second time. `tapAt` rather than `tap`, because `tap` on a widget whose
      // centre is covered by nothing throws a "would not hit test" warning --
      // and the whole point is that the button is no longer tappable.
      await tester.tapAt(tester.getCenter(find.byKey(const Key('phoneGateSaveButton'))));
      await tester.pump();
      expect(saved, hasLength(1));

      hold.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // And it comes back, so a write that dies at the network layer does not
      // leave the driver on a screen with a spinner and no way forward.
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('phoneGateSaveButton'))).onPressed,
        isNotNull,
      );
    });

    testWidgets('typing again clears the stale error', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap());
      await tester.enterText(find.byKey(const Key('phoneGateField')), '024123');
      await tester.tap(find.byKey(const Key('phoneGateSaveButton')));
      await tester.pump();
      expect(find.textContaining('looks too short'), findsOneWidget);
      // Now they start fixing it. The message must not still be accusing them
      // of the thing they are halfway through correcting.
      await tester.enterText(find.byKey(const Key('phoneGateField')), '0241234567');
      await tester.pump();
      expect(find.textContaining('looks too short'), findsNothing);
    });
  });

  group('the field itself', () {
    testWidgets('accepts digits, spaces and a plus, and drops letters as typed', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap());
      await tester.enterText(find.byKey(const Key('phoneGateField')), 'a+0 2b4c1 2d3e4 5f6g7');
      final field = tester.widget<TextField>(find.byKey(const Key('phoneGateField')));
      // Dropped by the formatter while typing, not rejected on save: a driver
      // who fat-fingers a letter mid-number should see the number correct
      // itself, and should not be told they mistyped something they never typed.
      // The spaces they typed stay where they were typed -- the formatter
      // removes the letters, it does not re-space the digits -- and
      // `normaliseGhanaPhone` is what strips them before the write.
      expect(field.controller?.text, '+0 241 234 567');
    });
  });
}