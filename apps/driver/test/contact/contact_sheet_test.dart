import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';
import 'package:meetngo_driver/src/contact/contact_controller.dart';
import 'package:meetngo_driver/src/contact/contact_sheet.dart';

/// The contact sheet, and the two ways to reach somebody.
///
/// The design decision these tests are about: the digits are on screen
/// unconditionally, and the dialler is offered beside them rather than instead of
/// them. `url_launcher` returns false when a `tel:` intent fires and nothing
/// handles it -- a phone with no dialler, no SIM, or a restricted profile -- and
/// a driver whose only affordance is that button is stuck.

const _rider = Contact(
  role: ContactRole.rider,
  phone: '0241234567',
  callable: true,
  name: 'Michael Apaloo',
);

Widget harness(Contact contact) => ScreenUtilInit(
  designSize: const Size(390, 844),
  minTextAdapt: true,
  builder: (_, _) => MaterialApp(
    theme: MngTheme.light,
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => ContactSheet.show(context, contact),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

Future<void> open(WidgetTester tester, Contact contact) async {
  await tester.pumpWidget(harness(contact));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('the number is readable without the dialler', () {
    testWidgets('the number is on screen as soon as the sheet opens', (
      tester,
    ) async {
      await open(tester, _rider);
      // The whole point. A driver whose phone cannot dial still has the digits.
      expect(find.byKey(const Key('contactNumber')), findsOneWidget);
      expect(find.text('024 123 4567'), findsOneWidget);
    });

    testWidgets('the number is selectable, so it can be copied by hand', (
      tester,
    ) async {
      await open(tester, _rider);
      expect(find.byType(SelectableText), findsWidgets);
    });

    testWidgets('the sheet says who it is', (tester) async {
      await open(tester, _rider);
      // "Rider" as well as the name: a driver calling a stranger is calling the
      // person who booked, and the label should say which.
      expect(find.textContaining('Michael'), findsOneWidget);
      expect(find.textContaining('Rider'), findsWidgets);
    });
  });

  group('all three ways to reach them are offered at once', () {
    testWidgets('call, copy and show are all on screen together', (
      tester,
    ) async {
      await open(tester, _rider);
      // Peers, not a primary with a fallback behind it. A driver who picks the
      // wrong one should be one glance from the right one.
      expect(find.byKey(const Key('contactDialButton')), findsOneWidget);
      expect(find.byKey(const Key('contactCopyButton')), findsOneWidget);
      expect(find.byKey(const Key('contactShowButton')), findsOneWidget);
    });

    testWidgets('copy puts the formatted number on the clipboard', (
      tester,
    ) async {
      // This was an empty test body for a while: it opened the sheet and asserted
      // nothing, and passed. A test that passes without checking anything is
      // worse than no test, because it is counted.
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });

      await open(tester, _rider);
      await tester.tap(find.byKey(const Key('contactCopyButton')));
      await tester.pumpAndSettle();

      // The *displayed* form, not the stored one: a driver pasting this into a
      // message wants `024 123 4567`, and a test asserting the raw
      // `0241234567` would pass against a copy button that pastes the wrong
      // thing into a message somebody is reading.
      expect(copied, '024 123 4567');
      // And it says what it did, so the driver is not left wondering.
      expect(find.byKey(const Key('contactMessage')), findsOneWidget);
    });

    testWidgets('show opens a full screen page with the number alone', (
      tester,
    ) async {
      await open(tester, _rider);
      await tester.tap(find.byKey(const Key('contactShowButton')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fullScreenNumber')), findsOneWidget);
      // The point of the page: readable from arm's length, which a bottom sheet
      // inside a trip screen is not.
      expect(find.text('024 123 4567'), findsOneWidget);
    });

    testWidgets('the full screen page also offers to call', (tester) async {
      await open(tester, _rider);
      await tester.tap(find.byKey(const Key('contactShowButton')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fullScreenCallButton')), findsOneWidget);
    });
  });

  group('a number that cannot be called', () {
    const noNumber = Contact(
      role: ContactRole.rider,
      phone: '',
      callable: false,
      name: 'Michael Apaloo',
    );

    testWidgets('says so, rather than showing an empty field', (tester) async {
      await open(tester, noNumber);
      // An empty text field reads as a number that failed to load. Saying "has
      // not added a phone number" is the truth and is actionable.
      expect(find.byKey(const Key('contactNoNumber')), findsOneWidget);
      expect(find.byKey(const Key('contactNumber')), findsNothing);
      expect(find.textContaining('not added a phone number'), findsOneWidget);
    });

    testWidgets('the dial button is disabled, not hidden', (tester) async {
      await open(tester, noNumber);
      // Hidden would leave the sheet with no primary action and a driver
      // wondering what to do. Disabled says "there is nothing here to call" in
      // the place they are looking.
      final button = tester.widget<FilledButton>(
        find.byKey(const Key('contactDialButton')),
      );
      expect(button.onPressed, isNull);
      expect(find.byKey(const Key('contactDialButton')), findsOneWidget);
    });

    testWidgets(
      'copy and show are disabled too, since there is nothing to copy',
      (tester) async {
        await open(tester, noNumber);
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const Key('contactCopyButton')),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const Key('contactShowButton')),
              )
              .onPressed,
          isNull,
        );
      },
    );
  });

  group('a number that is there but cannot be dialled', () {
    // Distinct from the no-number case, and the distinction is the whole design.
    // A driver on a phone with no dialler, or whose number is in a form this app
    // will not dial, still has a number and still needs to read it. The sheet
    // must not treat "I cannot call it" as "there is nothing here".
    //
    // The first version of this suite had no such case, and a mutation that made
    // the number conditional on `callable` passed the whole file -- because every
    // test either had a callable number or had none at all.
    const notCallable = Contact(
      role: ContactRole.rider,
      phone: '0241234567',
      callable: false,
      name: 'Michael Apaloo',
    );

    testWidgets('the number is still shown even though it cannot be dialled', (
      tester,
    ) async {
      await open(tester, notCallable);
      expect(
        find.byKey(const Key('contactNumber')),
        findsOneWidget,
        reason: 'a number this app will not dial is still a number the driver can read',
      );
      expect(find.text('024 123 4567'), findsOneWidget);
    });

    testWidgets('copy and show still work, because both are about the digits', (
      tester,
    ) async {
      await open(tester, notCallable);
      final copy = tester.widget<OutlinedButton>(
        find.byKey(const Key('contactCopyButton')),
      );
      expect(
        copy.onPressed,
        isNotNull,
        reason:
            'copying does not need a dialler, and this is the case it is for',
      );
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('contactShowButton')))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('only the dial button is disabled', (tester) async {
      await open(tester, notCallable);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('contactDialButton')))
            .onPressed,
        isNull,
      );
    });
  });

  group('the Contact model', () {
    test('a name becomes a first name for the button', () {
      expect(_rider.shortName, 'Michael');
      // "Call Apaloo Michael Edem" is a button nobody reads at a junction.
      expect(_rider.actionLabel, 'Call Michael');
    });

    test('no name gives a bare "Call", not "Call null"', () {
      const anonymous = Contact(
        role: ContactRole.rider,
        phone: '0241234567',
        callable: true,
        name: '',
      );
      expect(anonymous.shortName, '');
      expect(anonymous.actionLabel, 'Call');
    });

    test('the dialler URI is only offered for a real Ghanaian number', () {
      expect(_rider.telUri, 'tel:0241234567');
      // A number that is present but belongs to Ohio does not get a dialler,
      // even if the server said it was callable.
      const ohio = Contact(
        role: ContactRole.rider,
        phone: '+12025550100',
        callable: true,
        name: 'Someone',
      );
      expect(ohio.telUri, isNull);
    });

    test(
      'a server that claims a foreign number is callable is not believed',
      () {
        // The server only knows whether a string is present. The client knows what
        // a Ghanaian number looks like. Both checks, so a server that answered
        // `callable: true` for a foreign number still does not open a dialler.
        final parsed = Contact.fromJson({
          'role': 'rider',
          'phone': '+12025550100',
          'callable': true,
          'name': 'Someone',
        });
        expect(parsed.callable, isFalse);
      },
    );

    test('an unrecognised role is refused rather than guessed', () {
      // Showing a driver's number under the heading "rider" is worse than
      // refusing to parse it.
      expect(
        () => Contact.fromJson({
          'role': 'bystander',
          'phone': '0241234567',
          'callable': true,
        }),
        throwsFormatException,
      );
    });

    test('an international number is recognised and kept in its own form', () {
      final parsed = Contact.fromJson({
        'role': 'driver',
        'phone': '+233 24 123 4567',
        'callable': true,
        'name': 'Ama',
      });
      expect(parsed.display, '+233 24 123 4567');
      expect(parsed.telUri, 'tel:233241234567');
    });

    test('looksLikeContact separates a contact from an error body', () {
      expect(
        Contact.looksLikeContact({
          'role': 'rider',
          'phone': '0241234567',
          'callable': true,
        }),
        isTrue,
      );
      // An error body has neither, and must not be parsed into a contact with an
      // empty number -- which would look like a rider with no phone.
      expect(Contact.looksLikeContact({'error': 'no such trip'}), isFalse);
      expect(Contact.looksLikeContact({}), isFalse);
    });
  });

  group('ContactController', () {
    test('loads a contact and stops being busy', () async {
      final c = ContactController(_StubContactRepository(_rider));
      await c.load('t1');
      expect(c.contact, _rider);
      expect(c.busy, isFalse);
      expect(c.error, isNull);
    });

    test('a trip it is not on is null with a message, not a crash', () async {
      final c = ContactController(_StubContactRepository(null));
      await c.load('t1');
      expect(c.contact, isNull);
      expect(c.error, isNotNull);
    });

    test(
      'a failure is reported and leaves no stale contact on screen',
      () async {
        // The dangerous case: a driver finishes a trip and starts another, the
        // second lookup fails, and the first rider's number is still showing.
        final c = ContactController(_FailingContactRepository());
        await c.load('t1');
        expect(c.contact, isNull);
        expect(c.error, isNotNull);
      },
    );

    test('a late answer for an old trip is discarded', () async {
      // A driver who completes one trip and is given the next must never see the
      // previous rider's number. The controller keys every answer to the trip id
      // it asked about, and drops one that arrives after it has moved on.
      final repo = _SlowContactRepository();
      final c = ContactController(repo);
      unawaited(c.load('trip-1'));
      // The second load supersedes the first before the first answers.
      unawaited(c.load('trip-2'));
      await repo.drain();
      expect(
        c.contact?.phone,
        '0550000000',
        reason: 'the answer for trip-2, not the one for trip-1',
      );
    });

    test(
      'clearing forgets the trip, so the next load is not skipped',
      () async {
        final c = ContactController(_StubContactRepository(_rider));
        await c.load('t1');
        c.clear();
        expect(c.contact, isNull);
        await c.load('t1');
        expect(
          c.contact,
          _rider,
          reason: 'the early return must not fire on a cleared controller',
        );
      },
    );

    test('a rider with no phone is asked about once, not once a poll', () async {
      // Found on a real handset: the shell calls `load` from a three-second timer,
      // and the guard used to be "same trip and we already have a contact". A rider
      // with no phone leaves `contact` null forever, so every poll re-ran the
      // lookup and the Call button pulsed between "Loading…" and "Call" for the
      // whole trip -- roughly twenty times a minute, on a live ride.
      final repo = _CountingContactRepository(null);
      final c = ContactController(repo);
      await c.load('t1');
      expect(repo.calls, 1);
      for (var i = 0; i < 40; i++) {
        await c.load('t1');
      }
      expect(
        repo.calls,
        1,
        reason: '"no contact" is an answer, so the poll must stop asking',
      );
      expect(c.busy, isFalse, reason: 'and it must not be left spinning');
    });

    test('a failed lookup is retried, so a network fault recovers', () async {
      // The counterpart to the test above, and the reason the fix is not just
      // "remember the trip id". A lookup that never answered must not be cached
      // forever, or a driver who loses signal at the pickup never gets the number.
      final repo = _FlakyContactRepository(_rider);
      final c = ContactController(repo);
      await c.load('t1');
      expect(c.contact, isNull, reason: 'the first attempt failed');
      expect(repo.calls, 1);
      await c.load('t1');
      expect(repo.calls, 2, reason: 'a failure is not an answer');
      expect(c.contact, _rider, reason: 'and the retry recovered');
    });
  });
}

