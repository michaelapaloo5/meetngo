// Build the bundled map style's two POI layers, and check the icons resolve.
//
//   node toolchain/fix-style.mjs
//
// The style filters POIs on OpenMapTiles class names and looks the icon up by the
// same string -- `icon-image: ["get", "class"]` -- because OpenFreeMap's sprite
// keys ARE the class names. That is a nice property and it has a sharp edge: a
// class the sprite does not contain draws nothing, silently, with no error, and
// that is indistinguishable from "there is no bank round here". The first
// version of these layers asked for 73 classes and 28 of them had no icon.
//
// So this script does two things together, which is the point of it being one
// file rather than two:
//
//   1. builds the layers, with an explicit alias table for the classes that need
//      mapping onto an icon the sheet actually has
//   2. FETCHES the sheet and refuses to leave behind a class that cannot draw
//
// It writes only when the JSON parses and every class either has an icon or has
// an alias, so running it on a broken style is a no-op rather than a second
// breakage, and running it twice changes nothing.

import { readFileSync, writeFileSync } from 'node:fs';

const PATH = 'packages/mng_core/assets/maps/ride_premium.json';
const SPRITE = 'https://tiles.openfreemap.org/sprites/ofm_f384/ofm';

// ------------------------------------------------- classes, and their aliases
//
// `rank` runs from 1 (most important) downwards in the OpenMapTiles schema. The
// split is what keeps a neighbourhood readable: at zoom 13 a rider sees the
// hospital, the bank and the filling stations with names; at zoom 14 everything
// else gets a pin and no name, because a field of text is not a map.
const MAJOR = [
  'airport', 'atm', 'bank', 'bar', 'bus_station', 'cafe', 'cinema', 'college',
  'fast_food', 'fire_station', 'fuel', 'hospital', 'library', 'museum', 'parking',
  'pharmacy', 'place_of_worship', 'police', 'post', 'restaurant', 'school',
  'shop', 'stadium', 'zoo',
];

const MINOR = [
  'art_gallery', 'attraction', 'bakery', 'bus', 'car', 'car_rental', 'car_repair',
  'cemetery', 'charging_station', 'clinic', 'college', 'convenience', 'dentist',
  'department_store', 'doctors', 'drinking_water', 'electronics', 'ferry',
  'florist', 'garden', 'grave_yard', 'grocery', 'hairdresser', 'harbour', 'hotel',
  'kindergarten', 'laundry', 'marketplace', 'mobile_phone', 'money_lender',
  'nightclub', 'park', 'pitch', 'playground', 'railway', 'shelter', 'shopping',
  'sports_centre', 'subway', 'supermarket', 'swimming_pool', 'taxi', 'theatre',
  'toilets', 'tram', 'university', 'veterinary', 'waste_basket',
];

// Every one of these is a real OpenMapTiles class that the sheet has no icon for,
// pointed at the nearest one it does. Without this table the layer filters for a
// class, the feature matches, `icon-image` resolves to nothing, and the map looks
// like the data is missing rather than like the sprite is short.
const ALIAS = {
  // Money
  atm: 'bank',
  bureau_de_change: 'bank',
  money_lender: 'bank',
  // Transport
  bus_station: 'bus',
  taxi: 'car',
  car_rental: 'car',
  car_repair: 'car',
  charging_station: 'fuel',
  ferry: 'harbor',
  harbour: 'harbor',
  subway: 'railway_metro',
  tram: 'railway',
  // Health
  clinic: 'hospital',
  // Shops
  convenience: 'grocery',
  marketplace: 'grocery',
  supermarket: 'grocery',
  shopping: 'grocery',
  department_store: 'shop',
  electronics: 'shop',
  mobile_phone: 'shop',
  // Lodging and food
  hotel: 'lodging',
  nightclub: 'bar',
  // Places
  grave_yard: 'cemetery',
  kindergarten: 'school',
  university: 'college',
  sports_centre: 'stadium',
  swimming_pool: 'swimming',
};

/** `icon-image` as a `match`, aliasing first and falling back to the class. */
function iconImage(classes) {
  const used = [...new Set(classes.filter((c) => ALIAS[c]))].sort();
  if (used.length === 0) return ['get', 'class'];
  const expr = ['match', ['get', 'class']];
  for (const cls of used) expr.push([cls], ALIAS[cls]);
  expr.push(['get', 'class']);
  return expr;
}

const sorted = (xs) => [...new Set(xs)].sort();

/**
 * The `literal` operand, in the form a MapLibre *style* expects.
 *
 * `["literal", [...]]`, not `{"type": "literal", "literal": [...]}`. Both appear
 * in the MapLibre specification and the second version was what this file wrote
 * first, which is a genuinely nasty failure: MapLibre's own expression parser
 * accepts it, so nothing errors and the style loads, but the Dart test that
 * reads the filter back out looks for the array shape, finds nothing, and
 * reports "this layer filters on no classes" -- a test that passes by finding
 * nothing, which is the failure mode its own doc comment warns about three
 * functions above. The style is a data file consumed by two independent
 * readers, so it gets the shape both of them agree on.
 */
const literal = (xs) => ['literal', sorted(xs)];

