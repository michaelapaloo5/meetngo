import 'package:supabase_flutter/supabase_flutter.dart';

/// Every Edge Function in this project answers an error status with the body
/// `{ error: <string> }`, and each one sets `Content-Type: application/json`
/// on that body in its own `json()` helper (`request-ride/index.ts:14`,
/// `offers/handler.ts:24`) — not in `_shared/cors.ts`, which carries only the
/// three `Access-Control-Allow-*` headers. `functions_client` decodes a JSON
/// body before handing it back as `details`. A body that is not JSON, or a
/// JSON body with no `error` key, must still produce a message rather than
/// `null`.
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
