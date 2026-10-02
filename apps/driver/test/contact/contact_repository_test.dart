import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_driver/src/contact/contact_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FunctionException;

/// The one layer that actually talks to Supabase for a contact.
///
/// Written because this had no test at all, which is the whole reason a real bug
/// shipped in it. `contact_sheet_test.dart` covers the sheet and the controller
/// against a stub repository; `supabase/functions/_tests/contact.test.ts` covers
/// the handler against fake ports; `toolchain/verify-contact.mjs` calls the
/// deployed HTTP endpoint. Every one of those is real except this file, and this
/// file is where the client library's return type is interpreted -- so it is where
/// `invoke` answering a `FunctionResponse` rather than a `Map` could turn every
/// lookup into a throw, which is exactly what happened.

/// Shaped like `functions_client`'s `FunctionResponse`: a wrapper carrying the
/// decoded payload on `data`.
///
/// Deliberately *not* a Map, though the old bug would have passed a Map. A fake
/// that returns a bare Map is what let the mistake through twice: the Deno stub
/// returned one, this file did not exist, and the HTTP verifier never came near
/// it.
class _FunctionResponse {
  _FunctionResponse(this.data);
  final Object? data;
}

class _FakeFunctions {
  _FakeFunctions(this.answer);

  /// What `invoke` hands back.
  final Object answer;

  /// Thrown instead of answered, for the non-2xx path.
  Object? throws;

  int calls = 0;
  Map<String, dynamic>? lastBody;
  String? lastName;

  Future<Object> invoke(String name, {Map<String, dynamic>? body}) async {
    calls++;
    lastName = name;
    lastBody = body;
    final t = throws;
    if (t != null) throw t;
    return answer;
  }
}

class _FakeClient {
  _FakeClient(this.functions);
  final _FakeFunctions functions;
}

void main() {
  const good = {
    'role': 'rider',
    'phone': '0241234567',
    'callable': true,
    'name': 'Ama',
  };

  group('SupabaseContactRepository', () {
    test(
      'reads the payload off the response, not the response itself',
      () async {
        // The regression. `invoke` returns a `FunctionResponse`, and the payload is
        // on `.data`. Reading the response and asking whether it was a Map threw on
        // every call, so Call stayed blurred and flickered for the whole trip.
        final functions = _FakeFunctions(_FunctionResponse(good));
        final repo = SupabaseContactRepository(_FakeClient(functions));

        final contact = await repo.contactFor('trip-1');

        expect(contact, isNotNull, reason: 'the number must reach the driver');
        expect(contact!.phone, '0241234567');
        expect(contact.role, ContactRole.rider);
        expect(functions.calls, 1);
        expect(functions.lastName, 'contact');
        expect(functions.lastBody, {'tripId': 'trip-1'});
      },
    );

    test('a rider with no number is an answer, not a failure', () async {
      final functions = _FakeFunctions(
        _FunctionResponse({
          'role': 'rider',
          'phone': '',
          'callable': false,
          'name': 'Ama',
        }),
      );
      final repo = SupabaseContactRepository(_FakeClient(functions));

      final contact = await repo.contactFor('trip-1');

      expect(contact, isNotNull);
      expect(contact!.callable, isFalse);
    });

    test('a 200 that is not a contact is refused, loudly', () async {
      // A server fault and "no contact" must not read the same, or the driver is
      // told there is nobody to call when the service is broken.
      final functions = _FakeFunctions(_FunctionResponse({'unexpected': true}));
      final repo = SupabaseContactRepository(_FakeClient(functions));

      expect(() => repo.contactFor('trip-1'), throwsA(isA<ContactFailure>()));
    });

    test('a trip the driver is not on is null with no message', () async {
      // The server collapses "no such trip" and "not on this trip" into one 404,
      // and the client must not turn that into an error the driver sees.
      final functions = _FakeFunctions(_FunctionResponse(good))
        ..throws = const FunctionException(
            status: 404,
            details: {'error': 'no such trip'},
          );
      final repo = SupabaseContactRepository(_FakeClient(functions));

      expect(await repo.contactFor('trip-1'), isNull);
    });

    test('a real fault surfaces as a ContactFailure', () async {
      final functions = _FakeFunctions(_FunctionResponse(good))
        ..throws = const FunctionException(status: 500, details: {'error': 'boom'});
      final repo = SupabaseContactRepository(_FakeClient(functions));

      await expectLater(
        () => repo.contactFor('trip-1'),
        throwsA(isA<ContactFailure>()),
      );
    });

    test('a response with no data at all is refused', () {
      final functions = _FakeFunctions(_FunctionResponse(null));
      final repo = SupabaseContactRepository(_FakeClient(functions));

      expect(() => repo.contactFor('trip-1'), throwsA(isA<ContactFailure>()));
    });
  });
}
