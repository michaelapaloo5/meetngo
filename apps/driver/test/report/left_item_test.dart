import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_driver/src/report/left_item_controller.dart';
import 'package:meetngo_driver/src/report/left_item_sheet.dart';

import '../support/harness.dart';

/// Report something the rider left in the car.
///
/// A report is read by a member of staff who will take it seriously, and the
/// driver writes it in thirty seconds in a car park. So what is worth pinning is
/// not the layout: it is that the form can be sent with almost nothing in it, that
/// a correction replaces the first account rather than adding a second row, and
/// that the employee columns are never something the app sends.

/// A repository the test drives. Top level because Dart will not declare a class
/// inside a function.
class FakeLeftItem implements LeftItemRepository {
  FakeLeftItem({this.stored, this.saveError, this.readError});

  LeftItemReport? stored;
  Object? saveError;
  Object? readError;

  final List<({String item, String description})> saves = [];

  @override
  Future<LeftItemReport?> reportFor(String tripId) async {
    final error = readError;
    if (error != null) throw error;
    return stored;
  }

  @override
  Future<LeftItemReport> save({
    required String tripId,
    required String item,
    required String description,
  }) async {
    final error = saveError;
    if (error != null) throw error;
    saves.add((item: item, description: description));
    stored = LeftItemReport(
      id: 'r1',
      tripId: tripId,
      item: item,
      description: description,
      status: 'open',
      staffNote: '',
      createdAt: DateTime.utc(2026, 9, 30, 12),
    );
    return stored!;
  }
}