/// Fire and forget, named so the tests read as intentions rather than as
/// forgotten futures. `dart:async`'s own `unawaited` would do the same thing, but
/// importing it for one call reads as though the file needed async at all.
void unawaited(Future<void> f) {}

class _StubContactRepository implements ContactRepository {
  _StubContactRepository(this.answer);

  final Contact? answer;

  @override
  Future<Contact?> contactFor(String tripId) async => answer;
}

class _FailingContactRepository implements ContactRepository {
  @override
  Future<Contact?> contactFor(String tripId) async {
    throw ContactFailure('Could not reach the contact service');
  }
}

/// Counts its calls, so a test can prove the shell's poll stopped asking.
///
/// The count is the whole point. Every other stub here can tell you what the
/// controller ended up with; only this one can tell you how often it went to the
/// network to get there, which is the thing that was actually broken.
class _CountingContactRepository implements ContactRepository {
  _CountingContactRepository(this.answer);

  final Contact? answer;
  int calls = 0;

  @override
  Future<Contact?> contactFor(String tripId) async {
    calls++;
    return answer;
  }
}

/// Fails once, then answers.
///
/// The other half of the "asked once" fix: a lookup that *threw* must stay
/// retryable, or a driver who loses signal between the match and the pickup never
/// gets the rider's number for the rest of the trip.
class _FlakyContactRepository implements ContactRepository {
  _FlakyContactRepository(this.answer);

  final Contact? answer;
  int calls = 0;

  @override
  Future<Contact?> contactFor(String tripId) async {
    calls++;
    if (calls == 1) throw ContactFailure('Could not reach the contact service');
    return answer;
  }
}

/// Answers the first call only after [drain], so a test can start a second
/// lookup while the first is still in flight.
class _SlowContactRepository implements ContactRepository {
  final _pending = <Completer<Contact?>>[];

  @override
  Future<Contact?> contactFor(String tripId) {
    final completer = Completer<Contact?>();
    _pending.add(completer);
    // The first trip answers with one number, the second with another, so a
    // controller that adopted the stale one is caught rather than merely
    // unlikely to be caught.
    final answer = Contact(
      role: ContactRole.rider,
      phone: tripId == 'trip-1' ? '0241234567' : '0550000000',
      callable: true,
      name: 'Rider',
    );
    completer.complete(answer);
    return completer.future;
  }

  Future<void> drain() async {
    for (final c in _pending) {
      // Already completed above; this exists so the test has a name for "wait for
      // the in-flight answers" rather than an arbitrary delay.
      await c.future;
    }
  }
}
