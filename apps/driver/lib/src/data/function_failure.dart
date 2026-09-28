import 'package:supabase_flutter/supabase_flutter.dart';

/// Turns a thrown [FunctionException] into something a driver can read.
///
/// `functions.invoke` **throws** on any status outside 200..299 and its
/// `FunctionResponse` carries only `data` and `status` -- there is no `error`
/// field to read off a failure, so every failure arrives as a thrown
/// `FunctionException` and nothing else. A repository that expected `res.error`
/// would read a null on every failure and report a success.
///
/// Every Edge Function in this project answers an error status with a body of
/// `{"error": "<string>"}` and sets `Content-Type: application/json` on it
/// (`offers/handler.ts:19-25`), which `functions_client` decodes into
/// `details` before handing it back. A body that is not JSON, or a JSON body
/// with no `error` key, must still produce a message rather than `null`.
///
/// Two cases make that matter here. `offers` answers a 404 for an offer that is
/// not this driver's and a 409 for one that is already terminal, and both are
/// ordinary outcomes of a race rather than faults. `supabase_driver_repository`
/// turns both into `DriverAuthFailure`, so the driver reads the reason instead
/// of `null` with a number next to it.
///
/// A copy rather than an import: `apps/rider` and `apps/driver` are separate
/// packages and neither depends on the other.
String describeFunctionFailure(FunctionException e) {
  final details = e.details;
  if (details is Map) {
    final message = details['error'];
    if (message is String && message.isNotEmpty) return message;
    // `offers` answers a decline refusal as `{"declined": false, "reason": ...}`
    // (`offers/handler.ts:69`) rather than with an `error` key, so the reason
    // lives under a second name on that one response.
    final reason = details['reason'];
    if (reason is String && reason.isNotEmpty) return reason;
  }
  if (details is String && details.isNotEmpty) return details;
  if (e.status == 0) return 'Could not reach the server';
  return 'Something went wrong (${e.status})';
}
