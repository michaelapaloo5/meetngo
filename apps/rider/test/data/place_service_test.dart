import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mng_core/mng_core.dart';
import 'package:meetngo_rider/src/data/place_service.dart';

/// Answers from a script instead of the network.
///
/// The geocoder is the one place in the rider app that calls a third party, and
/// a test that reached Nominatim for real would be slow, flaky, and would be
/// making requests to a volunteer-run shared service on every run -- which is
/// precisely the use its usage policy does not want.
class _FakeClient extends http.BaseClient {
  _FakeClient(this.respond);

  final Future<http.Response> Function(http.Request request) respond;

  /// Every request made, so "asked once" and "sent a User-Agent" are assertions
  /// rather than assumptions.
  final List<http.Request> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final recorded = http.Request(request.method, request.url)
      ..headers.addAll(request.headers);
    requests.add(recorded);
    final response = await respond(recorded);
    return http.StreamedResponse(
      Stream.value(utf8.encode(response.body)),
      response.statusCode,
    );
  }
}

http.Response _json(Object body, {int status = 200}) =>
    http.Response(jsonEncode(body), status, headers: {
      'content-type': 'application/json',
    });

/// The shape Nominatim actually returns at `zoom=16` for the pilot driver's
/// parked position, 5.6037 / -0.1870.
///
/// Captured from a real request rather than written from imagination, which
/// matters: the first version of this fixture was invented and assumed a
/// `suburb` and a `road` were always present. At `zoom=10` -- the value the
/// service was first called with -- neither is. The parser was correct and the
/// fixture was a fiction, which is why this one is a recording.
Map<String, dynamic> _recordedResponse() => {
      'lat': '5.6037000',
      'lon': '-0.1870000',
      'display_name':
          'Patrice Lumumba Road, Airport Residential Area, Accra, '
              'Ayawaso West Municipal District, Greater Accra Region, Ghana',
      'address': {
        'road': 'Patrice Lumumba Road',
        'suburb': 'Airport Residential Area',
        'city': 'Accra',
        'county': 'Ayawaso West Municipal District',
        'state': 'Greater Accra Region',
        'ISO3166-2-lvl4': 'GH-AA',
        'country': 'Ghana',
        'country_code': 'gh',
      },
    };

