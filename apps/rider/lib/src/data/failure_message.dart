import 'auth_repository.dart';
import 'chat_repository.dart';
import 'trip_repository.dart';

/// The message a screen shows for a failure that came out of the data layer.
///
/// The three rules this encodes, all of them measured rather than assumed:
///
///  * A repository that caught a server refusal has already shaped it into one
///    of this app's two failure types, and its message is the one the server
///    wrote. `cancelTrip` is the case that makes this matter: it is a
///    `functions.invoke`, so a 409 arrives as a `TripRequestFailure` carrying
///    `cancel-trip`'s own `error` string, and replacing that with anything else
///    throws away the only sentence written for the rider.
///  * Anything else is a call that never reached the server. A direct
///    PostgREST read or write lets a `SocketException`/`ClientException` through
///    unconverted, and those are not `AuthFailure` or `TripRequestFailure`, so
///    without this branch they would be reported as raw type names. `http` is
///    `dependency: transitive` and not in `pubspec.yaml`, so naming its
///    `ClientException` here would be a `depend_on_referenced_packages` info,
///    which is fatal under this repo's `--fatal-infos`. Matching on this app's
///    own types and falling back to a sentence needs no such import.
///  * "Could not reach the server" is a claim about the network, so it is only
///    used where nothing came back at all.
String describeFailure(Object failure) {
  if (failure is TripRequestFailure) return failure.message;
  if (failure is AuthFailure) return failure.message;
  if (failure is ChatFailure) return failure.message;
  return 'Could not reach the server';
}
