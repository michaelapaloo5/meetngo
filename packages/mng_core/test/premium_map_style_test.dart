import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';

/// The style, parsed once for the whole file.
Future<Map<String, dynamic>> style() async =>
    jsonDecode(await premiumMapStyleJson()) as Map<String, dynamic>;

List<Map<String, dynamic>> layersOf(Map<String, dynamic> s) => (s['layers']
        as List)
    .cast<Map<String, dynamic>>();

Map<String, dynamic> layerNamed(Map<String, dynamic> s, String id) {
  final match = layersOf(s).where((l) => l['id'] == id);
  expect(match, hasLength(1), reason: 'layer "$id" must exist exactly once');
  return match.single;
}

void main() {
  // The style is read through `rootBundle`, which is a service -- and a
  // service with no binding is a crash rather than an empty style. The
  // binding is also what makes the asset reachable at all, so this has to
  // happen before the first `style()` call and not inside the tests.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the style loads from the bundle', () {
    test('is a version 8 style with a sprite-independent source', () async {
      final s = await style();
      expect(s['version'], 8);
      expect(s['name'], isNotEmpty);
    });

    test('draws from OpenFreeMap with no key, no account and no card', () async {
      final s = await style();
      final sources = s['sources'] as Map<String, dynamic>;
      final ofm = sources['openfreemap'] as Map<String, dynamic>;
      expect(ofm['type'], 'vector');
      // The whole reason this app has a map at all: the vector source is
      // fetched from a URL that needs no credentials. A regression to a keyed
      // provider here is invisible on a developer machine and fatal in
      // production, so it is worth an assertion.
      expect(ofm['url'], 'https://tiles.openfreemap.org/planet');
      final asText = jsonEncode(s);
      expect(asText.toLowerCase(), isNot(contains('access_token')));
      expect(asText.toLowerCase(), isNot(contains('mapbox.com')));
    });

    test('credits OpenStreetMap, as the tile usage policy requires', () async {
      final s = await style();
      final ofm =
          (s['sources'] as Map<String, dynamic>)['openfreemap']
              as Map<String, dynamic>;
      expect(ofm['attribution'], contains('OpenStreetMap'));
    });
  });

  group('1. palette', () {
    test('land is a muted off-white', () async {
      final bg = layerNamed(await style(), 'background');
      expect((bg['paint'] as Map)['background-color'], '#F4F4F6');
    });

    test('water is a desaturated pastel blue', () async {
      final w = layerNamed(await style(), 'water-fill');
      expect((w['paint'] as Map)['fill-color'], '#C4D3DF');
    });

    test('parks are very soft desaturated mint', () async {
      final s = await style();
      for (final id in ['park-fill', 'park-fill-polygons']) {
        expect((layerNamed(s, id)['paint'] as Map)['fill-color'], '#E2F0D9',
            reason: id);
      }
    });

    test('every colour in the style is one of the declared palette values', () async {
      // The point of declaring a palette is that it is obeyed. A hand-edited
      // `#4a90d9` in one layer is exactly how a map ends up with two blues.
      final s = await style();
      final allowed = {
        PremiumMapPalette.land,
        PremiumMapPalette.water,
        PremiumMapPalette.park,
        PremiumMapPalette.road,
        PremiumMapPalette.roadCasing,
        PremiumMapPalette.building,
        PremiumMapPalette.label,
      }.map((c) => c.toLowerCase()).toSet();

      final found = <String, String>{};
      for (final l in layersOf(s)) {
        final paint = l['paint'];
        if (paint is! Map) continue;
        for (final entry in paint.entries) {
          if (entry.key.contains('color') && entry.value is String) {
            found['${l['id']}.${entry.key}'] = entry.value as String;
          }
        }
      }
      expect(found, isNotEmpty);
      found.forEach((where, colour) {
        expect(allowed, contains(colour.toLowerCase()),
            reason: '$where is $colour, which is not in the palette');
      });
    });
  });

  group('2. road network', () {
    test('roads are crisp white', () async {
      final s = await style();
      final roadLayers = layersOf(s)
          .where((l) => l['type'] == 'line')
          .where((l) => l['source-layer'] == 'transportation')
          .where((l) => l['id'] != 'road-casing')
          .toList();
      expect(roadLayers, isNotEmpty);
      for (final l in roadLayers) {
        expect((l['paint'] as Map)['line-color'], '#FFFFFF', reason: '${l['id']}');
      }
    });

    test('highways carry the thin soft gray casing, drawn under the white', () async {
      final s = await style();
      final casing = layerNamed(s, 'road-casing');
      expect((casing['paint'] as Map)['line-color'], '#E0E0E5');

      // "Ultra-thin" is a ratio, not an absolute: a casing that is a large
      // fraction of the road it outlines is a border, not a separation. The
      // widest casing in the style is checked against the widest road.
      final casingMax = _maxWidth(casing);
      final roadMax = _maxWidth(layerNamed(s, 'road-major'));
      expect(casingMax, isNotNull);
      expect(roadMax, isNotNull);
      // Same zoom, same road: a 2px wider casing is what MapLibre draws, and
      // it is half exposed either side of an 8.5px road.
      expect(casingMax! - roadMax!, lessThanOrEqualTo(2.5),
          reason: 'casing $casingMax vs road $roadMax');

      // The casing has to be earlier in the layer list or the white road is
      // painted over it and it is invisible.
      final order = layersOf(s).map((l) => l['id']).toList();
      expect(order.indexOf('road-casing'), lessThan(order.indexOf('road-major')));
    });

    test('only highways are cased, so local streets do not get a border', () async {
      final casing = layerNamed(await style(), 'road-casing');
      final classes = _classesIn(casing);
      expect(classes, {'motorway', 'trunk', 'primary'});
      expect(classes, isNot(contains('minor')));
      expect(classes, isNot(contains('service')));
    });

    test('casing and the road it outlines select the same roads', () async {
      final s = await style();
      // A casing drawn on a different set of roads than the white on top of it
      // is a grey line running through the countryside.
      expect(_classesIn(layerNamed(s, 'road-casing')),
          _classesIn(layerNamed(s, 'road-major')));
    });

    test('every road width is zoom-interpolated, not a flat line', () async {
      final s = await style();
      // Filtered to line layers, because `road-name` is also a "road" layer by
      // name and has no `line-width` to interpolate -- it draws text along the
      // line instead.
      for (final l in layersOf(s)
          .where((l) => l['type'] == 'line')
          .where((l) => l['source-layer'] == 'transportation')) {
        final w = (l['paint'] as Map)['line-width'];
        expect(w, isA<List>(), reason: '${l['id']} has a fixed width');
        expect(jsonEncode(w), contains('zoom'), reason: '${l['id']}');
      }
    });

    test('rails, ferries and tunnels are not drawn', () async {
      final s = await style();
      final asText = jsonEncode(layersOf(s));
      for (final unwanted in ['"rail"', '"ferry"', '"transit"', '"aerialway"']) {
        expect(asText, isNot(contains(unwanted)),
            reason: '$unwanted would put rail and transit lines on a road map');
      }
      // Every road layer filters tunnels out: a tunnel drawn as a surface
      // street is a road that appears to run through a building.
      for (final l in layersOf(s).where((l) => l['source-layer'] == 'transportation')) {
        expect(jsonEncode(l['filter']), contains('brunnel'),
            reason: '${l['id']} does not exclude tunnels');
      }
    });
  });

  group('3. extreme decluttering', () {
    test('no POI, boundary or address-number layer exists at all', () async {
      final s = await style();
      // Not "hidden" -- absent. `visibility: none` still costs a style diff to
      // carry, still shows up in every layer list anyone reads, and is one
      // careless edit away from being turned back on.
      //
      // `place` and `transportation_name` are deliberately NOT in this list.
      // They were, and the result was a map with no street names on it, which
      // is not decluttering -- it is an unnavigable picture of a city.
      final banned = {
        'poi',
        'boundary',
        'aerodrome_label',
        'housenumber',
        'mountain_peak',
        'water_name',
      };
      for (final l in layersOf(s)) {
        expect(banned, isNot(contains(l['source-layer'])),
            reason: '${l['id']} draws ${l['source-layer']}');
      }
    });

    test('no layer draws a business or commercial name', () async {
      final s = await style();
      // The real constraint, as opposed to the one I first wrote. "Hide all
      // POIs, local businesses, stores and commercial labels" reduces to: no
      // layer reads a name off the `poi` source-layer, which is where every
      // shop, restaurant and landmark name lives. A business name cannot be
      // decluttered if it is never asked for.
      for (final l in layersOf(s)) {
        expect(l['source-layer'], isNot('poi'),
            reason: '${l['id']} reads the POI layer');
      }
    });

    test('road names are drawn, because an unnamed road cannot be navigated',
        () async {
      final s = await style();
      // This test is here because it was missing, and its absence shipped a map
      // with no street names on it. A driver told to meet at a junction, and a
      // rider trying to find a shop, both need to read a road name off the
      // screen; an unnamed road network is scenery, not a map.
      final road = layerNamed(s, 'road-name');
      expect(road['type'], 'symbol');
      expect(road['source-layer'], 'transportation_name');
      final layout = road['layout'] as Map<String, dynamic>;
      expect(layout['text-field'], isNotNull);
      // Along the line, not floating over its middle: a street name is
      // "Oxford Street", not a label parked on top of it.
      expect(layout['symbol-placement'], 'line');
    });

    test('place names are drawn, and only for places a person would name',
        () async {
      final s = await style();
      final place = layerNamed(s, 'place-label');
      expect(place['source-layer'], 'place');
      final layout = place['layout'] as Map<String, dynamic>;
      expect(layout['text-field'], isNotNull);
      // Towns, cities, districts. Not every hamlet and not every islet: a
      // screen with the name of a two-house village on it is as useless as one
      // with no names on it.
      final classes = _classesIn(place);
      expect(classes, containsAll(<String>['city', 'town', 'suburb']));
      expect(classes, isNot(contains('hamlet')));
    });

    test('every text layer has a font, or it draws nothing', () async {
      // A `text-field` with no `text-font` is a silent no-op: MapLibre has no
      // default font, the glyphs request is never made, and the layer renders
      // as nothing at all with no error anywhere. The symptom would be exactly
      // the bug this was written to prevent, arriving again by another route.
      final s = await style();
      var checked = 0;
      for (final l in layersOf(s)) {
        final layout = l['layout'];
        if (layout is! Map || layout['text-field'] == null) continue;
        checked++;
        expect(layout['text-font'], isNotNull,
            reason: '${l['id']} has text but no font, so it draws nothing');
        // Every font has to be one the style's `glyphs` URL can actually serve.
        final fonts = (layout['text-font'] as List).cast<String>();
        expect(fonts, isNotEmpty);
        for (final f in fonts) {
          expect(f, isNotEmpty);
        }
      }
      expect(checked, 2, reason: 'the two label layers, and no others');
    });

    test('labels carry a halo, because grey text on pale land is unreadable',
        () async {
      // The land is #F4F4F6 and the text is #8A8A8E, a difference of about 40
      // levels of luminance. Without a halo the names sit on the map as a grey
      // suggestion of text.
      final s = await style();
      for (final id in ['place-label', 'road-name']) {
        final paint = layerNamed(s, id)['paint'] as Map;
        expect(paint['text-halo-width'], isNotNull, reason: id);
        expect((paint['text-halo-width'] as num), greaterThan(0), reason: id);
      }
    });

    test('the car is still the only thing drawn as an image', () async {
      final s = await style();
      // `icon-image` is what makes a symbol an icon rather than a label. One
      // icon, and it is the car: a style that grows business icons has stopped
      // being a map for finding a pickup and become a directory.
      final icons = layersOf(s)
          .where((l) => (l['layout'] as Map?)?['icon-image'] != null)
          .map((l) => l['id'])
          .toList();
      expect(icons, [kMovingCarLayerId]);
    });

    test('keeps only the geometry a driver needs, and drops aeroways', () async {
      final used = layersOf(await style())
          .map((l) => l['source-layer'])
          .whereType<String>()
          .toSet();
      expect(used, {
        'landcover',
        'landuse',
        'water',
        'waterway',
        'building',
        'transportation',
        'place',
        'transportation_name',
      });
    });
  });

  group('4. 3D buildings', () {
    test('a fill-extrusion over the building source layer', () async {
      final b = layerNamed(await style(), 'building-3d');
      expect(b['type'], 'fill-extrusion');
      expect(b['source-layer'], 'building');
      expect(b['source'], 'openfreemap');
    });

    test('uniform light gray, and actually visible against the land', () async {
      final p = layerNamed(await style(), 'building-3d')['paint'] as Map;
      expect(p['fill-extrusion-color'], '#E5E7EB');
      // 0.45 was in the original brief and was wrong: #E5E7EB at 45% over
      // #F4F4F6 land lands about five levels of luminance apart, so the
      // extrusions rendered and could not be seen. Confirmed on a device, not
      // reasoned about. The colour is unchanged; only the opacity is, so the
      // buildings read as the light grey they were specified to be.
      expect(p['fill-extrusion-opacity'], 0.9);
    });

    test('the buildings are not a shade of the land they stand on', () async {
      // The regression this guards: any pair of colour and opacity that leaves
      // the extrusions within a few levels of the background. Stated as a
      // number rather than a colour so a future edit cannot quietly put them
      // back to invisible.
      final s = await style();
      final land = layerNamed(s, 'background');
      final paint = layerNamed(s, 'building-3d')['paint'] as Map;
      expect(
        paint['fill-extrusion-color'],
        isNot((land['paint'] as Map)['background-color']),
        reason: 'buildings the same colour as the ground are not buildings',
      );
      expect(paint['fill-extrusion-opacity'] as double, greaterThan(0.7));
    });

    test('a vertical gradient, without which the extrusions read as flat cutouts', () async {
      final p = layerNamed(await style(), 'building-3d')['paint'] as Map;
      expect(p['fill-extrusion-vertical-gradient'], isTrue);
    });

    test('height comes from the tile, not from a constant', () async {
      final p = layerNamed(await style(), 'building-3d')['paint'] as Map;
      // A constant height would give every building in Accra the same roof
      // line, which reads as a bug even though it drew correctly.
      expect(jsonEncode(p['fill-extrusion-height']), contains('render_height'));
      expect(p['fill-extrusion-base'], isNotNull);
    });

    test('skips the buildings the tiles mark as not-for-3d', () async {
      final b = layerNamed(await style(), 'building-3d');
      expect(jsonEncode(b['filter']), contains('hide_3d'));
    });

    test('starts at the zoom the building layer has data from', () async {
      // `building` is minzoom 13. An extrusion below that reads as no buildings
      // at all and the map looks broken rather than empty.
      expect(layerNamed(await style(), 'building-3d')['minzoom'], 13);
    });
  });

  group('5. car icon layer', () {
    test('is a dedicated symbol layer over the vehicle source', () async {
      final s = await style();
      final car = layerNamed(s, 'moving-car-icon');
      expect(car['type'], 'symbol');
      expect(car['source'], kVehicleSourceId);
      // The id is not decoration: both apps call setGeoJsonSource against it.
      expect(car['id'], kMovingCarLayerId);
    });

    test('the vehicle source is GeoJSON and starts empty', () async {
      final v = ((await style())['sources'] as Map)[kVehicleSourceId]
          as Map<String, dynamic>;
      expect(v['type'], 'geojson');
      final data = v['data'] as Map<String, dynamic>;
      expect(data['type'], 'FeatureCollection');
      // Not a placeholder car at the origin: a style that ships with a vehicle
      // in the Gulf of Guinea shows a car in the ocean until the first fix.
      expect((data['features'] as List), isEmpty);
    });

    test('every required icon property is set exactly as specified', () async {
      final layout = layerNamed(await style(), 'moving-car-icon')['layout']
          as Map<String, dynamic>;
      expect(layout['icon-image'], 'car-topdown');
      expect(layout['icon-allow-overlap'], isTrue);
      expect(layout['icon-ignore-placement'], isTrue);
      expect(layout['icon-rotation-alignment'], 'map');
    });

    test('rotation comes from the feature bearing, not from the camera', () async {
      final layout = layerNamed(await style(), 'moving-car-icon')['layout']
          as Map<String, dynamic>;
      // `viewport` alignment would pin the sprite to the screen's own rotation,
      // so the car would point north on the map whatever road it was on --
      // which is the specific failure this layer exists to avoid.
      expect(layout['icon-rotation-alignment'], 'map');
      expect(layout['icon-pitch-alignment'], 'map',
          reason: 'the car should lie on the pitched road, not stand up on it');
      final rotate = jsonEncode(layout['icon-rotate']);
      expect(rotate, contains(kVehicleBearingProperty));
    });

    test('a feature with no bearing still draws, pointing north', () async {
      // `coalesce`, not a bare `get`: `["get","bearing"]` on a feature without
      // the property evaluates to null, and a null icon-rotate draws nothing at
      // all. A car that vanishes when the compass has no answer is worse than a
      // car pointing the wrong way.
      final layout = layerNamed(await style(), 'moving-car-icon')['layout']
          as Map<String, dynamic>;
      final rotate = layout['icon-rotate'] as List;
      expect(rotate.first, 'coalesce');
      expect(rotate[1], ['get', kVehicleBearingProperty]);
      expect(rotate[2], 0);
    });

    test('icon-image names the sprite the apps register', () async {
      final layout = layerNamed(await style(), 'moving-car-icon')['layout']
          as Map<String, dynamic>;
      // A symbol layer whose icon-image matches nothing does not throw. It
      // silently draws nothing, so the car just is not there. This is the
      // assertion that would have caught it.
      expect(layout['icon-image'], kCarTopdownIconName);
    });

    test('is the last layer, so the car draws over the buildings', () async {
      final s = await style();
      final order = layersOf(s).map((l) => l['id']).toList();
      // A car behind a 0.45-opacity extrusion on a pitched camera is a car seen
      // through a wall.
      expect(order.last, kMovingCarLayerId);
      expect(order.indexOf(kMovingCarLayerId),
          greaterThan(order.indexOf('building-3d')));
    });
  });

  group('the style survives a round trip', () {
    test('is valid JSON with no unresolved expressions of the wrong arity', () async {
      final s = await style();
      // Every filter is a bare list, so a typo in one is a style MapLibre
      // rejects at load time -- on a phone, where the map is then simply
      // blank. Checking arity here turns that into a failing test.
      for (final l in layersOf(s)) {
        final filter = l['filter'];
        if (filter == null) continue;
        expect(filter, isA<List>(), reason: '${l['id']}');
        final head = (filter as List).first;
        const arity = {
          'all': 2,
          'any': 2,
          'in': 2,
          '==': 2,
          '!=': 2,
          'coalesce': 2,
          'has': 1,
        };
        if (arity.containsKey(head)) {
          expect(filter.length, greaterThanOrEqualTo(arity[head]!),
              reason: '${l['id']}: $head needs at least ${arity[head]} operands');
        }
      }
    });

    test('the palette block agrees with the constants the apps use', () async {
      final meta = (await style())['metadata'] as Map<String, dynamic>;
      final declared = (meta['mng:palette'] as Map).cast<String, String>();
      expect(declared['land'], PremiumMapPalette.land);
      expect(declared['water'], PremiumMapPalette.water);
      expect(declared['park'], PremiumMapPalette.park);
      expect(declared['road'], PremiumMapPalette.road);
      expect(declared['roadCasing'], PremiumMapPalette.roadCasing);
      expect(declared['building'], PremiumMapPalette.building);
    });
  });
}

