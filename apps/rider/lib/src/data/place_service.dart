import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mng_core/mng_core.dart';

/// A place name for a coordinate, and the parts it was assembled from.
///
/// Kept as fields rather than one pre-joined string so a screen can choose its
/// own shape: the home line wants one line, a receipt wants a fuller address,
/// and neither should have to re-parse a string another layer built.
class PlaceName {
  const PlaceName({
    required this.locality,
    this.administrativeArea,
    this.country,
    this.thoroughfare,
  });

  /// The town or city. 'Osu' for a point inside Osu, 'Accra' for one north of
  /// it, and so on -- whatever the geocoder considers most locally meaningful.
  final String locality;

  /// The region or county, when it differs from [locality].
  final String? administrativeArea;

  /// The country name, from the geocoder rather than assumed.
  final String? country;

  /// The street or road name, when the point is on one.
  final String? thoroughfare;

  /// One line, most specific first, skipping anything missing.
  ///
  /// [thoroughfare] leads when there is one, so a rider on a real street is
  /// told the street rather than only the town. The region is left out when it
  /// repeats [locality], which Nominatim does often -- both fields say "Accra"
  /// for a point in Accra, and printing it twice reads like a bug.
  ///
  /// Empty is treated as missing everywhere, not just null. The geocoder's own
  /// JSON carries `"country": ""` for a point it could not place in a country,
  /// and a null-only guard turned that into an address ending in a bare ", " --
  /// which then got stored on the trip and read out to a driver at the pickup.
  /// The parts are therefore filtered for emptiness rather than for null.
  String get line {
    String? usable(String? value) =>
        (value != null && value.isNotEmpty) ? value : null;
    final street = usable(thoroughfare);
    final where = usable(locality);
    final parts = <String>[
      ?street,
      ?where,
      if (usable(country) != null && country != where) country!,
    ].where((p) => p.isNotEmpty).toList();
    return parts.isEmpty ? locality : parts.join(', ');
  }
}

/// One candidate from a place search, ready to be offered to a rider.
class PlaceSuggestion {
  const PlaceSuggestion({
    required this.label,
    required this.point,
  });

  /// What the rider reads in the list. Nominatim's own `display_name` is
  /// accurate but long -- "Patrice Lumumba Road, Airport Residential Area,
  /// Accra, Ayawaso West Municipal District, Greater Accra Region, Ghana" --
  /// which wraps to four lines in a dropdown. Truncated to the named parts.
  final String label;

  final GeoPoint point;
}

/// The shortest query [PlaceService.search] will act on.
///
/// Below this a query is a prefix rather than a place, and Nominatim answers a
/// prefix with speculative matches that all look like real results. It lives
/// here rather than on the implementation so a caller can decide when to fire
/// a search without depending on which geocoder is behind it.
const kMinPlaceSearchChars = 3;

abstract class PlaceService {
  /// The place name for [point], or null when none could be resolved.
  Future<PlaceName?> reverse(GeoPoint point);

  /// Places matching [query], best first, or an empty list.
  Future<List<PlaceSuggestion>> search(String query);
}

/// Reverse geocoding over OpenStreetMap's Nominatim, which needs no key, no
/// account and no card.
///
/// Nominatim was chosen because it is the only geocoder that satisfies all
/// three of this project's constraints at once. Google Geocoding needs an API
/// key on a billing-enabled project, which is the thing this repo is built to
/// avoid. `geolocator` 13.0.4 has no `placemarkFromCoordinates` -- checked in
/// the package source, not assumed -- so there is no free platform geocoder to
/// reach for either. Nominatim fills the last gap.
///
/// It is a shared, volunteer-run service and its usage policy is a real
/// constraint on this code, so the policy is respected rather than merely
/// acknowledged:
///
/// - a descriptive `User-Agent`, which the policy requires and which is how
///   the operators identify who is calling;
/// - one request per place, cached, so a rider reopening the home screen does
///   not re-ask for an answer already held;
/// - a short timeout, so a slow or refused lookup degrades to "no name" and
///   never leaves the home screen waiting on a third party;
/// - no batching and no autocomplete, which are the two things the policy names
///   as unacceptable.
///
/// The policy is written against bulk and commercial use. A pilot with a
/// handful of riders, one cached lookup each, is well inside that, but this is
/// the seam to replace if the pilot grows: [PlaceService] is an interface and
/// the only production implementation is this one file.
class NominatimPlaceService implements PlaceService {
  NominatimPlaceService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// The free public endpoint. No key, no signup.
  static final Uri _endpoint = Uri.parse(
    'https://nominatim.openstreetmap.org/reverse',
  );

  /// Forward search, same service.
  static final Uri _searchEndpoint = Uri.parse(
    'https://nominatim.openstreetmap.org/search',
  );

  /// Below this, a query is not a place but a prefix of one, and Nominatim
  /// will happily return a handful of speculative matches for "Osu J" that all
  /// look like real answers. Two characters matches most of a city.
  static const int kMinSearchChars = kMinPlaceSearchChars;

  /// How many results to offer. More than five is noise in a dropdown.
  static const int kSearchLimit = 5;

  /// Identifying the caller, as the usage policy requires.
  ///
  /// A bare package name would not tell the operators who is calling, which is
  /// the whole reason the header exists.
  static const String userAgent =
      "Meet 'N Go rider app (com.meetngo.rider); reverse geocoding for a ride-hailing pilot";

  static const Duration _timeout = Duration(seconds: 6);

  /// Answered once per distinct place.
  ///
  /// Keyed on the coordinate rounded to about 11m, which is finer than any
  /// fix this app can act on and coarse enough that a rider standing still does
  /// not accumulate entries.
  final Map<String, PlaceName?> _cache = {};

