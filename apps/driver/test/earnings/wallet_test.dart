import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_driver/src/earnings/earnings_controller.dart';
import 'package:meetngo_driver/src/earnings/earnings_repository.dart';
import 'package:meetngo_driver/src/earnings/wallet_screen.dart';
import 'package:provider/provider.dart';

import '../support/fakes.dart';
import '../support/harness.dart';

Widget wrap(EarningsController c) => appHarness(
      ChangeNotifierProvider<EarningsController>.value(
        value: c,
        child: const WalletScreen(),
      ),
    );

void main() {
  late StubEarningsRepository repo;

  setUp(() => repo = StubEarningsRepository());

  group('EarningsSnapshot', () {
    // Commission is written by `complete-trip` as a negative `commission` row, so
    // subtracting it from the available balance is the same arithmetic the
    // settlement did. The plan's `fromLedger` skipped commission entirely -- its
    // `if` branch added to `lifetime` and not to `available` -- so a driver
    // whose fare was 17.34 and whose commission was 3.06 was shown 17.34
    // available. Run against the plan's own arithmetic this is what comes out,
    // and the plan's own test expected 14.28.
    test('a commission reduces the available balance', () {
      final s = EarningsSnapshot.fromLedger([
        ledgerEntry('1', 'fare', 17.34),
        ledgerEntry('2', 'commission', -3.06),
      ]);
      expect(s.availableGhs, closeTo(14.28, 0.001));
      expect(s.lifetimeGhs, closeTo(14.28, 0.001));
    });

    test('compensation is available to the driver', () {
      final s = EarningsSnapshot.fromLedger([ledgerEntry('1', 'compensation', 5.0)]);
      expect(s.availableGhs, closeTo(5.0, 0.001));
    });

    test('a bonus is available to the driver', () {
      final s = EarningsSnapshot.fromLedger([ledgerEntry('1', 'bonus', 2.5)]);
      expect(s.availableGhs, closeTo(2.5, 0.001));
    });

    // A void is the settlement reversing a charge. It must not continue past
    // zero into a balance the driver has never earned.
    test('a void zeroes the balance rather than going negative', () {
      final s = EarningsSnapshot.fromLedger([
        ledgerEntry('1', 'fare', 17.34),
        ledgerEntry('2', 'void', -17.34),
      ]);
      expect(s.availableGhs, 0.0);
      expect(s.lifetimeGhs, 0.0);
    });

    // The case above cannot tell "a void zeroes" from "a void subtracts", because
    // a void of exactly the fare leaves 0.00 either way. Mutation-checked: with
    // the void branch removed, this test still passed. This one cannot, because
    // the void is not the fare's amount.
    test('a void zeroes the whole balance, not just its own amount', () {
      final s = EarningsSnapshot.fromLedger([
        ledgerEntry('1', 'fare', 17.34),
        ledgerEntry('2', 'void', -5.00),
      ]);
      expect(
        s.availableGhs,
        0.0,
        reason: '17.34 less 5.00 would leave 12.34 if a void only subtracted',
      );
      expect(s.lifetimeGhs, closeTo(12.34, 0.001));
    });

    test('a void never leaves a negative balance', () {
      final s = EarningsSnapshot.fromLedger([
        ledgerEntry('1', 'void', -17.34),
      ]);
      expect(s.availableGhs, 0.0);
    });

    test('an empty ledger is a zeroed wallet, not a null', () {
      final s = EarningsSnapshot.fromLedger([]);
      expect(s.availableGhs, 0.0);
      expect(s.lifetimeGhs, 0.0);
      expect(s.entries, isEmpty);
    });

    // `complete-trip` writes the fare at the moment the trip completes, so
    // there is no unsettled interval for a "pending" figure to describe. It is
    // a tile and it is zero, rather than a number invented to fill it.
    test('nothing is ever pending in this build', () {
      final s = EarningsSnapshot.fromLedger([ledgerEntry('1', 'fare', 10.0)]);
      expect(s.pendingGhs, 0.0);
    });

    test('balances are rounded to two places, as cedis are', () {
      final s = EarningsSnapshot.fromLedger([
        ledgerEntry('1', 'fare', 0.1),
        ledgerEntry('2', 'fare', 0.2),
      ]);
      expect(s.availableGhs, 0.3);
    });

    test('the five ledger kinds the database allows are all handled', () {
      for (final kind in ['fare', 'commission', 'compensation', 'void', 'bonus']) {
        final s = EarningsSnapshot.fromLedger([ledgerEntry('1', kind, 4.0)]);
        expect(s.availableGhs, greaterThanOrEqualTo(0.0), reason: kind);
        expect(s.lifetimeGhs, closeTo(4.0, 0.001), reason: kind);
      }
    });
  });

  group('EarningsController', () {
    test('load populates the snapshot', () async {
      repo.rows = [
        ledgerEntry('1', 'fare', 17.34),
        ledgerEntry('2', 'commission', -3.06),
      ];
      final c = EarningsController(repo);
      await c.load();
      expect(c.snapshot!.availableGhs, closeTo(14.28, 0.001));
    });

    test('a failed ledger read is shown and leaves no snapshot', () async {
      repo.failLedger = true;
      final c = EarningsController(repo);
      await c.load();
      expect(c.error, 'Could not read your ledger');
      expect(c.snapshot, isNull);
      expect(c.busy, isFalse);
    });

    test('a payout of zero is rejected before the network call', () async {
      final c = EarningsController(repo);
      expect(await c.requestPayout(0), isFalse);
      expect(repo.payouts, isEmpty);
      expect(c.error, 'Enter an amount greater than zero');
    });

    test('a negative payout is rejected before the network call', () async {
      repo.rows = [ledgerEntry('1', 'fare', 20.0)];
      final c = EarningsController(repo);
      await c.load();
      expect(await c.requestPayout(-5), isFalse);
      expect(repo.payouts, isEmpty);
    });

    test('a payout above the available balance is rejected', () async {
      repo.rows = [ledgerEntry('1', 'fare', 10.0)];
      final c = EarningsController(repo);
      await c.load();
      expect(await c.requestPayout(25.0), isFalse);
      expect(c.error, contains('You only have GHS 10.00 available'));
      expect(repo.payouts, isEmpty);
    });

    test('a payout with no snapshot at all is rejected', () async {
      final c = EarningsController(repo);
      expect(await c.requestPayout(1.0), isFalse);
      expect(repo.payouts, isEmpty);
    });

    // The plan called `load()` after a payout. That is the same read that
    // produced the balance being spent; the ledger had not changed, so the
    // balance snapped back to its full amount under a "requested" message. Run
    // against the plan's own arithmetic, withdrawing 20 from a ledger of 20 ends
    // at 20.0, and the plan's own test expected 0.0.
    test('a valid payout is requested and the balance drops', () async {
      repo.rows = [ledgerEntry('1', 'fare', 20.0)];
      final c = EarningsController(repo);
      await c.load();
      expect(await c.requestPayout(20.0), isTrue);
      expect(repo.payouts, [20.0]);
      expect(c.snapshot!.availableGhs, 0.0);
    });

    test('a partial payout leaves the remainder', () async {
      repo.rows = [ledgerEntry('1', 'fare', 20.0)];
      final c = EarningsController(repo);
      await c.load();
      expect(await c.requestPayout(7.5), isTrue);
      expect(c.snapshot!.availableGhs, closeTo(12.5, 0.001));
    });

    // A second withdrawal cannot spend the same money twice, which is the whole
    // point of dropping the balance.
    test('the balance after a payout is the one the next payout is checked against',
        () async {
      repo.rows = [ledgerEntry('1', 'fare', 20.0)];
      final c = EarningsController(repo);
      await c.load();
      await c.requestPayout(15.0);
      expect(await c.requestPayout(15.0), isFalse);
      expect(repo.payouts, [15.0]);
      expect(c.error, contains('You only have GHS 5.00 available'));
    });

    test('a failed payout surfaces the reason and keeps the balance', () async {
      repo.rows = [ledgerEntry('1', 'fare', 20.0)];
      repo.failPayout = true;
      final c = EarningsController(repo);
      await c.load();
      expect(await c.requestPayout(20.0), isFalse);
      expect(c.error, 'Payouts are paused right now');
      expect(c.snapshot!.availableGhs, closeTo(20.0, 0.001));
    });

    test('a withdrawal does not change what the driver has earned', () async {
      repo.rows = [ledgerEntry('1', 'fare', 20.0)];
      final c = EarningsController(repo);
      await c.load();
      await c.requestPayout(20.0);
      expect(c.snapshot!.lifetimeGhs, closeTo(20.0, 0.001));
    });

    test('the controller tells its listeners', () async {
      repo.rows = [ledgerEntry('1', 'fare', 5.0)];
      final c = EarningsController(repo);
      var notifications = 0;
      c.addListener(() => notifications++);
      await c.load();
      await c.requestPayout(1.0);
      expect(notifications, greaterThan(1));
    });
  });

  testWidgets('the wallet shows the three balances', (tester) async {
    useDesignSurface(tester);
    final c = EarningsController(repo)
      ..snapshot = EarningsSnapshot.fromLedger([ledgerEntry('1', 'fare', 17.34)]);
    await tester.pumpWidget(wrap(c));
    expect(find.byKey(const Key('availableBalance')), findsOneWidget);
    expect(find.byKey(const Key('pendingBalance')), findsOneWidget);
    expect(find.byKey(const Key('lifetimeEarnings')), findsOneWidget);
    expect(find.text('GHS 17.34'), findsNWidgets(2), reason: 'available and lifetime');
    expect(find.text('GHS 0.00'), findsOneWidget, reason: 'pending is always zero');
  });

  testWidgets('the wallet is built by the controller, not by a hard-coded zero',
      (tester) async {
    useDesignSurface(tester);
    final c = EarningsController(repo);
    await tester.pumpWidget(wrap(c));
    expect(find.text('GHS 0.00'), findsNWidgets(3));
    expect(find.text('No earnings yet'), findsOneWidget);
  });

  testWidgets('the withdraw button opens the mock MoMo sheet', (tester) async {
    useDesignSurface(tester);
    final c = EarningsController(repo)
      ..snapshot = EarningsSnapshot.fromLedger([ledgerEntry('1', 'fare', 17.34)]);
    await tester.pumpWidget(wrap(c));

    await tester.tap(find.byKey(const Key('payoutButton')));
    await tester.pumpAndSettle();

    expect(find.text('Withdraw to MoMo'), findsOneWidget);
    expect(find.byKey(const Key('payoutAmountField')), findsOneWidget);
    expect(find.byKey(const Key('confirmPayoutButton')), findsOneWidget);
    expect(find.byKey(const Key('payoutPinField')), findsOneWidget);
  });

  // A PIN box that is collected and thrown away is the one control on the sheet
  // a driver could mistake for a real payment, so the copy has to say what it is.
  testWidgets('the sheet says no money moves and the PIN is unchecked',
      (tester) async {
    useDesignSurface(tester);
    final c = EarningsController(repo)
      ..snapshot = EarningsSnapshot.fromLedger([ledgerEntry('1', 'fare', 17.34)]);
    await tester.pumpWidget(wrap(c));
    await tester.tap(find.byKey(const Key('payoutButton')));
    await tester.pumpAndSettle();
    expect(find.textContaining('No money moves'), findsOneWidget);
    expect(find.textContaining('not checked against anything'), findsOneWidget);
  });

  testWidgets('a zero-balance wallet disables the withdraw button',
      (tester) async {
    useDesignSurface(tester);
    final c = EarningsController(repo)
      ..snapshot = EarningsSnapshot.fromLedger([]);
    await tester.pumpWidget(wrap(c));
    final button = tester.widget<FilledButton>(find.byKey(const Key('payoutButton')));
    expect(button.onPressed, isNull);
  });

  testWidgets('the ledger rows render with their kind and amount',
      (tester) async {
    useDesignSurface(tester);
    final c = EarningsController(repo)
      ..snapshot = EarningsSnapshot.fromLedger([
        ledgerEntry('1', 'fare', 17.34),
        ledgerEntry('2', 'compensation', 5.0),
      ]);
    await tester.pumpWidget(wrap(c));
    expect(find.byKey(const Key('ledgerRow-1')), findsOneWidget);
    expect(find.byKey(const Key('ledgerRow-2')), findsOneWidget);
    expect(find.text('Trip fare'), findsOneWidget);
    expect(find.text('Cancellation compensation'), findsOneWidget);
    expect(find.text('+GHS 17.34'), findsOneWidget);
    expect(find.text('+GHS 5.00'), findsOneWidget);
  });

  testWidgets('a negative ledger row reads as a subtraction', (tester) async {
    useDesignSurface(tester);
    final c = EarningsController(repo)
      ..snapshot = EarningsSnapshot.fromLedger([
        ledgerEntry('1', 'commission', -3.06),
      ]);
    await tester.pumpWidget(wrap(c));
    expect(find.text('-GHS 3.06'), findsOneWidget);
  });

  // `kind` is one of exactly five values -- the check constraint on
  // `ledger_entries.kind` (`init.sql:126`) -- so a sixth kind in the table would
  // be a value the database cannot store, and a missing one would be a kind the
  // wallet renders as its raw wire value.
  testWidgets('all five ledger kinds have a label a driver can read',
      (tester) async {
    useDesignSurface(tester);
    const labels = {
      'fare': 'Trip fare',
      'commission': 'Platform commission',
      'compensation': 'Cancellation compensation',
      'void': 'Voided charge',
      'bonus': 'Bonus',
    };
    for (final entry in labels.entries) {
      final c = EarningsController(repo)
        ..snapshot = EarningsSnapshot.fromLedger([
          ledgerEntry('1', entry.key, 1.0),
        ]);
      await tester.pumpWidget(wrap(c));
      expect(find.text(entry.value), findsOneWidget, reason: entry.key);
      expect(find.text(entry.key), findsNothing, reason: entry.key);
    }
  });

  testWidgets('the sheet reports a payout it refused', (tester) async {
    useDesignSurface(tester);
    repo.rows = [ledgerEntry('1', 'fare', 10.0)];
    repo.failPayout = true;
    final c = EarningsController(repo);
    await c.load();
    await tester.pumpWidget(wrap(c));
    await tester.tap(find.byKey(const Key('payoutButton')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('payoutAmountField')), '10');
    await tester.tap(find.byKey(const Key('confirmPayoutButton')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('payoutSent')), findsNothing);
    expect(find.text('Payouts are paused right now'), findsNWidgets(2));
  });

  testWidgets('the sheet reports a payout it made, and says it sent nothing',
      (tester) async {
    useDesignSurface(tester);
    repo.rows = [ledgerEntry('1', 'fare', 10.0)];
    final c = EarningsController(repo);
    await c.load();
    await tester.pumpWidget(wrap(c));
    await tester.tap(find.byKey(const Key('payoutButton')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('payoutAmountField')), '4');
    await tester.tap(find.byKey(const Key('confirmPayoutButton')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('payoutSent')), findsOneWidget);
    expect(find.textContaining('nothing was sent'), findsOneWidget);
  });

  testWidgets('an amount that is not a number is refused, not rounded',
      (tester) async {
    useDesignSurface(tester);
    repo.rows = [ledgerEntry('1', 'fare', 10.0)];
    final c = EarningsController(repo);
    await c.load();
    await tester.pumpWidget(wrap(c));
    await tester.tap(find.byKey(const Key('payoutButton')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('payoutAmountField')), 'abc');
    await tester.tap(find.byKey(const Key('confirmPayoutButton')));
    await tester.pumpAndSettle();

    expect(repo.payouts, isEmpty);
    expect(find.text('Enter an amount greater than zero'), findsNWidgets(2));
  });

  testWidgets('the sheet is a live view of the controller', (tester) async {
    useDesignSurface(tester);
    final c = EarningsController(repo)
      ..snapshot = EarningsSnapshot.fromLedger([ledgerEntry('1', 'fare', 5.0)]);
    await tester.pumpWidget(wrap(c));

    // A balance that only changed behind the screen's back would leave a stale
    // "Available" tile and a live button.
    c.snapshot = EarningsSnapshot.fromLedger([]);
    await tester.pumpAndSettle();
    expect(find.text('GHS 5.00'), findsNothing);

    final button = tester.widget<FilledButton>(find.byKey(const Key('payoutButton')));
    expect(button.onPressed, isNull);
  });
}
