import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_controller.dart';

/// [ChatRepository] over PostgREST and realtime.
///
/// The RLS policies on `chat_messages` already do the whole of the security work
/// here, and they were written before any of this existed:
///
///   `trip chat read`   -- the message's trip must be one this user rides or drives
///   `trip chat insert` -- the same, plus `sender_id` must be this user
///
/// So there is no trip-ownership check in this file to get wrong, and no
/// ownership is inferred from the arguments. Passing somebody else's trip id is
/// not a bug here; it is a read that returns nothing and a write that returns 403,
/// which is the database saying no in the only terms it has.
class SupabaseChatRepository implements ChatRepository {
  SupabaseChatRepository(this._client, {required this.myId});

  final SupabaseClient _client;
  final String myId;

  @override
  Stream<List<ChatMessage>> messages(String tripId) {
    // `.stream()` rather than a poll. `chat_messages` is in the
    // `supabase_realtime` publication, and a rider's "I'm at the gate" is worth
    // arriving while the driver is looking at the screen rather than on the next
    // refresh. The alternative -- a one-second poll, which the offer queue already
    // does -- would hold the radio open for the whole trip on a metered plan.
    return _client
        .from('chat_messages')
        .stream(primaryKey: ['id'])
        .eq('trip_id', tripId)
        .order('created_at', ascending: true)
        .map(
          (rows) => (rows as List<dynamic>)
              .map((r) => ChatMessage.fromJson(r as Map<String, dynamic>))
              .toList(growable: false),
        );
  }

  @override
  Future<void> send({required String tripId, required String body}) async {
    try {
      // `sender_id` is set here and not taken from the argument. The policy
      // compares it to `auth.uid()`, so a client that sent someone else's id would
      // be refused -- and passing it in at all would be an API that invites that
      // mistake.
      await _client.from('chat_messages').insert({
        'trip_id': tripId,
        'sender_id': myId,
        'body': body,
      });
    } on PostgrestException catch (e) {
      // PostgREST refusals are `PostgrestException`, not `FunctionException`, so
      // `describeFunctionFailure` does not apply -- that one reads `e.details`,
      // which is an Edge Function's JSON body. The useful fields here are
      // `code`, `message` and `hint`.
      //
      // 42501 is RLS refusing, which for this table means the trip is not this
      // user's. It is a "you cannot do that", not a "try again", so the two are
      // not given the same message.
      if (e.code == '42501') {
        throw const ChatFailure('You cannot message this trip.');
      }
      // PostgREST answers a write that matched no rows with 204 and an empty
      // body, so there is no status here worth reporting -- what is worth
      // reporting is that the message did not arrive.
      throw const ChatFailure('That message did not send. Try again.');
    } on ChatFailure {
      rethrow;
    } catch (_) {
      // A dropped connection on a metered connection, or a socket that closed
      // mid-write. Not distinguished from the database refusal above, because
      // from the driver's seat both are "it did not send".
      throw const ChatFailure('Could not reach the server.');
    }
  }
}