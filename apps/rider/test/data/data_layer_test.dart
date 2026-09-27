import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/data/function_failure.dart';
import 'package:meetngo_rider/src/data/supabase_auth_repository.dart';
import 'package:meetngo_rider/src/data/supabase_trip_repository.dart';
import 'package:meetngo_rider/src/data/trip_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The two Supabase repositories are imported here for one reason, and the test
/// below is the only place either is named: nothing else in the tree imports
/// them, so `flutter test` does not compile them unless something here does.
/// That gap is how compile errors in these two files reached a green test run
/// and were caught only by `flutter analyze`. Naming each type is enough to pull
/// both files into the test compile, and it needs no server: constructing the
/// classes would open a real client, so the one test that needs one builds it
/// against a URL nothing is listening on.
void main() {
  test('both Supabase repositories compile as part of this suite', () {
    expect(SupabaseAuthRepository, isNotNull);
    expect(SupabaseTripRepository, isNotNull);
  });

  group('describeFunctionFailure', () {
    test('prefers the function own error string out of a JSON body', () {
      // What a function's own `json()` helper puts on the wire: a status, plus
      // `{ error: <string> }` as `application/json`, which `functions_client`
      // decodes into `details` before it throws
      // (`functions_client.dart:264-269`).
      const e = FunctionsHttpException(
        status: 401,
        details: {'error': 'That code is not right'},
      );
      expect(describeFunctionFailure(e), 'That code is not right');
    });

    test('falls back to a non-JSON body, which arrives as the raw text', () {
      // A body that is not `application/json` is decoded as text and handed
      // over whole (`functions_client.dart:250-252`).
      const e = FunctionsHttpException(
        status: 502,
        details: 'upstream connect error',
      );
      expect(describeFunctionFailure(e), 'upstream connect error');
    });

    test('refuses a JSON body whose error is missing, empty, or not a string', () {
      for (final details in <Object?>[
        <String, Object?>{},
        <String, Object?>{'error': ''},
        <String, Object?>{'error': 42},
        null,
      ]) {
        expect(
          describeFunctionFailure(FunctionsHttpException(status: 42501, details: details)),
          'Something went wrong (42501)',
          reason: 'details: $details',
        );
      }
    });

    test('reports a transport failure as unreachable, not as a status', () {
      // `FunctionsFetchException` pins `status: 0` (`types.dart:50-53`) and
      // passes the caught transport error straight through as `details`
      // (`functions_client.dart:212`). On a device that error is a
      // `SocketException` or a `ClientException`; `Exception` stands in for it
      // here, and what matters is the shape — an object, so neither the Map nor
      // the String branch above claims it, and the status-0 branch is what is
      // left. A network failure must never render as "Something went wrong (0)".
      final e = FunctionsFetchException(details: Exception('Connection refused'));
      expect(describeFunctionFailure(e), 'Could not reach the server');
    });

    test('a transport failure with nothing usable is still unreachable', () {
      // The same branch with no `details` at all, so a future reorder that lets
      // the `details` branches answer for a status-0 exception is caught here
      // rather than by the wording alone.
      const e = FunctionsFetchException();
      expect(describeFunctionFailure(e), 'Could not reach the server');
    });
  });

  test('TripRequestFailure carries its message into a log line', () {
    // Nothing in the tree catches this type, so without a `toString` the
    // message is lost and only `Instance of 'TripRequestFailure'` survives.
    const failure = TripRequestFailure('The ride service returned nothing');
    expect(failure.toString(), 'The ride service returned nothing');
  });

  group('with no signed-in user', () {
    late SupabaseTripRepository repo;

    setUp(() {
      // Never initialised, so `auth.currentUser` is null and `auth.session` is
      // null. Nothing here reaches the network: both calls below refuse first.
      final client = SupabaseClient('http://localhost:54321', 'anon-key');
      expect(client.auth.currentUser, isNull);
      repo = SupabaseTripRepository(client);
    });

    test('raiseSos refuses with a readable failure, not a null-check crash', () async {
      // The SOS row is the whole point of the call. A null-assertion here threw
      // `Null check operator used on a null value` before the insert, which the
      // `on PostgrestException` could not catch and which left no row behind:
      // the exact outcome the migration's own comment at `init.sql:585-592`
      // says the insert policy exists to prevent.
      await expectLater(
        repo.raiseSos('11111111-1111-1111-1111-111111111111', 'help'),
        throwsA(
          isA<TripRequestFailure>()
              .having((e) => e.message, 'message', 'Not signed in')
              .having((e) => e.toString(), 'toString', 'Not signed in'),
        ),
      );
    });

    test('activeTrip is null, and asks nobody', () async {
      expect(await repo.activeTrip(), isNull);
    });
  });
}