void main() {
  LeftItemReport report({
    String item = 'Blue rucksack',
    String description = 'In the boot',
    String status = 'open',
    String staffNote = '',
  }) => LeftItemReport(
    id: 'r1',
    tripId: 't1',
    item: item,
    description: description,
    status: status,
    staffNote: staffNote,
    createdAt: DateTime.utc(2026, 9, 30, 12),
  );

  LeftItemController controller({FakeLeftItem? repo}) =>
      LeftItemController(tripId: 't1')..repository = repo ?? FakeLeftItem();

  Future<void> openSheet(
    WidgetTester tester,
    LeftItemController c,
  ) async {
    await tester.pumpWidget(
      appHarness(
        Scaffold(body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => LeftItemSheet.show(context, c),
              child: const Text('open'),
            ),
          ),
        )),
      ),
    );
    await tester.tap(find.text('open'));
    // Two pumps: the sheet route animates in, and its `initState` schedules a
    // post-frame `load`. Bounded rather than settling, because the item field is
    // autofocused and its cursor never stops blinking.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
  }

  group('the rules about what may be filed', () {
    test('an empty item is not sendable', () {
      expect(
        LeftItemController.isSendable(item: '', description: 'somewhere'),
        isFalse,
      );
      expect(
        LeftItemController.isSendable(item: '   ', description: ''),
        isFalse,
        reason: 'whitespace is not an item',
      );
    });

    test('an item with no description is sendable', () {
      // "Her blue bag" is a complete report. Insisting on a second sentence only
      // produces "yes".
      expect(LeftItemController.isSendable(item: 'Her blue bag', description: ''), isTrue);
    });

    test('the limits are the check constraints on the table', () {
      expect(
        LeftItemController.problemFor(item: 'a' * 201, description: ''),
        contains('200'),
      );
      expect(
        LeftItemController.problemFor(item: 'x', description: 'a' * 1001),
        contains('1000'),
      );
    });

    test('a problem is a sentence, not a flag', () {
      expect(LeftItemController.problemFor(item: '', description: ''), 'What was left behind?');
    });
  });

  group('loading', () {
    test('reads the trip own report', () async {
      final repo = FakeLeftItem(stored: report());
      final c = controller(repo: repo);
      await c.load();
      expect(c.report?.item, 'Blue rucksack');
      expect(c.hasReported, isTrue);
      // The button says "update" rather than "send", because a second report for
      // one trip is a constraint violation and a driver should never be offered
      // one.
      expect(c.actionLabel, 'Update report');
    });

    test('no report is a normal state, not a fault', () async {
      final c = controller();
      await c.load();
      expect(c.report, isNull);
      expect(c.hasReported, isFalse);
      expect(c.problem, isNull);
      expect(c.actionLabel, 'Send report');
    });

    test('a failed read is a fault and says so', () async {
      final c = controller(repo: FakeLeftItem(readError: const LeftItemFailure('no')));
      await c.load();
      expect(c.problem, 'no');
    });

    test('no repository is a fault, not "nothing filed"', () async {
      final c = LeftItemController(tripId: 't1');
      await c.load();
      // Both answer "there is no report", and only one of them is true.
      expect(c.report, isNull);
      expect(c.problem, isNotNull);
    });
  });

  group('saving', () {
    test('sends the trimmed text', () async {
      final repo = FakeLeftItem();
      final c = controller(repo: repo);
      expect(await c.save(item: '  Blue bag  ', description: '  In the boot  '), isTrue);
      expect(repo.saves.single.item, 'Blue bag');
      expect(repo.saves.single.description, 'In the boot');
    });

    test('adopts the row that came back', () async {
      final c = controller();
      await c.save(item: 'Blue bag', description: 'In the boot');
      // Without this the driver sees their own description in the field and an
      // empty card underneath until the next load, which reads as "not saved".
      expect(c.report?.item, 'Blue bag');
      expect(c.hasReported, isTrue);
    });

    test('a refused save says so and saves nothing', () async {
      final repo = FakeLeftItem(saveError: const LeftItemFailure('Could not reach the server.'));
      final c = controller(repo: repo);
      expect(await c.save(item: 'Blue bag', description: ''), isFalse);
      expect(c.problem, 'Could not reach the server.');
      expect(c.report, isNull);
    });

    test('an unsendable item is refused without touching the repository', () async {
      final repo = FakeLeftItem();
      final c = controller(repo: repo);
      expect(await c.save(item: '  ', description: ''), isFalse);
      expect(repo.saves, isEmpty);
    });

    test('clears a previous failure on the next success', () async {
      final repo = FakeLeftItem(saveError: const LeftItemFailure('nope'));
      final c = controller(repo: repo);
      await c.save(item: 'a', description: '');
      expect(c.problem, isNotNull);
      repo.saveError = null;
      await c.save(item: 'a', description: '');
      expect(c.problem, isNull);
    });
  });

  group('the state the driver is shown', () {
    test('open with no note is "nobody has got it yet"', () {
      expect(report().stateLabel, 'Nobody has got it yet');
    });

    test('returned says so plainly', () {
      expect(report(status: 'returned').stateLabel, 'Handed back');
    });

    test('a note from staff means answered, not returned', () {
      // Three states, not two: "answered" and "handed back" are different news
      // for somebody waiting for a lost phone, and collapsing them tells the
      // driver the item is back when an employee has only said they will look.
      expect(report(staffNote: 'Calling the rider now').stateLabel, 'Answered');
    });
  });

  group('the sheet', () {
    testWidgets('opens empty when nothing has been reported', (tester) async {
      useDesignSurface(tester);
      await openSheet(tester, controller());

      expect(find.byKey(const Key('leftItemField')), findsOneWidget);
      expect(find.text('Something left behind?'), findsOneWidget);
      // Not an empty card: an absence has to read as an absence.
      expect(find.byKey(const Key('leftItemStatus')), findsNothing);
    });

    testWidgets('the copy does not accuse', (tester) async {
      useDesignSurface(tester);
      await openSheet(tester, controller());

      // "Somebody" rather than "the rider". A driver who is not certain whose it
      // was has to be able to send this, and the wording is what lets them.
      expect(find.textContaining('somebody left'), findsOneWidget);
      expect(find.textContaining('the rider lost'), findsNothing);
    });

    testWidgets('the description is optional and says so', (tester) async {
      useDesignSurface(tester);
      await openSheet(tester, controller());
      expect(find.text('Optional, but it helps'), findsOneWidget);
    });

    testWidgets('the send button needs an item', (tester) async {
      useDesignSurface(tester);
      await openSheet(tester, controller());

      bool enabled() =>
          tester.widget<FilledButton>(find.byKey(const Key('leftItemSendButton'))).onPressed !=
          null;
      expect(enabled(), isFalse);

      await tester.enterText(find.byKey(const Key('leftItemField')), 'Blue bag');
      await tester.pump();
      expect(enabled(), isTrue);
    });

    testWidgets('an existing report is shown, with the form seeded from it', (
      tester,
    ) async {
      useDesignSurface(tester);
      await openSheet(
        tester,
        controller(
          repo: FakeLeftItem(
            stored: report(item: 'Blue rucksack', description: 'In the boot'),
          ),
        ),
      );

      // Seeded rather than blank, so fixing a typo is an edit rather than a fresh
      // report an employee has to reconcile with the first.
      final item = tester.widget<TextField>(find.byKey(const Key('leftItemField')));
      expect(item.controller?.text, 'Blue rucksack');
      final description =
          tester.widget<TextField>(find.byKey(const Key('leftItemDescriptionField')));
      expect(description.controller?.text, 'In the boot');
      expect(find.text('Your report'), findsOneWidget);
    });

    testWidgets('the employee answer is shown verbatim', (tester) async {
      useDesignSurface(tester);
      await openSheet(
        tester,
        controller(
          repo: FakeLeftItem(
            stored: report(
              status: 'returned',
              staffNote: 'Rider collected it, it was in the boot',
            ),
          ),
        ),
      );

      expect(find.byKey(const Key('leftItemStateLabel')), findsOneWidget);
      expect(find.text('Handed back'), findsOneWidget);
      // Verbatim and attributed. A driver told "answered" with nothing under it
      // has been told nothing.
      expect(find.byKey(const Key('leftItemStaffNote')), findsOneWidget);
      expect(find.text('Rider collected it, it was in the boot'), findsOneWidget);
    });

    testWidgets('a failed save is shown and the text is kept', (tester) async {
      useDesignSurface(tester);
      final repo = FakeLeftItem(saveError: const LeftItemFailure('Could not reach the server.'));
      await openSheet(tester, controller(repo: repo));

      await tester.enterText(find.byKey(const Key('leftItemField')), 'Blue bag');
      await tester.pump();
      await tester.tap(find.byKey(const Key('leftItemSendButton')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byKey(const Key('leftItemProblem')), findsOneWidget);
      expect(find.text('Could not reach the server.'), findsOneWidget);
      // Still on the sheet, with what they typed. Clearing the field after a
      // failed send makes them retype it.
      final item = tester.widget<TextField>(find.byKey(const Key('leftItemField')));
      expect(item.controller?.text, 'Blue bag');
    });

    testWidgets('a successful send closes the sheet with the report', (tester) async {
      useDesignSurface(tester);
      final repo = FakeLeftItem();
      await openSheet(tester, controller(repo: repo));

      await tester.enterText(find.byKey(const Key('leftItemField')), 'Blue bag');
      await tester.pump();
      await tester.tap(find.byKey(const Key('leftItemSendButton')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(repo.saves.single.item, 'Blue bag');
      expect(find.byKey(const Key('leftItemField')), findsNothing);
    });

    testWidgets('the item field uses a sentence keyboard and a sensible cap', (
      tester,
    ) async {
      useDesignSurface(tester);
      await openSheet(tester, controller());

      final field = tester.widget<TextField>(find.byKey(const Key('leftItemField')));
      // Sentences, because a driver is writing "Blue rucksack, black straps".
      expect(field.textCapitalization, TextCapitalization.sentences);
      // 200 is the table's `check`, so the field and the database agree.
      expect(field.maxLength, LeftItemController.kMaxItem);
    });
  });
}