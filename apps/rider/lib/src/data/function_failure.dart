import 'package:supabase_flutter/supabase_flutter.dart';

/// Every Edge Function in this project answers an error status with the body
/// `{ error: <string> }`, and each one sets `Content-Type: application/json`
/// on that body in its own `json()` helper (`request-ride/index.ts:14`,
/// `offers/handler.ts:24`, `cancel-trip/handler.ts:22`,
/// `complete-trip/handler.ts:25`, `demo-pay/handler.ts:22`) — not in
/// `_shared/cors.ts`, which carries only the three
/// `Access-Control-Allow-*` headers. `functions_client` decodes a JSON
/// body before handing it back as `details`. A body that is not JSON, or a
/// JSON body with no `error` key, must still produce a message rather than
/// `null`.
///
/// `cancel-trip` is the reason the `error` key is not optional in practice: its
/// 409 is the answer a rider gets for the ordinary case of cancelling after the
/// trip has gone `ongoing`, so a 409 without an `error` key reads
/// `Something went wrong (409)` on a screen where the rider can act.
/// `complete-trip` and `demo-pay` owe the same for the same reason: both
/// answer a 409 for a trip that is not in a state to be settled or paid, and
/// both put `error` on it.
///
/// Two functions here reach this, and neither can read a failure any other way:
/// `functions_client` throws on anything outside 200..299
/// (`functions_client-2.7.1/lib/src/functions_client.dart:255-269`) and its
/// `FunctionResponse` carries only `data` and `status` — there is no `error`
/// field on a response to read. `data/trip_functions.dart` is where
/// `complete-trip` and `demo-pay` are called from, and
/// `supabase_trip_repository.dart:75` and `:95` are the other two.
String describeFunctionFailure(FunctionException e) {
  final details = e.details;
  if (details is Map) {
    final message = details['error'];
    if (message is String && message.isNotEmpty) return message;
  }
  if (details is String && details.isNotEmpty) return details;
  if (e.status == 0) return 'Could not reach the server';
  return 'Something went wrong (${e.status})';
}
