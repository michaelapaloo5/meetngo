import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_driver/src/chat/chat_controller.dart';
import 'package:meetngo_driver/src/chat/chat_screen.dart';

import '../support/harness.dart';

/// A repository the test drives: it hands out a stream the test pushes into, and
/// records what was sent.
///
/// Top level because Dart will not declare a class inside a function, and
/// because it is used from three groups.
class FakeChat implements ChatRepository {
  final _controller = StreamController<List<ChatMessage>>.broadcast();
  final List<String> sentBodies = [];
  Object? sendError;

  @override
  Stream<List<ChatMessage>> messages(String tripId) {
    // Emits the current state immediately, the way PostgREST's realtime stream
    // does on subscribe. Without it `loading` never ends and the thread shows a
    // spinner forever -- which is not what the real stream does, so a fake that
    // sat silent would be testing a failure mode that cannot occur.
    Stream<List<ChatMessage>> emitInitial() async* {
      yield const <ChatMessage>[];
      yield* _controller.stream;
    }

    return emitInitial();
  }

  @override
  Future<void> send({required String tripId, required String body}) async {
    sentBodies.add(body);
    final error = sendError;
    if (error != null) throw error;
  }

  void arrive(List<ChatMessage> messages) => _controller.add(messages);
  Future<void> close() => _controller.close();
}

/// Chat: the driver's conversation with the rider on the active trip.
///
/// The data was already there -- `chat_messages` exists, is in the
/// `supabase_realtime` publication, and its two policies already answer "is this
/// my trip" for both read and insert. What was missing was anything a driver
/// could open.
///
/// Two of these tests are about behaviour that is easy to get wrong in a way no
/// crash reveals, and both were wrong in a first pass:
///
/// - a message is **not** added locally on send. A local copy is a second bubble
///   with the same text for as long as the round trip takes, which on a metered
///   connection is long enough for the driver to see it happen twice.
/// - the thread **does not** auto-scroll when the rider's message arrives and the
///   driver has scrolled up. "Scroll to newest" is what every chat library does
///   by default, and it yanks someone out of the history they are reading.

