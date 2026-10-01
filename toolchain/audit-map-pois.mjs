// Which POI classes does the style filter in, and can each one actually draw?
//
//   node toolchain/audit-map-pois.mjs
//
// Answers the question the tile counts raised. OpenFreeMap publishes a lot of POIs
// in Accra -- 92 restaurants, 204 offices, 140 bus stops in one z14 tile of Osu --
// but publishing them is not the same as showing them. A class is only visible if
// all three of these hold:
//
//   1. some layer's `filter` includes it
//   2. that layer has no `maxzoom` that switches it off at the zoom being viewed
//   3. the `icon-image` it resolves to exists in the sprite the style points at
//
// Each of those was a real miss. The `maxzoom: 14` on both POI layers hid every
// restaurant the moment a driver zoomed past 14 -- which is what "the restaurants are
// not on the map" actually looked like. And `office` and `bus`, the first and third
// largest classes in the tile, matched no filter at all.
//
// The last arm of each `icon-image` match is `["get","class"]`, so a class with no
// explicit mapping needs an icon named exactly after it. Those are checked by name.

const STYLE = 'packages/mng_core/assets/maps/ride_premium.json';
const SPRITE = 'https://tiles.openfreemap.org/sprites/ofm_f384/ofm.json';

const style = JSON.parse(await (await import('node:fs/promises')).readFile(STYLE, 'utf8'));
const sprite = await (await fetch(SPRITE)).json();
const have = new Set(Object.keys(sprite));

/** The class list out of `["in", ["get","class"], ["literal", [...]]]`. */
function classesIn(filter) {
  if (!Array.isArray(filter)) return [];
  const flat = [];
  const walk = (n) => {
    if (!Array.isArray(n)) return;
    if (n[0] === 'literal') { flat.push(...n[1]); return; }
    if (n[0] === 'all') { for (const x of n.slice(1)) walk(x); return; }
    // legacy object form: {"value": [...]}
    if (n.value) { walk(n.value); return; }
    for (const x of n) walk(x);
  };
  walk(filter);
  return flat;
}

/** Explicit class -> icon arms of a `match` expression. */
function mappingsIn(expr) {
  const map = new Map();
  if (typeof expr === 'string') return map; // a flat icon for every class
  if (!Array.isArray(expr) || expr[0] !== 'match') return map;
  for (let i = 2; i < expr.length - 1; i += 2) {
    const label = expr[i];
    const icon = expr[i + 1];
    if (Array.isArray(label) && typeof icon === 'string') {
      for (const c of label) map.set(c, icon);
    }
  }
  return map;
}

const symbolLayers = style.layers.filter(
  (l) => l.type === 'symbol' && l['source-layer'] === 'poi',
);

console.log('=== POI layers ===');
for (const l of symbolLayers) {
  console.log(
    `  ${l.id.padEnd(18)} z${l.minzoom ?? '-'}..${l.maxzoom ?? '∞'}` +
      (l.maxzoom === 14 ? '   <-- CAPPED: invisible the moment you zoom past 14' : ''),
  );
}

const drawn = new Map(); // class -> [layerIds]
const invisible = [];
const notFiltered = [];

for (const l of symbolLayers) {
  const classes = classesIn(l.filter);
  const map = mappingsIn(l.layout?.['icon-image']);
  const flat = typeof l.layout?.['icon-image'] === 'string' ? l.layout['icon-image'] : null;
  for (const c of classes) {
    // The catch-all arm of a `match` is the class name itself; a flat icon-image
    // applies to every class in the filter.
    const icon = map.get(c) ?? flat ?? c;
    const ok = have.has(icon);
    if (!drawn.has(c)) drawn.set(c, []);
    drawn.get(c).push(l.id + (ok ? '' : ' (icon missing!)'));
    if (!ok) invisible.push(`${c} -> needs icon "${icon}" (not in the sprite)`);
  }
}

console.log(`\n=== ${drawn.size} classes are filtered in ===`);
console.log('  a class can only draw if one of these resolves to an icon that exists');

if (invisible.length) {
  console.log('\n  FILTERED IN BUT CANNOT DRAW:');
  for (const i of invisible) console.log('    ' + i);
} else {
  console.log('\n  every filtered class resolves to an icon that exists');
}

// The other direction: what is in the tile that nothing draws.
console.log('\n=== to compare against the tile ===');
console.log('  node toolchain/count-pois.mjs 5.5639 -0.1950 14');
console.log('  lists the classes OpenFreeMap really publishes for a tile of Osu.');
console.log('  Anything in that list and not in the set above is simply not drawn.');

console.log('\n  classes this style draws:');
console.log('    ' + [...drawn.keys()].sort().join(', '));

// Layers whose icon is NOT expected to come from the remote sprite.
//
// `moving-car-icon` asks for `car-topdown`, which the OpenFreeMap sprite does not
// contain -- and that is correct, not a bug. `DriverMapPanel._pushVehicle` calls
// `controller.addImage(kCarTopdownIconName, carTopdownPng())`, so the app registers
// the icon itself at runtime from a bundled PNG. The first version of this audit
// flagged the layer as dead, which would have been a false alarm sent to whoever
// reads it next.
const RUNTIME_IMAGES = new Set(['car-topdown']);

for (const l of style.layers) {
  if (l.type !== 'symbol') continue;
  const expr = l.layout?.['icon-image'];
  if (typeof expr !== 'string') continue;
  if (RUNTIME_IMAGES.has(expr)) {
    console.log(`\n  ok: "${l.id}" uses "${expr}", which the app registers with addImage.`);
    continue;
  }
  if (!have.has(expr)) {
    console.log(`\n  DEAD LAYER: "${l.id}" asks for icon "${expr}", which the sprite does not have.`);
    console.log('    It can never draw. Either the sprite needs a different name or the');
    console.log('    layer is vestigial.');
  }
}