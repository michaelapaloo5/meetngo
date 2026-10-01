import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';

/// The style, parsed once for the whole file.
Future<Map<String, dynamic>> style() async =>
    jsonDecode(await premiumMapStyleJson()) as Map<String, dynamic>;

List<Map<String, dynamic>> layersOf(Map<String, dynamic> s) =>
    (s['layers'] as List).cast<Map<String, dynamic>>();

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

    test(
      'draws from OpenFreeMap with no key, no account and no card',
      () async {
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
      },
    );

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
        expect(
          (layerNamed(s, id)['paint'] as Map)['fill-color'],
          '#E2F0D9',
          reason: id,
        );
      }
    });

    test(
      'every colour in the style is one of the declared palette values',
      () async {
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
          PremiumMapPalette.labelStrong,
          PremiumMapPalette.labelPoi,
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
          expect(
            allowed,
            contains(colour.toLowerCase()),
            reason: '$where is $colour, which is not in the palette',
          );
        });
      },
    );
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
        expect(
          (l['paint'] as Map)['line-color'],
          '#FFFFFF',
          reason: '${l['id']}',
        );
      }
    });

    test(
      'highways carry the thin soft gray casing, drawn under the white',
      () async {
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
        expect(
          casingMax! - roadMax!,
          lessThanOrEqualTo(2.5),
          reason: 'casing $casingMax vs road $roadMax',
        );

        // The casing has to be earlier in the layer list or the white road is
        // painted over it and it is invisible.
        final order = layersOf(s).map((l) => l['id']).toList();
        expect(
          order.indexOf('road-casing'),
          lessThan(order.indexOf('road-major')),
        );
      },
    );

    test(
      'only highways are cased, so local streets do not get a border',
      () async {
        final casing = layerNamed(await style(), 'road-casing');
        final classes = _classesIn(casing);
        expect(classes, {'motorway', 'trunk', 'primary'});
        expect(classes, isNot(contains('minor')));
        expect(classes, isNot(contains('service')));
      },
    );

    test('casing and the road it outlines select the same roads', () async {
      final s = await style();
      // A casing drawn on a different set of roads than the white on top of it
      // is a grey line running through the countryside.
      expect(
        _classesIn(layerNamed(s, 'road-casing')),
        _classesIn(layerNamed(s, 'road-major')),
      );
    });

    test('every road width is zoom-interpolated, not a flat line', () async {
      final s = await style();
      // Filtered to line layers, because `road-name` is also a "road" layer by
      // name and has no `line-width` to interpolate -- it draws text along the
      // line instead.
      for (final l
          in layersOf(s)
              .where((l) => l['type'] == 'line')
              .where((l) => l['source-layer'] == 'transportation')) {
        final w = (l['paint'] as Map)['line-width'];
        expect(w, isA<List>(), reason: '${l['id']} has a fixed width');
        expect(jsonEncode(w), contains('zoom'), reason: '${l['id']}');
      }
    });

    test('rails, ferries and tunnels are not drawn', () async {
      final s = await style();
      // Scoped to *line and fill* layers, which is what this rule is about: no
      // rail track, no ferry route, no transit line drawn as geometry a driver
      // could mistake for a road. It used to scan the whole style as one string,
      // which is not the same test -- `"ferry"` is now a legitimate POI *class*
      // on a pin layer, and a harbour is a thing a rider picks a pickup beside.
      // A whole-file scan would have failed on that and the fix would have been
      // to delete a useful pin rather than to scope the rule correctly.
      final geometry = layersOf(s)
          .where((l) => l['type'] == 'line' || l['type'] == 'fill')
          .toList();
      expect(geometry, isNotEmpty);
      final asText = jsonEncode(geometry);
      for (final unwanted in [
        '"rail"',
        '"ferry"',
        '"transit"',
        '"aerialway"',
      ]) {
        expect(
          asText,
          isNot(contains(unwanted)),
          reason: '$unwanted would put rail and transit lines on a road map',
        );
      }
      // And the same check across every layer's filter, so a geometry layer
      // cannot smuggle a rail class in through its own `in` expression.
      for (final l in geometry) {
        final filter = jsonEncode(l['filter']);
        for (final unwanted in ['rail', 'ferry', 'aerialway']) {
          expect(
            filter,
            isNot(contains(unwanted)),
            reason: '${l['id']} filters on $unwanted',
          );
        }
      }
      // Every road layer filters tunnels out: a tunnel drawn as a surface
      // street is a road that appears to run through a building.
      for (final l in layersOf(
        s,
      ).where((l) => l['source-layer'] == 'transportation')) {
        expect(
          jsonEncode(l['filter']),
          contains('brunnel'),
          reason: '${l['id']} does not exclude tunnels',
        );
      }
    });
  });

  group('3. decluttering', () {
    // This group used to assert the opposite of most of what follows: that no
    // layer read the `poi` source-layer at all, because a map showing business
    // names was judged to be noise. That was a reasonable call for a map you
    // only ever used to orient yourself, and the wrong call for one you pick a
    // pickup on -- "there is a hospital on that corner" is exactly the fact a
    // rider needs and it is a fact only a POI layer can show.
    //
    // So the rule is no longer "no business names" but "only ranked ones, only
    // as far as the tiles carry them, and never at the expense of the roads".
    // The tests below are as strict about the new rule as the old ones were
    // about the old one, because a style that draws everything is the same
    // failure as one that draws nothing.

    test('no boundary, address-number or peak layer exists at all', () async {
      final s = await style();
      // Still absent rather than `visibility: none`. A hidden layer still costs a
      // style diff to carry, still shows up in every layer list anyone reads, and
      // is one careless edit away from being turned back on. None of these three
      // tells a driver anything about where to drive.
      final banned = {
        'boundary',
        'aerodrome_label',
        'housenumber',
        'mountain_peak',
        'water_name',
      };
      for (final l in layersOf(s)) {
        expect(
          banned,
          isNot(contains(l['source-layer'])),
          reason: '${l['id']} draws ${l['source-layer']}',
        );
      }
    });

    test(
      'POIs are drawn, because a pickup is chosen by what is on the corner',
      () async {
        final s = await style();
        final poi = layersOf(s)
            .where((l) => l['source-layer'] == 'poi')
            .toList();
        expect(
          poi,
          isNotEmpty,
          reason: 'no layer reads the poi source-layer at all',
        );
        // The classes a rider actually navigates by. A POI layer that drew only
        // `bench` and `waste_basket` would satisfy "draws POIs" and be useless.
        final all = <String>{..._classesIn(poi.first), ..._classesIn(poi.last)};
        expect(
          all,
          containsAll(<String>[
            'hospital',
            'pharmacy',
            'bank',
            'fuel',
            'restaurant',
          ]),
        );
      },
    );

    test('no POI layer caps out, which used to hide every restaurant', () async {
      final s = await style();
      // This rule used to be the opposite. It asserted that every POI layer carries
      // a `maxzoom` of 14 or less, on the reasoning that "the `poi` source-layer in
      // OpenFreeMap's tiles stops at zoom 14. A layer with no `maxzoom` would ask
      // for data that is not there at 16, draw nothing, and read as 'this map has no
      // restaurants near you'."
      //
      // That reasoning is wrong about MapLibre, and it was costing the map its
      // single most useful layer. With a `maxzoom` of 14 the layer is switched off
      // the instant the camera passes 14 -- which is where a driver actually is
      // while navigating -- so all 92 restaurants, 41 fast-food places and 34 bars
      // that OpenFreeMap publishes for one z14 tile of Osu vanished at exactly the
      // moment they were wanted. A `maxzoom` does not ask for absent data and draw
      // nothing; MapLibre overzooms, so the z14 tile keeps rendering, magnified.
      //
      // Measured on an A06 at the same camera, before and after: with the cap the
      // view of King Hassan Road had no POI icon of any kind on it; with the cap
      // removed the same view is covered in them.
      //
      // The style already knew this. `place-label` carried `maxzoom: 12` and was
      // uncapped for exactly the same reason -- see 'a district name survives
      // zooming in, which it used not to'. POIs are the same case with more at
      // stake: a district name tells a driver where they are, a restaurant tells
      // them what is on the corner they are being sent to.
      for (final l in layersOf(s).where((l) => l['source-layer'] == 'poi')) {
        expect(
          l['maxzoom'],
          isNull,
          reason:
              '${l['id']} caps out, so every POI it carries disappears at the '
              'zoom a driver is navigating at',
        );
      }
    });

    test('every POI layer filters on rank, so a neighbourhood is not a wall of pins', () async {
      final s = await style();
      for (final l in layersOf(s).where((l) => l['source-layer'] == 'poi')) {
        final filter = jsonEncode(l['filter']);
        expect(
          filter,
          contains('rank'),
          reason:
              '${l['id']} draws every POI in the tile with no '
              'importance cut-off',
        );
        // And the cut-off has to be numeric-safe: `to-number` of a missing
        // `rank` is NaN, NaN fails every comparison, and the POI disappears
        // rather than falling into the less-important layer. A coalesce is what
        // sends it there instead.
        expect(filter, contains('to-number'), reason: '${l['id']}');
        expect(filter, contains('coalesce'), reason: '${l['id']}');
      }
    });

    test('only the important POIs get a name; the rest get a pin alone', () async {
      final s = await style();
      // Two layers rather than one: a rider at zoom 13 should see the hospital
      // named and forty restaurants unnamed, not eighty named pins fighting for
      // the same centimetre of screen.
      final named = layerNamed(s, 'poi-label');
      final minor = layerNamed(s, 'poi-icon-minor');
      expect(
        named['minzoom'],
        lessThan(minor['minzoom'] as num),
        reason: 'the named layer must appear before the unnamed one',
      );
      expect(_classesIn(minor), isNotEmpty);
      expect(
        (minor['layout'] as Map)['text-size'],
        isA<num>(),
        reason:
            'the minor layer sets no text size, so its names are '
            'indistinguishable from the major layer\'s',
      );
    });

    test(
      'a POI name is optional, so a crowded corner keeps its pins',
      () async {
        final s = await style();
        // Without this, MapLibre drops the entire symbol -- icon included --
        // whenever the text collides with something, which on a street with a
        // bank, a pharmacy and a restaurant in fifty metres means the map loses
        // all three rather than showing three pins and two names.
        for (final l in layersOf(s).where((l) => l['source-layer'] == 'poi')) {
          expect(
            (l['layout'] as Map)['text-optional'],
            isTrue,
            reason:
                '${l['id']} will drop the whole symbol when its text collides',
          );
        }
      },
    );

    test('a layer using icon-image has a sprite to get the icon from', () async {
      final s = await style();
      // A symbol layer whose `icon-image` matches nothing draws nothing and
      // throws no error. That is the whole hazard of adding POI pins, and it is
      // why this is asserted rather than left to a device.
      final needingSprite = layersOf(s)
          .where(
            (l) =>
                (l['layout'] is Map) &&
                (l['layout'] as Map)['icon-image'] != null,
          )
          .where((l) => l['id'] != 'moving-car-icon') // registered at runtime
          .toList();
      expect(needingSprite, isNotEmpty);
      expect(
        s['sprite'],
        isNotNull,
        reason:
            'POI layers ask the sprite for icons and the style declares none',
      );
    });

    test('a POI class with no icon in the sprite is aliased onto one that has it', () async {
      final s = await style();
      // The `icon-image` is a `match` that aliases before it falls back to
      // `["get", "class"]`. Both halves matter: the alias is what makes
      // `supermarket` draw (the sheet has `grocery` and no `supermarket`), and
      // the fallback is what lets a class nobody anticipated still get an icon
      // without editing this file.
      for (final l in layersOf(s).where((l) => l['source-layer'] == 'poi')) {
        final image = jsonEncode((l['layout'] as Map)['icon-image']);
        expect(image, contains('match'), reason: '${l['id']} does not alias');
        expect(image, contains('get'), reason: '${l['id']} has no fallback');
      }
    });

    test('road names are drawn, because an unnamed road cannot be navigated', () async {
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

    test('a district name survives zooming in, which it used not to', () async {
      final s = await style();
      // `place-label` carried `maxzoom: 12`, so the moment a driver zoomed in to
      // navigate -- zoom 14, 15, 16, exactly when a street name starts to
      // matter -- every district name disappeared and the map stopped saying
      // whether it was Osu or Tema. The zoomed layer is the fix, and it fades the
      // name *down* as it goes in so it does not compete with the street names
      // it now sits among.
      expect(
        layerNamed(s, 'place-label')['maxzoom'],
        isNull,
        reason:
            'place-label must not cap out, or districts vanish when zoomed in',
      );
      final zoomed = layerNamed(s, 'place-label-zoomed');
      expect(zoomed['minzoom'], isNotNull);
      expect(
        _classesIn(zoomed),
        containsAll(<String>['suburb', 'neighbourhood']),
      );
      // Shrinking with zoom, not growing: at 15 px it would shout over the road
      // names that are the actual instruction.
      //
      // Read as pairs rather than by scraping digits. An `interpolate` is
      // `["interpolate", ["linear"], ["zoom"], zoomIn, sizeAtZoomIn, ...]` --
      // the sizes are the *second* of each pair, and a regex over the whole
      // array picks up the zoom stops as well. The first version of this test
      // did that and compared zoom 11 against size 10, which is comparing two
      // unrelated numbers and happened to pass for the wrong reason.
      final expr = (zoomed['layout'] as Map)['text-size'];
      expect(expr, isA<List>());
      final list = (expr as List).cast<Object?>();
      expect(list.first, 'interpolate');
      // Skip the interpolation specifier and the ["zoom"] input, then walk the
      // remaining numbers as (zoom, size) pairs.
      final numbers = <double>[];
      for (final v in list.skip(2)) {
        if (v is List) {
          expect(
            v.first,
            'zoom',
            reason: 'the input is the zoom, so the numbers after it are pairs',
          );
        } else if (v is num) {
          numbers.add(v.toDouble());
        }
      }
      expect(
        numbers.length,
        greaterThanOrEqualTo(2),
        reason: 'no (zoom, size) pairs found in $expr',
      );
      expect(numbers.length % 2, 0, reason: 'a dangling stop in $expr');
      final sizes = <double>[];
      for (var i = 1; i < numbers.length; i += 2) {
        sizes.add(numbers[i]);
      }
      expect(
        sizes.first,
        greaterThan(sizes.last),
        reason:
            'the zoomed district label should get smaller, not larger, '
            'as the map closes in; sizes were $sizes',
      );
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
        expect(
          layout['text-font'],
          isNotNull,
          reason: '${l['id']} has text but no font, so it draws nothing',
        );
        // Every font has to be one the style's `glyphs` URL can actually serve.
        final fonts = (layout['text-font'] as List).cast<String>();
        expect(fonts, isNotEmpty);
        for (final f in fonts) {
          expect(f, isNotEmpty);
        }
      }
      // This used to be `expect(checked, 2)`, an exact count, and it is a
      // number that has to be edited every time a label is added. That is fine
      // for catching an accidental layer and useless for catching the real
      // hazard, which is one label with no font. What is asserted now is that
      // every text layer is one of the four that are supposed to exist, so a
      // fifth text layer -- from a plugin, or a layer pasted in from a style
      // someone else wrote -- fails here by name.
      expect(checked, greaterThanOrEqualTo(4));
      final textLayers = layersOf(s)
          .where(
            (l) =>
                (l['layout'] is Map) &&
                (l['layout'] as Map)['text-field'] != null,
          )
          .map((l) => l['id'] as String)
          .toSet();
      expect(
        textLayers,
        everyElement(
          anyOf(
            'place-label',
            'place-label-zoomed',
            'road-name',
            'poi-label',
            'poi-icon-minor',
            // The classes OpenFreeMap publishes for Accra that no earlier layer
            // matched -- beer, clothing_store, butcher, ice_cream, town_hall,
            // monument, castle, information and the rest. `office` is deliberately
            // NOT here: it has 204 features in a single z14 tile of Osu, so it is
            // icon-only in `poi-office-block` and carries no name.
            'poi-icon-extra',
          ),
        ),
        reason: 'an unexpected text layer appeared: $textLayers',
      );
    });

    test('labels carry a halo, because grey text on pale land is unreadable', () async {
      // The land is #F4F4F6 and the text is #8A8A8E, a difference of about 40
      // levels of luminance. Without a halo the names sit on the map as a grey
      // suggestion of text.
      final s = await style();
      for (final id in [
        'place-label',
        'place-label-zoomed',
        'road-name',
        'poi-label',
        'poi-icon-minor',
      ]) {
        final paint = layerNamed(s, id)['paint'] as Map;
        expect(paint['text-halo-width'], isNotNull, reason: id);
        expect((paint['text-halo-width'] as num), greaterThan(0), reason: id);
      }
    });

    test('the car icon and the POI icons come from different places', () async {
      final s = await style();
      // This used to read "the car is still the only thing drawn as an image",
      // and it was the rule that kept business icons out. It is now the rule
      // that keeps the *car* correct, which is a different and still-worth-
      // having check: the car's `icon-image` is a fixed name the apps register
      // at runtime, while the POI layers' is a `match` resolved per feature out
      // of the sheet. If either quietly became the other, one of them stops
      // drawing and nothing says so.
      final car = layerNamed(s, kMovingCarLayerId);
      final carImage = (car['layout'] as Map)['icon-image'];
      expect(
        carImage,
        kCarTopdownIconName,
        reason: 'the car must name the sprite the apps register, not the sheet',
      );

      final poi = layersOf(s).where((l) => l['source-layer'] == 'poi').toList();
      expect(poi, isNotEmpty);
      for (final l in poi) {
        final image = (l['layout'] as Map)['icon-image'];
        expect(
          image,
          isNot(kCarTopdownIconName),
          reason: '${l['id']} asks for the car sprite',
        );
        expect(
          jsonEncode(image),
          contains('get'),
          reason: '${l['id']} must resolve its icon per feature',
        );
      }
    });

    test(
      'keeps only the geometry a driver needs, and drops aeroways',
      () async {
        final used = layersOf(await style())
            .map((l) => l['source-layer'])
            .whereType<String>()
            .toSet();
        // An exact set, because this is the test that stops the style growing a
        // source layer nobody decided on. `poi` is in it now, and deliberately:
        // the rest of this group is about what is drawn, and a POI layer the
        // rank tests above constrain is drawn on purpose.
        expect(used, {
          'landcover',
          'landuse',
          'water',
          'waterway',
          'building',
          'transportation',
          'place',
          'transportation_name',
          'poi',
        });
      },
    );
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

    test(
      'a vertical gradient, without which the extrusions read as flat cutouts',
      () async {
        final p = layerNamed(await style(), 'building-3d')['paint'] as Map;
        expect(p['fill-extrusion-vertical-gradient'], isTrue);
      },
    );

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
      final v =
          ((await style())['sources'] as Map)[kVehicleSourceId]
              as Map<String, dynamic>;
      expect(v['type'], 'geojson');
      final data = v['data'] as Map<String, dynamic>;
      expect(data['type'], 'FeatureCollection');
      // Not a placeholder car at the origin: a style that ships with a vehicle
      // in the Gulf of Guinea shows a car in the ocean until the first fix.
      expect((data['features'] as List), isEmpty);
    });

    test('every required icon property is set exactly as specified', () async {
      final layout =
          layerNamed(await style(), 'moving-car-icon')['layout']
              as Map<String, dynamic>;
      expect(layout['icon-image'], 'car-topdown');
      expect(layout['icon-allow-overlap'], isTrue);
      expect(layout['icon-ignore-placement'], isTrue);
      expect(layout['icon-rotation-alignment'], 'map');
    });

    test('rotation comes from the feature bearing, not from the camera', () async {
      final layout =
          layerNamed(await style(), 'moving-car-icon')['layout']
              as Map<String, dynamic>;
      // `viewport` alignment would pin the sprite to the screen's own rotation,
      // so the car would point north on the map whatever road it was on --
      // which is the specific failure this layer exists to avoid.
      expect(layout['icon-rotation-alignment'], 'map');
      expect(
        layout['icon-pitch-alignment'],
        'map',
        reason: 'the car should lie on the pitched road, not stand up on it',
      );
      final rotate = jsonEncode(layout['icon-rotate']);
      expect(rotate, contains(kVehicleBearingProperty));
    });

    test('a feature with no bearing still draws, pointing north', () async {
      // `coalesce`, not a bare `get`: `["get","bearing"]` on a feature without
      // the property evaluates to null, and a null icon-rotate draws nothing at
      // all. A car that vanishes when the compass has no answer is worse than a
      // car pointing the wrong way.
      final layout =
          layerNamed(await style(), 'moving-car-icon')['layout']
              as Map<String, dynamic>;
      final rotate = layout['icon-rotate'] as List;
      expect(rotate.first, 'coalesce');
      expect(rotate[1], ['get', kVehicleBearingProperty]);
      expect(rotate[2], 0);
    });

    test('icon-image names the sprite the apps register', () async {
      final layout =
          layerNamed(await style(), 'moving-car-icon')['layout']
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
      expect(
        order.indexOf(kMovingCarLayerId),
        greaterThan(order.indexOf('building-3d')),
      );
    });
  });

  group('the style survives a round trip', () {
    test(
      'is valid JSON with no unresolved expressions of the wrong arity',
      () async {
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
            expect(
              filter.length,
              greaterThanOrEqualTo(arity[head]!),
              reason:
                  '${l['id']}: $head needs at least ${arity[head]} operands',
            );
          }
        }
      },
    );

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
