import 'package:supabase_flutter/supabase_flutter.dart';

/// Every Edge Function in this project answers an error status with the body
/// `{ error: <string> }` (`_shared/cors.ts` sets `Content-Type: application/json`,
/// and `functions_client` decodes a JSON body before handing it back as
/// `details`). A body that is not JSON, or a JSON body with no `error` key,
/// must still produce a message rather than `null`.
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
