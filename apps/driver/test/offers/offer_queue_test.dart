import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';
import 'package:meetngo_driver/src/offers/offer_card.dart';
import 'package:meetngo_driver/src/offers/offer_queue_controller.dart';

import '../support/fakes.dart';
import '../support/harness.dart';

void main() {
  late StubDriverRepository repo;

  setUp(() => repo = StubDriverRepository());

  test('the newest offer is the head of the queue', () {
    final c = OfferQueueController(repo);
    c
      ..add(offer('a'))
      ..add(offer('b'));
    expect(c.offers.first.id, 'b');
    expect(c.offers, hasLength(2));
    expect(c.next!.id, 'b');
  });

  test('adding the same offer twice is idempotent', () {
    final c = OfferQueueController(repo);
    c
      ..add(offer('a'))
      ..add(offer('a'));
    expect(c.offers, hasLength(1));
  });

  test('an offer that is not pending is ignored', () {
    final c = OfferQueueController(repo)
      ..add(offer('a').copyWith(state: OfferState.accepted));
    expect(c.offers, isEmpty);
    expect(c.next, isNull);
  });

  test('accept removes the offer and reports success', () async {
    final c = OfferQueueController(repo)..add(offer('a'));
    expect(await c.accept(c.next!), isTrue);
    expect(repo.acceptedOfferIds, ['a']);
    expect(c.offers, isEmpty);
  });

  test('accepting asks the server about the exact offer that was shown', () async {
    final c = OfferQueueController(repo)
      ..add(offer('a'))
      ..add(offer('b'));
    await c.accept(c.next!);
    expect(repo.acceptedOfferIds, ['b']);
  });

  // A lost race is the ordinary outcome of five drivers and one trip, and the
  // offer may still be live -- the loss can be a transport fault. Dropping it
  // hides a trip the driver can still take.
  test('a losing accept returns false and keeps the offer for a retry',
      () async {
    repo.acceptLoses = true;
    final c = OfferQueueController(repo)..add(offer('a'));
    expect(await c.accept(c.next!), isFalse);
    expect(c.error, isNotNull);
    expect(c.offers.map((o) => o.id), ['a']);
  });

  test('the refusal reason from the server reaches the driver', () async {
    repo.acceptLoses = true;
    final c = OfferQueueController(repo)..add(offer('a'));
    await c.accept(c.next!);
    expect(c.error, 'That trip was taken by another driver');
  });

  test('decline removes the offer', () async {
    final c = OfferQueueController(repo)..add(offer('a'));
    await c.decline(c.next!);
    expect(repo.declinedOfferIds, ['a']);
    expect(c.offers, isEmpty);
  });

  // The plan removed the offer only on success, so a decline whose network call
  // failed left a declined offer on screen with a live countdown, inviting the
  // driver to press the wrong button. Intent was clear; the row is not coming
  // back either way.
  test('a failed decline still removes the offer and says why', () async {
    repo.declineSucceeds = false;
    final c = OfferQueueController(repo)..add(offer('a'));
    await c.decline(c.next!);
    expect(c.offers, isEmpty);
    expect(c.error, isNotNull);
  });

  // The 20-second TTL is `kOfferTtl` in `mng_core` and is not configurable. The
  // server has no sweeper, so an offer past `expires_at` is still `pending` in
  // the database until somebody acts on it.
  test('tick drops expired offers and keeps live ones', () {
    final c = OfferQueueController(repo)
      ..add(offer('live'))
      ..add(offer('dead', ttl: const Duration(seconds: -1)));
    c.tick();
    expect(c.offers.map((o) => o.id), ['live']);
  });

  test('a tick that changes nothing does not notify', () {
    final c = OfferQueueController(repo)..add(offer('live'));
    var notifications = 0;
    c.addListener(() => notifications++);
    c.tick();
    expect(notifications, 0);
  });

  test('a tick that drops one does notify', () {
    final c = OfferQueueController(repo)
      ..add(offer('dead', ttl: const Duration(seconds: -1)));
    var notifications = 0;
    c.addListener(() => notifications++);
    c.tick();
    expect(notifications, 1);
  });

  // The TTL is a constant in `mng_core` and nothing in this app can change it.
  // `secondsRemaining` truncates rather than rounds, so a freshly built offer
  // reads 19 or 20 depending on where in the second the assertion lands; what
  // is pinned here is the boundary, not the reading of a moving clock.
  test('the TTL really is 20 seconds and is not configurable', () {
    expect(kOfferTtl, const Duration(seconds: 20));
    expect(offer('a').isExpired, isFalse);
    expect(
      offer('a', ttl: kOfferTtl - const Duration(milliseconds: 1)).isExpired,
      isFalse,
      reason: 'one millisecond inside the window is still live',
    );
    expect(
      offer('a', ttl: const Duration(milliseconds: -1)).isExpired,
      isTrue,
      reason: 'one millisecond outside it is not',
    );
  });

  // Truncation, not rounding, and pinned on a value that is not a boundary.
  //
  // This used to assert that a freshly built 20-second offer read 19, on the
  // reasoning that `expiresAt - now` is 19.99... seconds. That is true in
  // principle and false on Windows: `DateTime.now()` has roughly 15.6 ms
  // granularity, so the two reads that build the offer and query it return the
  // *same* instant almost every time. Measured on the machine this suite runs
  // on, 1999 of 2000 consecutive `DateTime.now()` pairs were identical. The
  // difference is then exactly 20 s, truncation of 20.0 is 20, and the test
  // failed with `Expected: <19> Actual: <20>` while the code under test was
  // right.
  //
  // 19.5 s is the same property without the boundary: it truncates to 19 and
  // rounds to 20, so it fails if `secondsRemaining` ever grows a `.round()`,
  // and the half-second of slack absorbs any clock granularity. 1.5 s pins the
  // same thing on the other side of zero.
  test('the countdown truncates rather than rounds', () {
    expect(
      offer('a', ttl: const Duration(milliseconds: 19500)).secondsRemaining,
      19,
      reason: '19.5s truncates to 19; rounding would say 20',
    );
    expect(
      offer('a', ttl: const Duration(milliseconds: 1500)).secondsRemaining,
      1,
      reason: '1.5s truncates to 1; rounding would say 2',
    );
  });

  testWidgets('the card shows a whole-number countdown, never a decimal',
      (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(appHarness(
      Scaffold(body: OfferCard(offer: offer('a'), onAccept: () {}, onDecline: () {})),
    ));
    // Which second the first frame lands in is not pinnable -- building the
    // first frame of a test can take most of a second of real time, and the
    // value is a live reading of a clock that does not stop for tests. What is
    // pinned is the shape, the range, and that it is strictly under the TTL.
    final pill = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .firstWhere((s) => s.endsWith('s'));
    expect(pill, matches(RegExp(r'^\d{1,2}s$')));
    expect(int.parse(pill.substring(0, pill.length - 1)), lessThan(20));
    expect(int.parse(pill.substring(0, pill.length - 1)), greaterThan(10));
  });

  test('clear empties the queue', () {
    final c = OfferQueueController(repo)
      ..add(offer('a'))
      ..add(offer('b'));
    c.clear();
    expect(c.offers, isEmpty);
  });

  test('the queue cannot be written through the getter', () {
    final c = OfferQueueController(repo)..add(offer('a'));
    expect(() => c.offers.add(offer('b')), throwsUnsupportedError);
  });

  testWidgets('the card shows the fare, the distance and the countdown',
      (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(appHarness(
      Scaffold(body: OfferCard(offer: offer('a'), onAccept: () {}, onDecline: () {})),
    ));
    expect(find.textContaining('GHS 12.50'), findsOneWidget);
    expect(find.textContaining('800 m'), findsOneWidget);
    expect(find.byKey(const Key('acceptOfferButton')), findsOneWidget);
    expect(find.byKey(const Key('declineOfferButton')), findsOneWidget);
    expect(find.byKey(const Key('offer-a')), findsOneWidget);
  });

  testWidgets('an expired card cannot be accepted', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(appHarness(
      Scaffold(
        body: OfferCard(
          offer: offer('a', ttl: const Duration(seconds: -1)),
          onAccept: () {},
          onDecline: () {},
        ),
      ),
    ));
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('acceptOfferButton')),
    );
    expect(button.onPressed, isNull);
    expect(find.text('Offer expired'), findsOneWidget);
  });

  testWidgets('a declined offer can still be declined', (tester) async {
    useDesignSurface(tester);
    var declined = 0;
    await tester.pumpWidget(appHarness(
      Scaffold(
        body: OfferCard(
          offer: offer('a', ttl: const Duration(seconds: -1)),
          onAccept: () {},
          onDecline: () => declined++,
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('declineOfferButton')));
    expect(declined, 1);
  });

  testWidgets('accept and decline callbacks fire', (tester) async {
    useDesignSurface(tester);
    var accepted = 0;
    var declined = 0;
    await tester.pumpWidget(appHarness(
      Scaffold(
        body: OfferCard(
          offer: offer('a'),
          onAccept: () => accepted++,
          onDecline: () => declined++,
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('acceptOfferButton')));
    await tester.tap(find.byKey(const Key('declineOfferButton')));
    expect(accepted, 1);
    expect(declined, 1);
  });

  testWidgets('the distance is rounded to whole metres, not truncated',
      (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(appHarness(
      Scaffold(
        body: OfferCard(
          offer: offer('a', pickupDistanceKm: 0.8006),
          onAccept: () {},
          onDecline: () {},
        ),
      ),
    ));
    expect(find.textContaining('801 m'), findsOneWidget);
  });

  testWidgets('the card is keyed by the offer id', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(appHarness(
      Scaffold(body: OfferCard(offer: offer('xyz-1'), onAccept: () {}, onDecline: () {})),
    ));
    expect(find.byKey(const Key('offer-xyz-1')), findsOneWidget);
  });
}
