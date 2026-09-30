import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The role a driver signup declares, and the three places that have to agree
/// about it.
///
/// ## Why this file reads source instead of calling the server
///
/// Because the bug it guards could not have been caught any other way, and the
/// reason is worth stating so nobody adds a "real" test and assumes this one is
/// redundant.
///
/// `handle_new_user` reads the role from `raw_user_meta_data` exactly once, at
/// signup. The driver app sent `{'full_name': ...}` and no `role` key, so
/// `handle_new_user` took the `else 'rider'` branch for every driver who ever
/// signed up. `guard_profile_update` then made `role` permanently immutable, so
/// there was no way back.
///
/// Nothing about that is visible from the app. A driver signs up, uploads all
/// seven documents, an employee compares them by eye and approves, and the
/// approval is real -- the row says `kyc_status = 'approved'`. The driver then
/// never receives a single offer, because `match_offers_for_trip` filters on
/// `d.role = 'driver'` and joins `vehicles` on `v.approved`. The app looks
/// completely healthy from the inside. There is no error, no empty state that
/// looks like a bug, and no log line; there is a person who passed every check
/// and cannot work.
///
/// A test with a live Supabase client would have caught it, and would also have
/// been skipped on every machine that is not pointed at a project, which is most
/// of them. These read the things that must agree and assert that they do. One
/// real pilot account was stuck in exactly this state -- seven good documents,
/// stored as a rider -- before this was found.
void main() {
  final auth = File('lib/src/data/driver_auth_repository.dart');
  final init = File('../../supabase/migrations/20260927000001_init.sql');
  final roleMigration = File(
    '../../supabase/migrations/20260930000002_driver_role.sql',
  );

  String authSource() => auth.readAsStringSync();
  String initSql() => init.readAsStringSync();

  group('the signup the driver app sends', () {
    test('declares role: driver, which was the missing half', () {
      // The regression, in one assertion. Without the key, `handle_new_user`
      // writes 'rider' for every driver who ever signs up.
      final s = authSource();
      expect(
        s,
        contains("'role': 'driver'"),
        reason:
            'the driver app must send role: driver in the signup metadata; '
            'handle_new_user reads it once, at signup, and defaults to rider '
            'when the key is absent, so a driver created here can never be '
            'matched to a trip',
      );
    });

    test('sends the role in the same call that sends the name', () {
      // The `data:` map itself, not a window around the call.
      //
      // Two earlier attempts at this, both wrong in instructive ways. A suffix
      // assertion would have checked the formatting rather than the payload. A
      // fixed-width window from `auth.signUp(` checked the payload, but the
      // width was a guess: the comments explaining *why* the key is there are
      // longer than the window, so the assertion failed on a file where the code
      // was plainly correct. Locating the map and reading to its closing brace
      // cannot rot that way -- the comments can be any length.
      final s = authSource();
      final call = s.indexOf('auth.signUp(');
      expect(call, greaterThan(-1), reason: 'the signup call is gone or renamed');
      final data = s.indexOf('data:', call);
      expect(data, greaterThan(-1), reason: 'the signup sends no data map');
      final close = s.indexOf('}', data);
      expect(close, greaterThan(data), reason: 'the data map is not closed');
      final map = s.substring(data, close);

      expect(
        map,
        contains("'full_name': fullName"),
        reason:
            'the signup must still send full_name alongside role; they are '
            'different keys with different jobs and neither replaces the other',
      );
      expect(
        map,
        contains("'role': 'driver'"),
        reason:
            "role: 'driver' must be in the data map of this very call, not sent "
            'by a later update; handle_new_user only reads it during the insert '
            'that creates the user, and there is no second chance to set it',
      );
    });

    test('still sends full_name, which is a separate key with a separate job', () {
      // `20260928000001_persist_signup_name.sql` reads `full_name` to seed
      // `profiles.full_name`. Adding `role` must not have displaced it, and
      // this is the assertion that would notice if it did.
      expect(
        authSource(),
        contains("'full_name': fullName"),
        reason:
            'full_name is what persists the driver name onto the profile; it is '
            'a different key from role and both are needed',
      );
    });
  });

  group('the database side that has to agree', () {
    test('handle_new_user reads the role key this sends', () {
      final sql = initSql();
      expect(
        sql,
        contains("raw_user_meta_data ->> 'role'"),
        reason:
            "handle_new_user must read raw_user_meta_data ->> 'role'; if the key "
            'was renamed, the key the app sends no longer does anything',
      );
    });

    test('anything that is not exactly "driver" becomes a rider', () {
      // The safety half. The signup is a claim by an unverified person, so the
      // value is coerced rather than trusted: there is no third role for a
      // crafted metadata key to land in.
      final sql = initSql();
      expect(
        sql,
        contains("then 'driver' else 'rider' end"),
        reason:
            "handle_new_user must coerce the metadata value -- 'driver' or "
            "'rider', nothing else -- so a crafted signup key cannot invent a "
            'role that no other code knows how to handle',
      );
    });

    test('trip matching really does filter on role, so the omission mattered', () {
      // This is the consequence that makes the bug a revenue bug rather than a
      // cosmetic one. If matching stopped filtering on role, the assertions
      // above would matter much less and this one is the thing to revisit.
      expect(
        initSql(),
        contains("where d.role = 'driver'"),
        reason:
            "match_offers_for_trip is expected to filter on d.role = 'driver'; "
            'this test exists because a driver who was approved but stored as a '
            'rider is passed, matched to nobody, and never told why',
      );
    });
  });

  group('the one transition a client is allowed', () {
    test('the migration exists and was applied', () {
      expect(
        roleMigration.existsSync(),
        isTrue,
        reason: 'migration not found at ${roleMigration.path}',
      );
    });

    test('permits rider to driver', () {
      // The recovery path for somebody who installed the rider app first, or who
      // signed up before the metadata key was sent. Without it they are a rider
      // for life.
      expect(
        roleMigration.readAsStringSync(),
        contains("old.role = 'rider' and new.role = 'driver'"),
        reason:
            'the rider -> driver transition is the only way back for an account '
            'created before the app sent role; if it has been narrowed, those '
            'people can never drive again',
      );
    });

    test('grants role to authenticated, or the trigger is dead code', () {
      // PostgREST rejects the whole update with PGRST204 when the column is not
      // in the grant, *before* the trigger is ever reached. So a trigger that
      // allows the transition but a grant that omits the column permits nothing
      // at all, and the error a caller sees points at permissions rather than at
      // the trigger. Same class of break as the missing `ghana_card_expiry`
      // column in the init migration.
      final sql = roleMigration.readAsStringSync();
      expect(
        RegExp(r'grant update \([^)]*\brole\b').hasMatch(sql),
        isTrue,
        reason:
            'role must be in the update grant to authenticated, or PostgREST '
            'rejects the write with PGRST204 before guard_profile_update runs',
      );
    });

    test('keeps the reverse direction blocked', () {
      // A driver must not be able to shed their obligations on a live trip, and
      // nothing in the product needs it.
      final sql = roleMigration.readAsStringSync();
      expect(
        sql,
        contains('role may only move rider -> driver'),
        reason:
            'the guard should refuse everything except rider -> driver, and say '
            'so in the error a caller sees; a widened guard is a privilege '
            'change and should be a deliberate edit to this test',
      );
      expect(
        sql,
        isNot(contains("old.role = 'driver' and new.role = 'rider'")),
        reason: 'the reverse transition must stay refused',
      );
    });

    test('leaves kyc_status and rating server-owned', () {
      // The reason letting a client set its own role is safe at all. If either of
      // these became client-writable then `role = driver` would be a way to
      // approve yourself, and the reasoning in the migration would be wrong.
      final sql = roleMigration.readAsStringSync();
      expect(
        sql,
        contains("new.kyc_status <> 'pending'"),
        reason: 'kyc_status must still be client-writable to pending only',
      );
      expect(
        sql,
        contains('rating is not user-writable'),
        reason: 'rating must stay server-owned',
      );
      expect(
        sql,
        contains('trip_count is not user-writable'),
        reason: 'trip_count must stay server-owned',
      );
    });
  });
}