  @override
  Future<PlaceName?> reverse(GeoPoint point) async {
    final key = '${point.lat.toStringAsFixed(5)},'
        '${point.lng.toStringAsFixed(5)}';
    if (_cache.containsKey(key)) return _cache[key];

    final resolved = await _lookup(point);
    _cache[key] = resolved;
    return resolved;
  }

  @override
  Future<List<PlaceSuggestion>> search(String query) async {
    final q = query.trim();
    if (q.length < kMinSearchChars) return const [];
    final uri = _searchEndpoint.replace(queryParameters: {
      'q': q,
      'format': 'jsonv2',
      'limit': '$kSearchLimit',
      // The rider is looking for somewhere to be picked up or dropped off
      // inside a city, not a country or a continent. Without these a search for
      // "airport" returns Heathrow, ORD and a runway in Kazakhstan.
      'addressdetails': '1',
    });
    try {
      final response = await _client
          .get(uri, headers: {'User-Agent': userAgent})
          .timeout(_timeout);
      if (response.statusCode != 200) return const [];
      return _parseSearch(response.body);
    } on Object {
      // Same contract as [reverse]: a geocoder that is down is not an error
      // the rider caused, and it must not reach the framework.
      return const [];
    }
  }

  List<PlaceSuggestion> _parseSearch(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! List) return const [];
    final out = <PlaceSuggestion>[];
    for (final entry in decoded) {
      if (entry is! Map<String, dynamic>) continue;
      final lat = entry['lat'];
      final lon = entry['lon'];
      if (lat is! String || lon is! String) continue;
      final dLat = double.tryParse(lat);
      final dLon = double.tryParse(lon);
      if (dLat == null || dLon == null) continue;
      if (dLat.abs() > 90 || dLon.abs() > 180) continue;
      final name = entry['name'];
      final display = entry['display_name'];
      out.add(PlaceSuggestion(
        label: _shortLabel(
          name is String && name.isNotEmpty ? name : null,
          display is String ? display : null,
        ),
        point: GeoPoint(dLat, dLon),
      ));
    }
    return out;
  }

  /// A label short enough for a dropdown row.
  ///
  /// Nominatim's `display_name` is a comma-joined path from the building to the
  /// country and is routinely four lines long. The named place plus the next two
  /// parts is what a rider recognises: "Osu, Accra, Ghana" rather than the
  /// full administrative path.
  static String _shortLabel(String? name, String? displayName) {
    final parts = (displayName ?? '')
        .split(',')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return name ?? '';
    // When the geocoder named the place, that name is the most specific and
    // most useful part, so it leads even if `display_name` did not repeat it.
    final head = name != null && !parts.contains(name) ? name : parts.first;
    final tail = parts.where((p) => p != head).take(2);
    return [head, ...tail].join(', ');
  }

  Future<PlaceName?> _lookup(GeoPoint point) async {
    final uri = _endpoint.replace(queryParameters: {
      'format': 'jsonv2',
      'lat': point.lat.toString(),
      'lon': point.lng.toString(),
      // 16 is chosen from measured responses, not guessed, because the answer
      // changes completely with it. For the pilot driver's parked position
      // (5.6037, -0.1870), Nominatim returns:
      //
      //   zoom 10 -> "Accra" and nothing else. No suburb, no road. The home
      //               line would read "Accra, Ghana" for a rider standing in
      //               Airport Residential Area, which is true and useless.
      //   zoom 12 -> the suburb ("Airport Residential Area") but still no road.
      //   zoom 16 -> the road *and* the suburb, no house number. This is the
      //               one used: "Patrice Lumumba Road, Airport Residential
      //               Area, Ghana".
      //   zoom 18 -> adds a house number. Which is the most precise answer
      //               available and also the one to be most careful about
      //               putting on a screen, so it is not used.
      //
      // 16 is also finer than the accuracy of any fix this app acts on, so it
      // is not claiming a street the rider is not on.
      'zoom': '16',
      'addressdetails': '1',
    });

    try {
      final response = await _client
          .get(uri, headers: {'User-Agent': userAgent})
          .timeout(_timeout);
      if (response.statusCode != 200) return null;
      return _parse(response.body);
    } on Object {
      // A timeout, a refused connection, a malformed body: all of them mean the
      // same thing to this screen, which is that there is no name to show and
      // the coordinates are what it has. Swallowed on purpose -- a geocoder
      // failing is not an error the rider did anything about, and letting it
      // reach the framework would fail a test whose subject is the home screen.
      return null;
    }
  }

  PlaceName? _parse(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return null;
    final address = decoded['address'];
    if (address is! Map<String, dynamic>) return null;

    // Nominatim's vocabulary, most specific first. `city` is absent in some
    // places where `town` or `village` is used instead, which is exactly the
    // case a hard-coded "city" key would drop on the floor.
    const keys = <String>[
      'suburb',
      'neighbourhood',
      'town',
      'village',
      'city',
      'municipality',
      'county',
      'state',
    ];
    String? locality;
    for (final key in keys) {
      final value = address[key];
      if (value is String && value.isNotEmpty) {
        locality = value;
        break;
      }
    }
    if (locality == null) return null;

    String? named(String key) {
      final value = address[key];
      return (value is String && value.isNotEmpty) ? value : null;
    }

    return PlaceName(
      locality: locality,
      administrativeArea: named('state') ?? named('region'),
      country: named('country'),
      thoroughfare: named('road') ?? named('pedestrian') ?? named('footway'),
    );
  }

  void close() => _client.close();
}
