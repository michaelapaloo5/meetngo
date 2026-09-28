import 'package:mng_core/mng_core.dart' show DriverAvailability, GeoPoint;
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_driver/src/data/driver_auth_repository.dart';
import 'package:meetngo_driver/src/data/driver_repository.dart';
import 'package:meetngo_driver/src/data/function_failure.dart';
import 'package:meetngo_driver/src/data/supabase_driver_repository.dart';
import 'package:meetngo_driver/src/earnings/earnings_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The three Supabase-backed classes are named here for one reason, and the
/// first test is the only place any of them is named: nothing outside `main.dart`
/// imports them, so `flutter test` does not compile them unless something here
/// does. That gap is how compile errors in these files reach a green test run
/// and are caught only by `flutter analyze`. Naming each type pulls all three
/// into the test compile, and it needs no server.
void main() {
  test('the Supabase-backed classes compile as part of this suite', () {
    expect(SupabaseDriverRepository, isNotNull);
    expect(SupabaseEarningsRepository, isNotNull);
    expect(SupabaseDriverAuthRepository, isNotNull);
  });

  group('describeFunctionFailure', () {
    test('prefers the function own error string out of a JSON body', () {
      const e = FunctionsHttpException(
        status: 409,
        details: {'error': 'That offer is no longer pending'},
      );
      expect(describeFunctionFailure(e), 'That offer is no longer pending');
    });

    // `offers` answers a decline refusal as `{"declined": false, "reason": ...}`
    // (`offers/handler.ts:288`), not with an `error` key, so a driver refusing an
    // offer that somebody else took first would have been told
    // "Something went wrong (409)".
    test('reads the reason key the offers function actually uses', () {
      const e = FunctionsHttpException(
        status: 409,
        details: {'declined': false, 'reason': 'offer already accepted'},
      );
      expect(describeFunctionFailure(e), 'offer already accepted');
    });

    test('falls back to a non-JSON body, which arrives as the raw text', () {
      const e = FunctionsHttpException(
        status: 502,
        details: 'upstream connect error',
      );
      expect(describeFunctionFailure(e), 'upstream connect error');
    });

    test('refuses a body whose message is missing, empty or not a string', () {
      for (final details in <Object?>[
        <String, Object?>{},
        <String, Object?>{'error': ''},
        <String, Object?>{'error': 42},
        <String, Object?>{'declined': false},
        null,
      ]) {
        expect(
          describeFunctionFailure(
            FunctionsHttpException(status: 42501, details: details),
          ),
          'Something went wrong (42501)',
          reason: 'details: $details',
        );
      }
    });

    test('reports a transport failure as unreachable, not as a status', () {
      final e = FunctionsFetchException(details: Exception('Connection refused'));
      expect(describeFunctionFailure(e), 'Could not reach the server');
    });

    test('a transport failure with nothing usable is still unreachable', () {
      const e = FunctionsFetchException();
      expect(describeFunctionFailure(e), 'Could not reach the server');
    });
  });

  group('failures carry their message into a log line', () {
    test('DriverAuthFailure', () {
      const f = DriverAuthFailure('That trip is no longer yours to move');
      expect(f.toString(), 'That trip is no longer yours to move');
    });

    test('PayoutFailure', () {
      const f = PayoutFailure('Payouts are paused right now');
      expect(f.toString(), 'Payouts are paused right now');
    });
  });

  group('with no signed-in user', () {
    late SupabaseClient client;
    late SupabaseDriverRepository drivers;
    late SupabaseEarningsRepository earnings;

    setUp(() {
      // Never initialised, so `auth.currentUser` is null. Nothing below reaches
      // the network: every call refuses before it builds a query.
      client = SupabaseClient('http://localhost:54321', 'anon-key');
      expect(client.auth.currentUser, isNull);
      drivers = SupabaseDriverRepository(client);
      earnings = SupabaseEarningsRepository(client);
    });

    // `_client.auth.currentUser!.id` throws a `TypeError`, and a `TypeError` is
    // an `Error`, so the `on PostgrestException` around every caller of `_uid`
    // does not catch it. The failure would escape to the framework as an
    // unhandled async error with nothing on the driver's screen.
    test('every method that needs an id refuses with a readable failure', () async {
      await expectLater(
        drivers.me(),
        throwsA(
          isA<DriverAuthFailure>()
              .having((e) => e.message, 'message', 'Not signed in'),
        ),
      );
      await expectLater(
        drivers.submitGhanaCard(
          cardNumber: 'GHA-123456789-0',
          expiry: '04/29',
          fullName: 'JANE COOPER',
        ),
        throwsA(isA<DriverAuthFailure>()),
      );
      await expectLater(
        drivers.setAvailability(DriverAvailability.online),
        throwsA(isA<DriverAuthFailure>()),
      );
      await expectLater(
        drivers.activeTrip(),
        throwsA(isA<DriverAuthFailure>()),
      );
      await expectLater(
        drivers.updateLocation(const GeoPoint(5.6037, -0.1870)),
        throwsA(isA<DriverAuthFailure>()),
      );
    });

    // `advanceTripState` and `verifyPickupOtp` are deliberately absent from the
    // list above: neither reads the session, because neither needs the driver's
    // id -- both filter on a trip id, and `driver advances own trip` is
    // `using (driver_id = auth.uid())`, so signed out the write matches no row
    // and the row-count check turns that into
    // 'This trip is no longer yours to move'. Refusing a missing session there
    // would be a second, redundant answer to the same question.

    test('the earnings repository refuses rather than reading nobody\'s ledger',
        () async {
      await expectLater(
        earnings.ledger(),
        throwsA(
          isA<PayoutFailure>().having((e) => e.message, 'message', 'Not signed in'),
        ),
      );
    });

    // A synchronous throw out of a stream factory is a crash with no message, and
    // `watchMe` is read from `build`.
    test('the profile watch is empty rather than a crash', () async {
      expect(await drivers.watchMe().toList(), isEmpty);
    });

    test('the offer watch is empty rather than a crash', () async {
      expect(await drivers.watchOffers().toList(), isEmpty);
    });
  });

  group('a selfie that is not on this device', () {
    late SupabaseDriverRepository drivers;

    setUp(() {
      drivers = SupabaseDriverRepository(
        SupabaseClient('http://localhost:54321', 'anon-key'),
      );
    });

    // Reporting a selfie the server does not hold is the outcome to avoid, so a
    // path that cannot be read back is refused here.
    test('an empty path is refused', () async {
      await expectLater(
        drivers.submitSelfie(''),
        throwsA(
          isA<DriverAuthFailure>()
              .having((e) => e.message, 'message', 'No selfie was captured'),
        ),
      );
    });

    test('a path that does not exist is refused', () async {
      await expectLater(
        drivers.submitSelfie('/nonexistent/selfie.jpg'),
        throwsA(
          isA<DriverAuthFailure>().having(
            (e) => e.message,
            'message',
            'The selfie could not be read back',
          ),
        ),
      );
    });
  });

  group('the earnings repository refuses an empty withdrawal before any call',
      () {
    test('zero', () async {
      final repo = SupabaseEarningsRepository(
        SupabaseClient('http://localhost:54321', 'anon-key'),
      );
      await expectLater(
        repo.requestPayout(amountGhs: 0),
        throwsA(
          isA<PayoutFailure>().having(
            (e) => e.message,
            'message',
            'Enter an amount greater than zero',
          ),
        ),
      );
    });
  });
}
