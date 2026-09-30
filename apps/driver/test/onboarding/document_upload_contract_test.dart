import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The `driver_documents` write path, against the constraints it has to satisfy.
///
/// ## Why this file reads source instead of calling the server
///
/// Because the bug it guards could not have been caught any other way, and the
/// reason is worth stating so nobody adds a "real" test and assumes this one is
/// redundant.
///
/// `unique (driver_id, kind)` means a second document of the same kind collides.
/// A driver replacing a blurry licence has to be able to, so the row is
/// upserted. But PostgREST's default conflict target is the table's **primary
/// key**, `id`, and the payload has no `id` -- so it took the INSERT branch, the
/// insert violated the unique constraint, and every second upload of every kind
/// failed.
///
/// The first upload of each kind worked, which is what kept it hidden: the
/// happy path *is* the first upload. The broken path is only reached by
/// deliberately replacing something, or by doing the face check twice. Both
/// happened on a real device before this was found, and the symptom -- "that
/// photo could not be saved" -- read like a network problem.
///
/// A test with a live Supabase client would have caught it, and would also have
/// been skipped on every machine that is not pointed at a project, which is
/// most of them. These read the two things that must agree and assert that they
/// do. If the repository is ever rewritten against a real client, these are the
/// assertions to carry over.
void main() {
  final repo = File('lib/src/data/supabase_driver_repository.dart');
  final migration = File(
    '../../supabase/migrations/20260929000002_driver_documents.sql',
  );

  String source() => repo.readAsStringSync();

  group('the constraint the write path has to satisfy', () {
    test('the migration really does make (driver_id, kind) unique', () {
      // If this stops being true the `onConflict` below is either wrong or
      // unnecessary, and both are worth knowing.
      expect(
        migration.existsSync(),
        isTrue,
        reason: 'migration not found at ${migration.path}',
      );
      final sql = migration.readAsStringSync();
      expect(
        sql,
        contains('unique (driver_id, kind)'),
        reason:
            'the unique constraint this test names has been renamed or dropped; '
            'check the migration before trusting the onConflict below',
      );
    });
  });

  group('the upsert', () {
    test('names the columns to conflict on, not just the primary key', () {
      // The regression, in one assertion. Without `onConflict` this call
      // resolves on `id`, finds nothing to match, inserts, and collides.
      final s = source();
      expect(
        s,
        contains("onConflict: 'driver_id,kind'"),
        reason:
            'the upsert must name the unique constraint explicitly; PostgREST '
            "defaults to the primary key ('id'), which this payload never sets, "
            'so omitting it makes every replacement of every document fail',
      );
    });

    test('is an upsert and not an insert', () {
      // The other half. A correct `onConflict` on an `insert` is not a thing, and
      // an `upsert` that has drifted away from the constraint is a write path
      // that has stopped being about the constraint.
      //
      // Matched across the payload rather than by a suffix, because the argument
      // list is several lines long and a suffix assertion would be checking the
      // formatting instead of the call.
      final s = source();
      final conflict = RegExp(
        r"upsert\(\s*\{[^}]*\}[^;]*onConflict: 'driver_id,kind'",
      );
      expect(
        conflict.hasMatch(s),
        isTrue,
        reason:
            'expected one upsert(...) call carrying both the payload and '
            "onConflict: 'driver_id,kind', so the conflict target belongs to "
            'the same call that writes the row',
      );
      expect(
        s,
        isNot(matches(RegExp(r"\.insert\(\s*\{\s*'driver_id'"))),
        reason: 'a plain insert cannot respect (driver_id, kind)',
      );
    });

    test('never sends an id, so the conflict target has to be named', () {
      // Why `onConflict` cannot be left to default. If a future edit adds `id`
      // to the payload this test fails, and the right response is to think about
      // whether the row should now be inserted rather than replaced -- not to
      // delete the assertion.
      final s = source();
      final start = s.indexOf("from('driver_documents')");
      expect(start, greaterThan(-1), reason: 'the write is gone or renamed');
      final block = s.substring(start, start + 600);
      expect(
        block,
        isNot(contains("'id'")),
        reason:
            'the payload sets no id, so the upsert can only work because '
            "onConflict names (driver_id, kind)",
      );
    });
  });
}
