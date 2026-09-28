import 'package:flutter/foundation.dart';

import '../data/booked_trip.dart';
import '../data/chat_repository.dart';
import '../data/failure_message.dart';
import '../data/trip_repository.dart';

/// Which of the two things the chat tab shows is on screen.
enum ChatStage { picking, thread }

/// A trip's message thread, and the trip list it is picked from.
///
/// Two calls, both caught, because a chat screen that fails quietly is a chat
/// screen where a rider cannot tell a broken conversation from one where the
/// driver has not replied. [error] is rendered above the thread in red and is
/// cleared by the next action, not by a timer.
class ChatController extends ChangeNotifier {
  ChatController({required this.trips, required this.chat});

  final TripRepository trips;
  final ChatRepository chat;

  ChatStage _stage = ChatStage.picking;
  ChatStage get stage => _stage;

  bool _loadingTrips = false;
  bool get loadingTrips => _loadingTrips;

  bool _loadingThread = false;
  bool get loadingThread => _loadingThread;

  bool _sending = false;
  bool get sending => _sending;

  List<BookedTrip> _rides = const [];
  List<BookedTrip> get rides => _rides;

  List<ChatMessage> _messages = const [];
  List<ChatMessage> get messages => _messages;

  String? _error;
  String? get error => _error;

  BookedTrip? _open;
  BookedTrip? get open => _open;

  /// The id of the signed-in rider, so a bubble can say which side of the
  /// thread it is.
  String? selfId;

  /// Loads the trip list the rider can pick a conversation with.
  Future<void> loadRides() async {
    if (_loadingTrips) return;
    _loadingTrips = true;
    _error = null;
    notifyListeners();
    try {
      _rides = await trips.history();
    } on Object catch (e) {
      _error = describeFailure(e);
    } finally {
      _loadingTrips = false;
      notifyListeners();
    }
  }

  Future<void> openTrip(BookedTrip ride) async {
    _open = ride;
    _stage = ChatStage.thread;
    _messages = const [];
    _error = null;
    notifyListeners();
    await refresh();
  }

  void closeTrip() {
    _open = null;
    _messages = const [];
    _error = null;
    _stage = ChatStage.picking;
    notifyListeners();
  }

  Future<void> refresh() async {
    final ride = _open;
    if (ride == null) return;
    _loadingThread = true;
    notifyListeners();
    try {
      _messages = await chat.thread(ride.id);
      _error = null;
    } on Object catch (e) {
      // The messages already on screen are left alone. A failed refresh means
      // the rider cannot see *new* ones, not that the ones they were reading
      // are gone, and clearing the thread would lose their scroll position
      // over a request that was never answered.
      _error = describeFailure(e);
    } finally {
      _loadingThread = false;
      notifyListeners();
    }
  }

  /// Whether the send button is live.
  ///
  /// The 500-character cap is the database's own check constraint on
  /// `chat_messages.body`, so this is not a stylistic limit: a body over it is
  /// rejected by PostgREST with a 23514 and the message never lands. Clamping
  /// in the controller and refusing here means the rider is told the limit
  /// while they are typing rather than after a failed send.
  bool canSend(String draft) => !_sending && ChatMessage.isSendable(draft);

  /// Sends one message, clamped to what the column will accept.
  ///
  /// Returns whether it landed, and always leaves the field's contents to the
  /// caller: the field is cleared on success and left as typed on failure, so
  /// a message the rider just wrote is not destroyed by a dropped connection.
  Future<bool> send(String draft) async {
    final ride = _open;
    if (ride == null) return false;
    if (!canSend(draft)) return false;
    _sending = true;
    _error = null;
    notifyListeners();
    try {
      await chat.send(tripId: ride.id, body: draft.trim());
      // Re-read rather than appending the optimistic copy: the row's `id` and
      // `created_at` come from the database, and a bubble carrying a locally
      // invented timestamp is the kind of thing that gets screenshotted and
      // believed.
      _messages = await chat.thread(ride.id);
      return true;
    } on Object catch (e) {
      _error = describeFailure(e);
      return false;
    } finally {
      _sending = false;
      notifyListeners();
    }
  }
}