void main() {
  group('PlaceName.line', () {
    test('street leads, then locality, then country', () {
      const place = PlaceName(
        locality: 'Accra',
        country: 'Ghana',
        thoroughfare: 'Oxford Street',
      );
      expect(place.line, 'Oxford Street, Accra, Ghana');
    });

    // Nominatim returns the same string in `city` and in the field this maps to
    // for many places, and printing it twice reads like a bug in the app.
    test('a country that repeats the locality is not printed twice', () {
      const place = PlaceName(locality: 'Ghana', country: 'Ghana');
      expect(place.line, 'Ghana');
    });

    test('a blank street is skipped rather than leaving a leading comma', () {
      const place = PlaceName(locality: 'Osu', thoroughfare: '');
      expect(place.line, 'Osu');
    });

    test('a place with only a locality still renders', () {
      expect(const PlaceName(locality: 'Osu').line, 'Osu');
    });
  });

  group('NominatimPlaceService', () {
    test('reads the road, locality and country out of a recorded response', () async {
      final client = _FakeClient((_) async => _json(_recordedResponse()));
      final service = NominatimPlaceService(client: client);

      final place = await service.reverse(const GeoPoint(5.6037, -0.1870));

      expect(place, isNotNull);
      // The suburb, not the city, and that is the point: the keys are walked
      // most specific first, so a rider in Airport Residential Area is told
      // that rather than the city containing it. Being told "Accra" on a screen
      // in Airport Residential teaches the rider nothing.
      expect(place!.locality, 'Airport Residential Area');
      expect(place.thoroughfare, 'Patrice Lumumba Road');
      expect(place.country, 'Ghana');
      expect(place.administrativeArea, 'Greater Accra Region');
    });

    // The string the rider actually sees, end to end from a recorded body. This
    // is the one a demo will show, so it is asserted literally.
    test('renders the line the rider sees', () async {
      final service = NominatimPlaceService(
        client: _FakeClient((_) async => _json(_recordedResponse())),
      );
      final place = await service.reverse(const GeoPoint(5.6037, -0.1870));
      expect(
        place!.line,
        'Patrice Lumumba Road, Airport Residential Area, Ghana',
      );
    });

    // The zoom is not incidental: it decides whether a road comes back at all.
    // Measured, the same coordinate returns no road below 16 and a house number
    // at 18. Pinning it stops a well-meaning change to a coarser zoom silently
    // reducing the line to "Accra, Ghana".
    test('asks at the zoom that returns a street but not a house number', () async {
      final client = _FakeClient((_) async => _json(_recordedResponse()));
      final service = NominatimPlaceService(client: client);

      await service.reverse(const GeoPoint(5.6037, -0.1870));

      final query = client.requests.single.url.queryParameters;
      expect(query['zoom'], '16');
      expect(query['addressdetails'], '1');
    });

    // A response with no road is the `zoom=10` shape, and it must still render
    // the locality rather than collapsing to nothing.
    test('a response with no road still names the locality', () async {
      final service = NominatimPlaceService(
        client: _FakeClient((_) async => _json({
              'address': {'city': 'Accra', 'country': 'Ghana'},
            })),
      );
      final place = await service.reverse(const GeoPoint(5.6037, -0.1870));
      expect(place!.line, 'Accra, Ghana');
    });

    // The usage policy requires an identifying User-Agent, and a bare one is
    // exactly what that policy is written about.
    test('every request identifies the app in its User-Agent', () async {
      final client = _FakeClient((_) async => _json(_recordedResponse()));
      final service = NominatimPlaceService(client: client);

      await service.reverse(const GeoPoint(5.56, -0.18));

      expect(client.requests, hasLength(1));
      final ua = client.requests.single.headers['User-Agent'] ?? '';
      expect(ua, isNotEmpty);
      expect(ua, contains('meetngo'));
    });

    test('no key, token or app id is sent', () async {
      final client = _FakeClient((_) async => _json(_recordedResponse()));
      final service = NominatimPlaceService(client: client);

      await service.reverse(const GeoPoint(5.56, -0.18));

      final uri = client.requests.single.url;
      expect(uri.queryParameters.keys, isNot(contains('key')));
      expect(uri.queryParameters.values.join(), isNot(contains('Bearer')));
      expect(uri.host, 'nominatim.openstreetmap.org');
    });

    // The policy also caps repeated asking. A rider who backgrounds and returns
    // to the home screen should not spend a request on an answer already held.
    test('the same place is asked for once', () async {
      final client = _FakeClient((_) async => _json(_recordedResponse()));
      final service = NominatimPlaceService(client: client);

      final first =
          await service.reverse(const GeoPoint(5.5600, -0.1800));
      final second =
          await service.reverse(const GeoPoint(5.5600, -0.1800));

      expect(client.requests, hasLength(1));
      expect(second, same(first));
    });

    // A cache that only remembered successes would re-ask about a coordinate
    // the geocoder has already said it cannot name, forever.
    test('a place that could not be named is not asked for again', () async {
      final client = _FakeClient((_) async => _json({'error': 'Unable to geocode'}));
      final service = NominatimPlaceService(client: client);

      expect(await service.reverse(const GeoPoint(1.0, 1.0)), isNull);
      expect(await service.reverse(const GeoPoint(1.0, 1.0)), isNull);
      expect(client.requests, hasLength(1));
    });

    // A geocoder failing is not the rider's problem and must never reach the
    // framework as an unhandled error: the home screen falls back to the
    // coordinates it already has.
    test('a non-200 is a null, not a throw', () async {
      final service = NominatimPlaceService(
        client: _FakeClient((_) async => http.Response('nope', 503)),
      );
      expect(await service.reverse(const GeoPoint(5.56, -0.18)), isNull);
    });

    test('a body that is not JSON is a null, not a throw', () async {
      final service = NominatimPlaceService(
        client: _FakeClient((_) async => http.Response('<html>oops</html>', 200)),
      );
      expect(await service.reverse(const GeoPoint(5.56, -0.18)), isNull);
    });

    test('a response with no address is a null, not a throw', () async {
      final service = NominatimPlaceService(
        client: _FakeClient((_) async => _json({'lat': '5.5', 'lon': '-0.1'})),
      );
      expect(await service.reverse(const GeoPoint(5.56, -0.18)), isNull);
    });

    // `city` is absent where Nominatim uses `town` or `village`, which is common
    // outside a capital city. A parser that only knows `city` returns nothing
    // for a large part of the world.
    test('a village with no city key still resolves', () async {
      final service = NominatimPlaceService(
        client: _FakeClient((_) async => _json({
              'address': {'village': 'Kumasi', 'country': 'Ghana'},
            })),
      );
      final place = await service.reverse(const GeoPoint(6.69, -1.62));
      expect(place!.locality, 'Kumasi');
    });

    test('the most specific locality key wins over the broader one', () async {
      final service = NominatimPlaceService(
        client: _FakeClient((_) async => _json({
              'address': {
                'suburb': 'Osu',
                'city': 'Accra',
                'country': 'Ghana',
              },
            })),
      );
      final place = await service.reverse(const GeoPoint(5.56, -0.18));
      expect(place!.locality, 'Osu');
    });
  });
}
