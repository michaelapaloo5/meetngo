import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/data/function_failure.dart';
import 'package:meetngo_rider/src/data/supabase_auth_repository.dart';
import 'package:meetngo_rider/src/data/supabase_trip_repository.dart';
import 'package:meetngo_rider/src/data/trip_repository.dart';
import 'package:mng_core/mng_core.dart';
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

  group('reading the assigned driver', () {
    // The parser is the load-bearing part. `driver_locations.point` is a
    // PostGIS `geography`, so PostgREST hands it back as GeoJSON in GeoJSON's
    // order, `[lng, lat]` -- which is the *reverse* of the `{lat, lng}` shape
    // the rest of the app uses for trip stops. Reading it the other way round
    // puts the driver in the sea off the coast of Ghana, and it looks like a
    // plausible position rather than an error.

    final repo = SupabaseTripRepository(
      SupabaseClient('http://localhost:54321', 'anon-key'),
    );

    GeoPoint? parse(Object? value) =>
        SupabaseTripRepository.geographyToPointForTest(value);

    test('a geography comes back as the point it names', () {
      final point = parse({
        'type': 'Point',
        'coordinates': [-0.187, 5.6037],
      });
      // Note the order: GeoJSON puts longitude first. Swapped, Accra's
      // longitude would be read as a latitude of -0.187 and its latitude as a
      // longitude of 5.6, which is the middle of the Atlantic.
      expect(point?.lng, -0.187);
      expect(point?.lat, 5.6037);
    });

    test('the {lat, lng} parser cannot read a geography column', () {
      // The two shapes coexist in this app: trip stops are normalised into
      // `{lat, lng}` by `request-ride`, while anything read straight out of a
      // geography column is GeoJSON's `[lng, lat]`. `GeoPoint.fromJson` casts
      // `json['lat'] as num`, so handing it GeoJSON does not return null -- it
      // throws a TypeError, which no `on PostgrestException` would catch. That
      // is precisely why a separate parser exists rather than a call to it.
      expect(
        () => GeoPoint.fromJson({
          'type': 'Point',
          'coordinates': [-0.187, 5.6037],
        }),
        throwsA(isA<TypeError>()),
        reason: 'if this stops throwing, fromJson can read a geography column '
            'and the two shapes are no longer distinguishable at a call site',
      );
      expect(
        parse({'type': 'Point', 'coordinates': [-0.187, 5.6037]}),
        isNotNull,
      );
    });

    test('a null column is null, not a crash', () {
      expect(parse(null), isNull);
    });

    test('a point of the wrong type is refused', () {
      expect(parse({'type': 'LineString', 'coordinates': [0, 0]}), isNull);
    });

    test('coordinates that are not numbers are refused', () {
      expect(
        parse({'type': 'Point', 'coordinates': ['nope', 5.6]}),
        isNull,
      );
    });

    test('too few coordinates are refused', () {
      expect(parse({'type': 'Point', 'coordinates': [5.6]}), isNull);
    });

    test('an impossible latitude is refused rather than drawn', () {
      // A latitude of 187 is not a place, and a car drawn there is a car a
      // rider cannot tell from a bug.
      expect(
        parse({'type': 'Point', 'coordinates': [5.6, 187]}),
        isNull,
      );
    });

    test('an impossible longitude is refused', () {
      expect(
        parse({'type': 'Point', 'coordinates': [900, 5.6]}),
        isNull,
      );
    });

    test('a row with no driver never asks the server', () async {
      // Spending a round trip to be told the same thing by the policy.
      expect(await repo.assignedDriverLocation(null), isNull);
      expect(await repo.assignedDriverLocation(''), isNull);
    });
  });

  group('the heading the driver is published with', () {
    test('a bearing of 0 is a real reading, not "none"', () {
      // North is a heading. Treating 0 as absent would leave a car heading
      // exactly north unrotated by the map for a reason nobody can see.
      expect(normaliseBearing(0), 0);
    });

    test('a bearing of -1 is the plugin saying it has no compass', () {
      // Taken at face value, -1 rotates a car to 359 degrees -- a car
      // apparently reversing while it drives forwards.
      expect(normaliseBearing(-1), isNull);
    });

    test('a NaN bearing is refused', () {
      expect(normaliseBearing(double.nan), isNull);
    });

    test('a heading survives the round trip to the map', () {
      // 450 degrees is a legal compass reading of 90, and MapLibre's
      // `icon-rotate` would take it as written.
      final fix = VehicleFix(const GeoPoint(5.6037, -0.1870), normaliseBearing(450));
      expect(fix.headingDegrees, 90);
    });
  });
}
