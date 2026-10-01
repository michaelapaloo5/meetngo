import 'package:supabase_flutter/supabase_flutter.dart';

import 'left_item_controller.dart';

/// [LeftItemRepository] over PostgREST.
///
/// Every rule about who may do what here is already in the database, and none of
/// it is re-implemented:
///
/// - `report a left item on a trip you are party to` -- INSERT, `reporter_id`
///   must be `auth.uid()` and the trip must be one this user rides or drives.
/// - `read your own left item reports`               -- SELECT, `reporter_id = auth.uid()`.
/// - `correct your own left item report`             -- UPDATE, `reporter_id = auth.uid()`
///   on both halves.
///
/// So `reporter_id` is set here and not taken as an argument, and no trip
/// ownership is inferred from what the caller passed. Handing this a trip the user
/// is not on is not a bug to guard against; it is a 403 from the policy, which is
/// the database answering in the only terms it has.
///
/// `status`, `staff_note` and `returned_at` have no grant to `authenticated` at
/// all, so PostgREST refuses a write naming them with PGRST204 before the guard
/// trigger is reached. That is deliberate and it is why this class never sends
/// them.
class SupabaseLeftItemRepository implements LeftItemRepository {
  SupabaseLeftItemRepository(this._client, {String? myId}) : _overrideMyId = myId;

  final SupabaseClient _client;

  /// Only for a test that needs a fixed identity. Production reads
  /// [SupabaseClient.auth], for the same reason as the chat repository: this is
  /// registered in `main.dart` before there is necessarily a session, and an id
  /// captured at registration time would file reports as nobody.
  final String? _overrideMyId;

  String get myId => _overrideMyId ?? _client.auth.currentUser?.id ?? '';

  /// The conflict target for [save], and the exact text of the unique constraint
  /// `left_item_reports_one_per_trip`.
  ///
  /// Both halves of this pair are load-bearing and neither is sufficient alone.
  /// `toolchain/probe-upsert.mjs` measured it: `Prefer: resolution=merge-duplicates`
  /// on its own is refused with 409, because PostgREST does not build
  /// `ON CONFLICT DO UPDATE` without being told the target. The client's `upsert`
  /// sends this string as `?on_conflict=` and the `Prefer` header together, which
  /// is what makes the correction work.
  static const String onConflict = 'trip_id,reporter_id';

  @override
  Future<LeftItemReport?> reportFor(String tripId) async {
    // `.limit(1)` rather than `.single()`, because the unique constraint means
    // there is at most one and `single()` treats "none" as an error that has to be
    // caught. Null here means nothing has been filed, which is a normal state on
    // most trips and not a failure.
    final rows = await _guard(() async {
      final result = await _client
          .from('left_item_reports')
          .select()
          .eq('trip_id', tripId)
          .order('created_at', ascending: false)
          .limit(1);
      return result as List<dynamic>;
    });
    if (rows.isEmpty) return null;
    return LeftItemReport.fromJson(rows.first as Map<String, dynamic>);
  }

  @override
  Future<LeftItemReport> save({
    required String tripId,
    required String item,
    required String description,
  }) async {
    final rows = await _guard(() async {
      final result = await _client.from('left_item_reports').upsert(
        {'trip_id': tripId, 'reporter_id': myId, 'item': item, 'description': description},
        onConflict: onConflict,
      ).select();
      return result as List<dynamic>;
    });
    // An upsert that matched nothing returns nothing, which for this client means
    // either a policy refusal or a dropped connection -- and both look the same
    // from here. A report the driver was told was saved and cannot be read back is
    // the worst outcome, so it is reported rather than assumed.
    if (rows.isEmpty) {
      throw const LeftItemFailure('That report was not saved. Try again.');
    }
    return LeftItemReport.fromJson(rows.first as Map<String, dynamic>);
  }

  /// Turn a PostgREST failure into a sentence a driver can act on.
  Future<List<dynamic>> _guard(Future<List<dynamic>> Function() run) async {
    try {
      return await run();
    } on PostgrestException catch (e) {
      if (e.code == '42501') {
        throw const LeftItemFailure('You cannot report an item on this trip.');
      }
      // 23505 is the unique constraint, which here means a second report for one
      // trip reached the server without the conflict target. That is a bug in the
      // call rather than anything the driver did, and saying "try again" would
      // send them round the same loop.
      if (e.code == '23505') {
        throw const LeftItemFailure('That report could not be updated.');
      }
      if (e.code == 'PGRST204') {
        // A column with no grant. Nothing in this file should reach it.
        throw const LeftItemFailure('That report could not be saved.');
      }
      throw const LeftItemFailure('Could not save the report. Try again.');
    } catch (_) {
      throw const LeftItemFailure('Could not reach the server.');
    }
  }
}