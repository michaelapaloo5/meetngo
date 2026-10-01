import 'package:supabase_flutter/supabase_flutter.dart';

import 'leave_trip_controller.dart';

/// [LeaveTripRepository] over the `leave-trip` Edge Function.
///
/// A function call rather than a direct table write, and not for tidiness. Three
/// things have to happen atomically-ish and none of them can be done by a client:
///
/// - the state change is conditional on the state the trip is *now* in, so two
///   presses of the button cannot both believe they won;
/// - `trip_withdrawals` has no row level security policy at all, so no client key
///   can write it;
/// - the driver has to be put back on the road and the pending offers voided.
///
/// So the rules live in `leave-trip/handler.ts` and this file translates its
/// answers. The two refusals worth distinguishing are below, because they read the
/// same way on the wire and mean different things to a driver.
class SupabaseLeaveTripRepository implements LeaveTripRepository {
  SupabaseLeaveTripRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<void> leave({required String tripId, required String reason}) async {
    try {
      await _client.functions.invoke(
        'leave-trip',
        body: {'tripId': tripId, 'reason': reason},
      );
    } on FunctionException catch (e) {
      final details = e.details;
      final message = details is Map ? details['error'] : null;
      if (message is String && message.isNotEmpty) {
        // The server's own sentence, used verbatim. For the 409 cases it already
        // says the thing a driver needs -- "the rider is in the car" rather than
        // the generic "conflict" -- and rewording it here would only lose that.
        throw LeaveTripFailure(message);
      }
      if (e.status == 0) {
        throw const LeaveTripFailure('Could not reach the server.');
      }
      throw LeaveTripFailure('Could not leave this trip. Try again.');
    } on LeaveTripFailure {
      rethrow;
    } catch (_) {
      throw const LeaveTripFailure('Could not leave this trip. Try again.');
    }
  }
}