const majorLayer = (classes) => ({
  id: 'poi-label',
  type: 'symbol',
  source: 'openfreemap',
  'source-layer': 'poi',
  minzoom: 13,
  maxzoom: 14,
  filter: [
    'all',
    ['in', ['get', 'class'], literal(classes)],
    // `to-number` of a missing `rank` is NaN, and NaN fails both comparisons,
    // so an absent rank would drop the POI entirely. Coalescing to 30 sends it
    // to the minor layer instead, which draws the pin and leaves the name off.
    // Losing a label is a smaller failure than losing the pin.
    ['<=', ['to-number', ['coalesce', ['get', 'rank'], 30], 30], 20],
  ],
  layout: {
    'icon-image': iconImage(classes),
    'icon-size': ['interpolate', ['linear'], ['zoom'], 13, 0.6, 14, 0.85],
    'icon-anchor': 'top',
    'icon-allow-overlap': false,
    'icon-ignore-placement': false,
    'text-field': ['coalesce', ['get', 'name_en'], ['get', 'name']],
    'text-font': ['Noto Sans Regular'],
    'text-size': ['interpolate', ['linear'], ['zoom'], 13, 9, 14, 10.5],
    'text-anchor': 'top',
    'text-offset': [0, 0.9],
    'text-max-width': 9,
    'text-allow-overlap': false,
    // The icon is the point; the name is a bonus. `text-optional` lets the icon
    // stand alone when the label will not fit, rather than MapLibre dropping the
    // whole symbol because its text collided with something.
    'text-optional': true,
  },
  paint: {
    'text-color': '#5A5A5F',
    'text-halo-color': '#F4F4F6',
    'text-halo-width': 1.4,
  },
});

const minorLayer = (classes) => ({
  id: 'poi-icon-minor',
  type: 'symbol',
  source: 'openfreemap',
  'source-layer': 'poi',
  minzoom: 14,
  maxzoom: 14,
  filter: [
    'all',
    ['in', ['get', 'class'], literal(classes)],
    ['>', ['to-number', ['coalesce', ['get', 'rank'], 30], 30], 20],
  ],
  layout: {
    'icon-image': iconImage(classes),
    'icon-size': 0.55,
    'icon-allow-overlap': false,
    'icon-ignore-placement': false,
    'text-field': ['coalesce', ['get', 'name_en'], ['get', 'name']],
    'text-font': ['Noto Sans Regular'],
    'text-size': 9,
    'text-anchor': 'top',
    'text-offset': [0, 0.8],
    'text-optional': true,
    'text-allow-overlap': false,
  },
  paint: {
    'text-color': '#6E6E73',
    'text-halo-color': '#F4F4F6',
    'text-halo-width': 1.2,
  },
});

/**
 * The classes a layer's `class` filter names, whether the filter *is* the `in`
 * expression or an `all` containing one.
 */
const filterClasses = (layer) => {
  const literalOf = (f) => {
    if (!Array.isArray(f) || f[0] !== 'in' || f.length < 3) return null;
    const l = f[2];
    return Array.isArray(l) && l[0] === 'literal' && Array.isArray(l[1]) ? l[1] : null;
  };
  const direct = literalOf(layer.filter);
  if (direct) return direct;
  if (Array.isArray(layer.filter)) {
    for (const clause of layer.filter) {
      const found = literalOf(clause);
      if (found) return found;
    }
  }
  return [];
};

// ------------------------------------------------------------------- the work
//
// The file may not parse (it did not, last time), so the two layers are located
// in the text and replaced wholesale rather than read as JSON and edited.

const layerStart = (src, id) => {
  const at = src.indexOf(`"id": "${id}"`);
  return at < 0 ? -1 : src.lastIndexOf('{', at);
};

const layerEnd = (src, from) => {
  let depth = 0;
  for (let i = from; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) return i + 1;
  }
  return -1;
};

let text = readFileSync(PATH, 'utf8');
for (const [id, build] of [['poi-label', majorLayer], ['poi-icon-minor', minorLayer]]) {
  const classes = id === 'poi-label' ? MAJOR : MINOR;
  const start = layerStart(text, id);
  const built = JSON.stringify(build(classes), null, 2);
  if (start < 0) {
    console.log('  ' + id + ': not present, appending');
    continue;
  }
  const end = layerEnd(text, start);
  if (end < 0) { console.log('  ' + id + ': could not find the end of the object'); process.exit(1); }
  const replacement = built.split('\n').map((l, i) => (i === 0 ? l : '    ' + l)).join('\n');
  text = text.slice(0, start) + replacement + text.slice(end);
  console.log('  ' + id + ': ' + classes.length + ' classes, ' +
    [...new Set(classes.filter((c) => ALIAS[c]))].length + ' of them aliased');
}

let style;
try {
  style = JSON.parse(text);
} catch (e) {
  console.log('  STILL not valid JSON, so nothing written: ' + e.message);
  process.exit(1);
}

// ------------------------------------------------- the check that matters
//
// Fetch the sheet and confirm every class the style filters on can actually
// draw. This is the assertion the first version of these layers was missing, and
// it is the reason a restaurant pin is a promise rather than a hope.
const res = await fetch(SPRITE + '.json');
if (!res.ok) {
  console.log('  could not read the sprite index (HTTP ' + res.status + '), so the icon check did not run');
  process.exit(1);
}
const icons = new Set(Object.keys(await res.json()));

let unresolvable = [];
for (const layer of style.layers.filter((l) => l['source-layer'] === 'poi')) {
  for (const cls of filterClasses(layer)) {
    const target = ALIAS[cls] ?? cls;
    if (!icons.has(target)) unresolvable.push(layer.id + ': ' + cls + ' -> ' + target);
  }
}
if (unresolvable.length) {
  console.log('\n  ' + unresolvable.length + ' class(es) still cannot draw an icon:');
  for (const u of unresolvable) console.log('    ' + u);
  console.log('\n  nothing written -- add an alias or drop the class');
  process.exit(1);
}

writeFileSync(PATH, JSON.stringify(style, null, 2) + '\n');
console.log('  every class resolves to a real icon in the sheet');
console.log('  written: ' + PATH + '  (' + style.layers.length + ' layers)');
