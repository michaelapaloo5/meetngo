import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:meetngo_rider/src/data/location_service.dart';
import 'package:meetngo_rider/src/data/supabase_trip_repository.dart';

/// The exact body `contact` answered with, captured from the **deployed**
/// function against a real accepted ride, by toolchain/probe-contact.mjs.
///
/// The rider reported that no profile details appeared on the card. They were in
/// this payload the whole time, under `driver`. Two fields -- `name` and `phone`
/// -- are also duplicated at the top level for the other direction, which is why
/// exactly those two rendered and nothing said why the rest were missing.
const liveBody = '''
{
  "role": "driver",
  "phone": "0200000001",
  "callable": true,
  "name": "accept-check driver",
  "driver": {
    "name": "accept-check driver",
    "photoUrl": "",
    "rating": 5,
    "vehicle": {
      "make": "Toyota",
      "model": "Corolla",
      "plate": "ACCEPT-CHECK"
    }
  }
}
''';

/// Builds the real repository over a fake transport.
///
/// A real `SupabaseClient` rather than a stand-in for one, because the two bugs
/// this file exists for were both in the seam between the function's HTTP answer
/// and what the repository reads out of it: reading the response instead of
/// `.data`, and reading the payload flat. A hand-written fake of the *parsed*
/// shape would have stayed green through both.
SupabaseTripRepository _repo(String payload) {
  final client = SupabaseClient(
    'https://probe.supabase.co',
    'anon-key-not-used',
    httpClient: MockClient((request) async {
      if (!request.url.path.contains('/functions/v1/contact')) {
        return http.Response('{}', 404);
      }
      return http.Response(
        payload,
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
  );
  return SupabaseTripRepository(client, locations: const _NoLocation());
}

class _NoLocation implements LocationService {
  const _NoLocation();

  @override
  Future<DeviceLocation> current() async =>
      const DeviceLocation(LocationOutcome.denied);
}

void main() {
  test('the real read draws the car out of the nested driver object', () async {
    final c = await _repo(liveBody).driverContact('trip-1');
    expect(c.name, 'accept-check driver');
    expect(c.carMake, 'Toyota');
    expect(c.carModel, 'Corolla');
    expect(c.car, 'Toyota Corolla');
    expect(
      c.plate,
      'ACCEPT-CHECK',
      reason: 'the plate is the thing a rider looks for at the rank',
    );
    expect(
      c.hasCar,
      isTrue,
      reason: 'the card keys off this, and it was false for every real driver',
    );
    expect(c.rating, 5.0);
  });

  test('the phone and callable flag still come from the top level', () async {
    final c = await _repo(liveBody).driverContact('trip-1');
    expect(c.phone, '0200000001');
    expect(c.callable, isTrue);
  });

  test('the photo comes from the nested object', () async {
    final c = await _repo(
      jsonEncode({
        'role': 'driver',
        'phone': '0200000001',
        'callable': true,
        'name': 'Someone',
        'driver': {
          'name': 'Someone',
          'photoUrl': 'https://example.test/p.jpg',
          'rating': 4.5,
        },
      }),
    ).driverContact('trip-1');
    expect(c.photoUrl, 'https://example.test/p.jpg');
    expect(c.rating, 4.5);
  });

  test('a driver with no vehicle is not an error', () async {
    final c = await _repo(
      jsonEncode({
        'role': 'driver',
        'phone': '',
        'callable': false,
        'name': 'Someone',
        'driver': {'name': 'Someone', 'photoUrl': ''},
      }),
    ).driverContact('trip-1');
    expect(c.name, 'Someone');
    expect(c.hasCar, isFalse);
    expect(c.rating, isNull);
    expect(c.callable, isFalse);
  });

  test('a flat payload still reads', () async {
    // The fallback is what the duplicated top-level fields are for, so a shape
    // that is ever flattened again does not blank the card.
    final c = await _repo(
      jsonEncode({
        'name': 'Someone',
        'phone': '0200000001',
        'callable': true,
        'photoUrl': 'https://example.test/p.jpg',
        'rating': 4.5,
        'vehicle': {'make': 'Kia', 'model': 'Rio', 'plate': 'GA-1234'},
      }),
    ).driverContact('trip-1');
    expect(c.car, 'Kia Rio');
    expect(c.plate, 'GA-1234');
    expect(c.rating, 4.5);
    expect(c.photoUrl, 'https://example.test/p.jpg');
  });

  test('a malformed vehicle does not take the card down', () async {
    final c = await _repo(
      jsonEncode({
        'name': 'Someone',
        'phone': '0200000001',
        'driver': {'vehicle': 'not an object'},
      }),
    ).driverContact('trip-1');
    expect(c.name, 'Someone');
    expect(c.hasCar, isFalse);
  });
}