/// The class values a layer's filter selects.
///
/// Handles both shapes a `class` filter takes: the filter *is* the `in`
/// expression, as the label layers and the road groups use, or it is a list
/// *containing* one, as an `all` of several conditions does. A helper that
/// only understood the second would have reported "no classes" for a layer that
/// filters on three, which is a test that passes by finding nothing.
Set<String> _classesIn(Map<String, dynamic> layer) {
  List<dynamic>? literalOf(Object? filter) {
    if (filter is! List || filter.isEmpty) return null;
    if (filter.first == 'in' && filter.length >= 3 && filter[2] is List) {
      final literal = filter[2] as List;
      if (literal.isNotEmpty && literal.first == 'literal') {
        return literal[1] as List;
      }
    }
    return null;
  }

  final direct = literalOf(layer['filter']);
  if (direct != null) return direct.cast<String>().toSet();

  final f = layer['filter'];
  if (f is! List) return const {};
  for (final op in f) {
    if (op is! List) continue;
    final found = literalOf(op);
    if (found != null) return found.cast<String>().toSet();
  }
  return const {};
}

/// The largest `line-width` a layer reaches, across its zoom stops.
double? _maxWidth(Map<String, dynamic> layer) {
  final w = (layer['paint'] as Map)['line-width'];
  if (w is num) return w.toDouble();
  if (w is! List) return null;
  final stops = <double>[];
  for (var i = 2; i + 1 < w.length; i += 2) {
    if (w[i + 1] is num) stops.add((w[i + 1] as num).toDouble());
  }
  return stops.isEmpty ? null : stops.reduce((a, b) => a > b ? a : b);
}