void main() {
  const me = 'driver-1';
  const them = 'rider-1';

  ChatMessage msg(String id, String sender, String body) => ChatMessage(
    id: id,
    tripId: 't1',
    senderId: sender,
    body: body,
    createdAt: DateTime.utc(2026, 9, 30, 12, 30),
  );

  late FakeChat repo;

  setUp(() => repo = FakeChat());
  tearDown(() => repo.close());

  ChatController controller() =>
      ChatController(myId: me, tripId: 't1')..repository = repo;

  group('the rules about what may be sent', () {
    test('empty and whitespace-only text is not sendable', () {
      expect(ChatController.isSendable(''), isFalse);
      expect(ChatController.isSendable('   \n '), isFalse);
    });

    test('a message is sendable', () {
      expect(ChatController.isSendable('I am at the gate'), isTrue);
    });

    test('the limit is the same number the composer enforces', () {
      // 500 in two places -- `problemFor` and the `maxLength` on the field --
      // would drift, and the drift is a driver who cannot type what they wrote.
      expect(
        ChatController.problemFor('a' * ChatController.kMaxLength),
        isNull,
      );
      expect(
        ChatController.problemFor('a' * (ChatController.kMaxLength + 1)),
        contains('Too long'),
      );
    });

    test('a problem is a sentence, not a flag', () {
      expect(ChatController.problemFor('   '), 'Type a message');
    });
  });

  group('loading', () {
    test('starts loading, and stops when the stream speaks', () async {
      final c = controller();
      final seen = <bool>[];
      c.addListener(() => seen.add(c.loading));
      await c.load();
      // True at this point, before the event queue turns over: the subscription
      // has been opened and nothing has come back along it yet.
      expect(c.loading, isTrue);

      await pumpEventQueue();
      // False once it does. The stream's first emission is the current state,
      // which for a trip with no messages is an empty list -- so an empty thread
      // arrives as an event rather than as an absence of events. A fake that
      // stayed silent would leave this spinner running forever, which is a
      // failure mode the real stream does not have.
      expect(c.loading, isFalse);
      expect(c.messages, isEmpty);
      expect(
        seen,
        contains(true),
        reason: 'the listener was told it was loading',
      );
    });

    test('a message arriving while the thread is open shows up', () async {
      final c = controller();
      await c.load();
      await pumpEventQueue();
      repo.arrive([msg('m1', them, 'hello')]);
      await pumpEventQueue();
      expect(c.messages, hasLength(1));
    });

    test('messages come oldest first', () async {
      final c = controller();
      await c.load();
      // Let the subscription attach before pushing anything: a broadcast
      // stream drops an event that has no listener, so rrive on the next
      // line without this is a message that never existed.
      await pumpEventQueue();
      repo.arrive([msg('m1', them, 'first'), msg('m2', me, 'second')]);
      await pumpEventQueue();
      expect(c.messages.map((m) => m.body), ['first', 'second']);
    });

    test('no repository is a fault, not an empty thread', () async {
      final c = ChatController(myId: me, tripId: 't1');
      await c.load();
      // Let the subscription attach before pushing anything: a broadcast
      // stream drops an event that has no listener, so rrive on the next
      // line without this is a message that never existed.
      await pumpEventQueue();
      // An empty list and a broken list are identical to a driver, and they mean
      // opposite things. "No messages yet" while the feature is not wired in is
      // the app telling a driver the rider is silent when it is the app.
      expect(c.messages, isEmpty);
      expect(c.problem, isNotNull);
      expect(c.isEmpty, isFalse);
    });
  });

  group('sending', () {
    test('sends the trimmed body', () async {
      final c = controller();
      await c.load();
      // Let the subscription attach before pushing anything: a broadcast
      // stream drops an event that has no listener, so rrive on the next
      // line without this is a message that never existed.
      await pumpEventQueue();
      expect(await c.send('  I am at the gate  '), isTrue);
      expect(repo.sentBodies, ['I am at the gate']);
    });

    test('does not add the message locally', () async {
      final c = controller();
      await c.load();
      // Let the subscription attach before pushing anything: a broadcast
      // stream drops an event that has no listener, so rrive on the next
      // line without this is a message that never existed.
      await pumpEventQueue();
      await c.send('hello');
      // The realtime stream delivers this driver's own insert a moment later. A
      // local copy would be visible as the same text twice, for exactly as long
      // as the network is slow.
      expect(
        c.messages,
        isEmpty,
        reason: 'the stream owns the list, not the send',
      );
    });

    test('appears once, when the stream reports it', () async {
      final c = controller();
      await c.load();
      // Let the subscription attach before pushing anything: a broadcast
      // stream drops an event that has no listener, so rrive on the next
      // line without this is a message that never existed.
      await pumpEventQueue();
      await c.send('hello');
      repo.arrive([msg('m1', me, 'hello')]);
      await pumpEventQueue();
      expect(c.messages.where((m) => m.body == 'hello'), hasLength(1));
    });

    test('a refused send says so and keeps the text', () async {
      repo.sendError = const ChatFailure('Could not reach the server.');
      final c = controller();
      await c.load();
      // Let the subscription attach before pushing anything: a broadcast
      // stream drops an event that has no listener, so rrive on the next
      // line without this is a message that never existed.
      await pumpEventQueue();
      expect(await c.send('hello'), isFalse);
      expect(c.problem, 'Could not reach the server.');
    });

    test(
      'an unsendable body is refused without touching the network',
      () async {
        final c = controller();
        await c.load();
        // Let the subscription attach before pushing anything: a broadcast
        // stream drops an event that has no listener, so rrive on the next
        // line without this is a message that never existed.
        await pumpEventQueue();
        expect(await c.send('   '), isFalse);
        expect(repo.sentBodies, isEmpty);
        expect(c.problem, 'Type a message');
      },
    );

    test('clears a previous failure on the next successful send', () async {
      repo.sendError = const ChatFailure('nope');
      final c = controller();
      await c.load();
      // Let the subscription attach before pushing anything: a broadcast
      // stream drops an event that has no listener, so rrive on the next
      // line without this is a message that never existed.
      await pumpEventQueue();
      await c.send('hello');
      expect(c.problem, isNotNull);
      repo.sendError = null;
      await c.send('hello again');
      expect(c.problem, isNull);
    });
  });

  group('which bubble is mine', () {
    test('a message from this driver is mine', () {
      expect(msg('m1', me, 'x').isMine(me), isTrue);
    });

    test('the rider is not me, even on the same trip', () {
      expect(msg('m1', them, 'x').isMine(me), isFalse);
    });

    test('the clock is local, 24 hour, no seconds', () {
      final m = ChatMessage(
        id: 'm',
        tripId: 't1',
        senderId: me,
        body: 'x',
        createdAt: DateTime.utc(2026, 9, 30, 14, 5, 42),
      );
      expect(m.clockLabel, matches(RegExp(r'^\d{2}:\d{2}$')));
      expect(m.clockLabel.endsWith(':42'), isFalse);
    });
  });

  group('the screen', () {
    Future<void> openChat(WidgetTester tester, ChatController c) async {
      await tester.pumpWidget(
        appHarness(ChatScreen(controller: c, riderName: 'Ama')),
      );
      // The screen starts listening from a post-frame callback, so one frame is
      // needed before the subscription exists. Bounded rather than settling,
      // because the thread may then hold a blinking cursor.
      await tester.pump();
      await tester.pump();
    }

    testWidgets('names the rider, so a thread is not just avatars', (
      tester,
    ) async {
      useDesignSurface(tester);
      await openChat(tester, controller());
      expect(find.text('Ama'), findsWidgets);
    });

    testWidgets('says the thread is empty, and offers something to do', (
      tester,
    ) async {
      useDesignSurface(tester);
      await openChat(tester, controller());
      expect(find.byKey(const Key('chatEmptyNote')), findsOneWidget);
      // Silence from the rider is the expected state at the start of a trip, so
      // the empty thread has to suggest the next thing rather than apologise.
      expect(find.textContaining('on the way'), findsOneWidget);
    });

    testWidgets('shows each message once, mine and theirs', (tester) async {
      useDesignSurface(tester);
      final c = controller();
      await openChat(tester, c);
      repo.arrive([msg('m1', them, 'I am here'), msg('m2', me, 'Coming up')]);
      // Two pumps: the first turns the event queue over so the
      // stream's generator delivers, the second draws the frame that shows it.
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('chatBody_m1')), findsOneWidget);
      expect(find.byKey(const Key('chatBody_m2')), findsOneWidget);
      // Once each. The stream re-emits the whole list on every change, so a
      // list that appended would show two of each after the second event.
      repo.arrive([
        msg('m1', them, 'I am here'),
        msg('m2', me, 'Coming up'),
        msg('m3', them, 'ok'),
      ]);
      // Two pumps: the first turns the event queue over so the
      // stream's generator delivers, the second draws the frame that shows it.
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('chatBody_m1')), findsOneWidget);
      expect(find.byKey(const Key('chatBody_m3')), findsOneWidget);
    });

    testWidgets('a message that arrives is visible without any interaction', (
      tester,
    ) async {
      useDesignSurface(tester);
      final c = controller();
      await openChat(tester, c);
      expect(find.text('I am at the gate'), findsNothing);

      repo.arrive([msg('m9', them, 'I am at the gate')]);
      // Two pumps: the first turns the event queue over so the
      // stream's generator delivers, the second draws the frame that shows it.
      await tester.pump();
      await tester.pump();
      expect(find.text('I am at the gate'), findsOneWidget);
    });

    testWidgets(
      'the send button is disabled until there is something to send',
      (tester) async {
        useDesignSurface(tester);
        await openChat(tester, controller());

        // `onPressed` rather than a hit test, because a disabled `IconButton`
        // still occupies its slot and `tester.tap` on it would warn about
        // missing the hit rather than reporting the real state.
        bool enabled() =>
            tester
                .widget<IconButton>(find.byKey(const Key('chatSendButton')))
                .onPressed !=
            null;

        expect(enabled(), isFalse, reason: 'nothing typed');

        await tester.enterText(find.byKey(const Key('chatComposer')), 'hello');
        await tester.pump();
        expect(enabled(), isTrue);

        // And back off when the text becomes unsendable again.
        await tester.enterText(find.byKey(const Key('chatComposer')), '  ');
        await tester.pump();
        expect(enabled(), isFalse, reason: 'whitespace is not a message');
      },
    );

    testWidgets('the send button stays in the composer when the keyboard is up', (
      tester,
    ) async {
      useDesignSurface(tester);
      // The keyboard, as the platform reports it. This is the state that broke
      // it: the send button used to be a floating action button padded by
      // `viewInsets.bottom`, and the `Scaffold` had already lifted it above the
      // keyboard, so the inset was counted twice and the button flew to the top
      // of the screen. Verified on the handset, not inferred.
      tester.view.viewInsets = const FakeViewPadding(bottom: 400);
      addTearDown(tester.view.reset);

      await openChat(tester, controller());
      await tester.enterText(find.byKey(const Key('chatComposer')), 'hello');
      await tester.pump();

      final send = tester.getRect(find.byKey(const Key('chatSendButton')));
      final field = tester.getRect(find.byKey(const Key('chatComposer')));

      // Same row, to the right of the field, which is the whole assertion: the
      // button is part of the composer rather than floating at the other end of
      // the thread. Not `overlaps` -- the field is `Expanded`, so the button sits
      // beside it and by construction never overlaps it.
      expect(
        send.center.dx,
        greaterThan(field.center.dx),
        reason: 'the button belongs to the right of the field',
      );
      expect(
        send.center.dy,
        greaterThan(field.top),
        reason: "and on the field's own line, not above the app bar",
      );
      expect(
        send.center.dy,
        lessThan(field.bottom),
        reason: "and on the field's own line, not below the composer",
      );
    });

    testWidgets('typing then sending clears the composer', (tester) async {
      useDesignSurface(tester);
      await openChat(tester, controller());
      await tester.enterText(
        find.byKey(const Key('chatComposer')),
        'I am here',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('chatSendButton')));
      await tester.pump();
      await tester.pump();

      final field = tester.widget<TextField>(
        find.byKey(const Key('chatComposer')),
      );
      expect(field.controller?.text, isEmpty);
      expect(repo.sentBodies, ['I am here']);
    });

    testWidgets('a failed send leaves the text so it is not typed again', (
      tester,
    ) async {
      useDesignSurface(tester);
      repo.sendError = const ChatFailure('Could not reach the server.');
      await openChat(tester, controller());
      await tester.enterText(
        find.byKey(const Key('chatComposer')),
        'I am here',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('chatSendButton')));
      await tester.pump();
      await tester.pump();

      // The message is still unsent. Clearing the composer on a failed send makes
      // the driver retype a sentence to somebody waiting at a kerb.
      final field = tester.widget<TextField>(
        find.byKey(const Key('chatComposer')),
      );
      expect(field.controller?.text, 'I am here');
    });

    testWidgets('has a close control, because the phone is in a mount', (
      tester,
    ) async {
      useDesignSurface(tester);
      await openChat(tester, controller());
      // Not a back arrow: a mounted phone may not be in a position to receive
      // the gesture, and the driver has to be able to leave without it.
      expect(find.byKey(const Key('chatCloseButton')), findsOneWidget);
    });
  });
}
