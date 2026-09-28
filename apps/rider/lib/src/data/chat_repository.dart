/// A refused chat read or write, carrying a sentence written for the rider.
///
/// Separate from `AuthFailure` and `TripRequestFailure` because those two name
/// their own subject: a chat failure says something about the conversation, and
/// `describeFailure` is the one place a screen turns a throw into copy, so
/// anything thrown from here has to be a type that function knows about.
class ChatFailure implements Exception {
  const ChatFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One row of `chat_messages`.
///
/// The table is `(id, trip_id, sender_id, body text check 1..500, created_at)`.
/// `body` has a database check constraint, not just a client one, so a message
/// outside 1..500 characters is rejected by PostgREST with a 23514 and never
/// reaches the rider as anything but a failure.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.tripId,
    required this.senderId,
    required this.body,
    required this.createdAt,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as String,
        tripId: json['trip_id'] as String,
        senderId: json['sender_id'] as String,
        body: (json['body'] as String?) ?? '',
        createdAt: DateTime.tryParse((json['created_at'] as String?) ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );

  final String id;
  final String tripId;
  final String senderId;
  final String body;
  final DateTime createdAt;

  /// The database's own limit, read once so the input and the guard that
  /// decides whether the send button is live cannot drift from the constraint
  /// that rejects the write.
  static const int maxLength = 500;

  static const int minLength = 1;

  /// Whether this body would be accepted by `chat_messages_body_check`.
  static bool isSendable(String body) {
    final length = body.trim().length;
    return length >= minLength && length <= maxLength;
  }
}

abstract class ChatRepository {
  /// The thread for one trip, oldest first.
  Future<List<ChatMessage>> thread(String tripId);

  /// Writes one message as the signed-in rider.
  Future<void> send({required String tripId, required String body});
}
