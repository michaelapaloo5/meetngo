import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_repository.dart';
import 'chat_repository.dart';

class SupabaseChatRepository implements ChatRepository {
  SupabaseChatRepository(this._client);
  final SupabaseClient _client;

  @override
  Future<List<ChatMessage>> thread(String tripId) async {
    // No user filter: `trip chat read` already requires the caller to be the
    // rider or the driver on that trip, and adding `.eq('sender_id', uid)`
    // would hide the other party's half of the conversation, which is the
    // whole point of a thread.
    //
    // `chat_trip_idx` is `(trip_id, created_at)`, so this ordering is the
    // index order rather than a sort the database has to do afterwards.
    final rows = await _client
        .from('chat_messages')
        .select('id, trip_id, sender_id, body, created_at')
        .eq('trip_id', tripId)
        .order('created_at', ascending: true);
    return rows.map(ChatMessage.fromJson).toList();
  }

  @override
  Future<void> send({required String tripId, required String body}) async {
    // `sender_id = auth.uid()` is the first half of `trip chat insert`
    // (`init.sql:586-594`); the second half, that the sender is party to the
    // trip, can only be checked server-side, so a refusal here arrives as a
    // `PostgrestException` and is reported as such.
    //
    // Refusing a signed-out call before touching the database is the same
    // reason `raiseSos` reads the user first: a null `currentUser` would
    // otherwise be written as a null `sender_id`, which fails the foreign key
    // with a message that says nothing about the actual problem.
    final uid = _client.auth.currentUser?.id;
    if (uid == null) throw const AuthFailure('Not signed in');
    if (!ChatMessage.isSendable(body)) {
      throw const ChatFailure(
        'A message has to be between 1 and 500 characters',
      );
    }
    // A refused write throws rather than returning an error field, because
    // awaiting a postgrest builder yields the rows.
    await _client.from('chat_messages').insert({
      'trip_id': tripId,
      'sender_id': uid,
      'body': body,
    });
  }
}
