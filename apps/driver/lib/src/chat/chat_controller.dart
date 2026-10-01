import 'dart:async';

import 'package:flutter/foundation.dart';

/// One message in a trip's conversation.
///
/// Immutable and compared by value, because the realtime stream delivers a new
/// list on every change and the list rebuilds on each one. Without value
/// equality every message would be "new" on every event and the whole thread
/// would repaint and lose scroll position -- which is the single most annoying
/// thing a chat screen can do to someone mid-conversation.
@immutable
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.tripId,
    required this.senderId,
    required this.body,
    required this.createdAt,
  });

  final String id;
  final String tripId;

  /// The profile id that sent it, not the driver id. The realtime row carries a
  /// uuid with no role on it, and the only question the UI asks is "is this mine?"
  final String senderId;
  final String body;
  final DateTime createdAt;

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id'] as String,
    tripId: json['trip_id'] as String,
    senderId: json['sender_id'] as String,
    body: (json['body'] as String?) ?? '',
    // Parsed in UTC and kept in UTC. A message timestamp that shifts when the
    // device changes timezone reads as a message sent in the wrong hour, and the
    // only place the wall clock is shown is the bubble, formatted locally at
    // paint time.
    createdAt: DateTime.parse(json['created_at'] as String).toUtc(),
  );

  /// Whether this one is the signed-in user's, which decides the bubble's side.
  bool isMine(String myId) => senderId == myId;

  /// The time as shown on the bubble.
  ///
  /// Local time, 24-hour, no seconds. A rider reading "I'll be there in 5" is
  /// reading a clock face, and a Ghanaian reads a 24-hour one.
  String get clockLabel {
    final local = createdAt.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  bool operator ==(Object other) =>
      other is ChatMessage &&
      other.id == id &&
      other.tripId == tripId &&
      other.senderId == senderId &&
      other.body == body &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(id, tripId, senderId, body, createdAt);
}

/// A conversation with one rider, for one trip.
///
/// Two decisions here rather than in the controller, because both are rules about
/// what the data means and neither is a rule about what the screen looks like.
class ChatController extends ChangeNotifier {
  ChatController({required this.myId, required this.tripId});

  /// The signed-in driver's profile id. Stored rather than passed to every
  /// comparison, because "is this mine" is asked once per bubble per rebuild and
  /// getting it wrong puts a driver's own words in the other column.
  final String myId;
  final String tripId;

  /// Supplied by the screen so the controller has no repository of its own. The
  /// contact sheet's controller takes one in the constructor for the same reason,
  /// and the wiring test swaps it for a fake.
  ChatRepository? repository;

  List<ChatMessage> _messages = const [];
  StreamSubscription<List<ChatMessage>>? _subscription;
  bool _loading = true;
  String? _problem;
  bool _sending = false;

  /// Oldest first, which is the order a conversation is read in.
  List<ChatMessage> get messages => _messages;
  bool get loading => _loading;
  bool get sending => _sending;

  /// Set only for a failure a driver can act on. Null means "nothing is wrong",
  /// which is different from "the message did not arrive" -- a send that fails
  /// shows on the composer, and a load that fails shows here.
  String? get problem => _problem;

  bool get isEmpty => !_loading && _messages.isEmpty && _problem == null;

  /// Begin listening. Safe to call again; the previous subscription is closed.
  Future<void> load() async {
    await _subscription?.cancel();
    final repo = repository;
    if (repo == null) {
      // No repository is a programming error, not a network failure, and it is
      // reported as one rather than as "no messages", because an empty thread
      // and a broken thread look identical to the driver otherwise.
      _messages = const [];
      _loading = false;
      _problem = 'Chat is not available right now.';
      notifyListeners();
      return;
    }
    _loading = true;
    _problem = null;
    notifyListeners();
    try {
      _subscription = repo
          .messages(tripId)
          .listen(_apply, onError: (Object e) {
            _loading = false;
            _problem = 'Could not load your messages.';
            notifyListeners();
          });
    } on ChatFailure catch (e) {
      _loading = false;
      _problem = e.message;
      notifyListeners();
    }
  }

  void _apply(List<ChatMessage> incoming) {
    _messages = incoming;
    _loading = false;
    // A failure is cleared once messages arrive, and only then: a stream that
    // recovers is not a stream that is broken, and leaving the error up would
    // tell the driver their conversation is unavailable while they are reading it.
    _problem = null;
    notifyListeners();
  }

  /// Send [body], and refuse anything that is not a message.
  ///
  /// The checks are here rather than in the screen because the screen's button is
  /// disabled for the same reasons, and two implementations of "is this sendable"
  /// is how they drift apart.
  static const int kMaxLength = 500;
  static const int kMinLength = 1;

  /// Why [text] cannot be sent, or null if it can.
  ///
  /// Not trimmed-and-checked: the sent body keeps the driver's own spacing, and
  /// only the *decision* to send ignores whitespace. `isSendable` and the send
  /// path therefore agree on what counts as empty.
  static String? problemFor(String text) {
    final trimmed = text.trim();
    if (trimmed.length < kMinLength) return 'Type a message';
    if (text.length > kMaxLength) {
      return 'Too long. ${text.length} of $kMaxLength characters';
    }
    return null;
  }

  static bool isSendable(String text) => problemFor(text) == null;

  Future<bool> send(String text) async {
    final problem = problemFor(text);
    if (problem != null) {
      _problem = problem;
      notifyListeners();
      return false;
    }
    final repo = repository;
    if (repo == null) {
      _problem = 'Chat is not available right now.';
      notifyListeners();
      return false;
    }

    _sending = true;
    _problem = null;
    notifyListeners();
    try {
      // Not added locally on success. The realtime stream delivers this driver's
      // own insert a moment later, and a local copy would be a second bubble with
      // the same text until it arrived -- visible as the driver watching their
      // message appear twice.
      await repo.send(tripId: tripId, body: text.trim());
      return true;
    } on ChatFailure catch (e) {
      _problem = e.message;
      return false;
    } finally {
      _sending = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}

/// Where messages come from and go to.
///
/// An interface rather than a concrete class so the widget test can hand the
/// controller a stream it controls, which is the only way to test the two states
/// that matter here: a message arriving while the screen is open, and a send that
/// fails.
abstract class ChatRepository {
  /// Live messages for [tripId], oldest first, re-emitting the whole list on
  /// every change.
  Stream<List<ChatMessage>> messages(String tripId);

  Future<void> send({required String tripId, required String body});
}

/// A send that failed in a way a driver can be told about.
class ChatFailure implements Exception {
  const ChatFailure(this.message);
  final String message;

  @override
  String toString() => 'ChatFailure: $message';
}