// What POIs are actually in the tiles around Accra, and can they get an icon?
//
//   node toolchain/poi-probe.mjs
//
// The user asked for restaurant icons "and everything" on the map. The style has
// no sprite, so an `icon-image` can only be the car's. Before promising a
// restaurant icon I check two things: that the tiles really carry the POIs, and
// that an icon for them can be fetched. A POI layer with no sprite renders
// nothing at all, which looks identical to "there are no restaurants here".

import { readFileSync } from 'node:fs';

const style = JSON.parse(readFileSync('packages/mng_core/assets/maps/ride_premium.json', 'utf8'));
const tileJsonUrl = style.sources.openfreemap.url;
const tj = await (await fetch(tileJsonUrl)).json();
const poiLayer = tj.vector_layers.find((l) => l.id === 'poi');
if (!poiLayer) { console.log('NO poi layer in the tiles at all'); process.exit(1); }

console.log('=== the poi layer the tiles offer ===');
console.log('  description:', (poiLayer.description ?? '').slice(0, 90));
console.log('  zoom range: ', poiLayer.minzoom, '-', poiLayer.maxzoom);
console.log('  every class the schema defines:');
for (const v of poiLayer.values?.class ?? []) console.log('    ' + v);

// Accra, zoom 14 -- the zoom a driver is actually looking at.
const LAT = 5.6037, LNG = -0.1870;
const z = 14;
const n = 2 ** z;
const x = Math.floor(((LNG + 180) / 360) * n);
const y = Math.floor(((1 - Math.asinh(Math.tan(LAT * Math.PI / 180)) / Math.PI) / 2) * n);
const tileUrl = tj.tiles[0].replace('{z}', z).replace('{x}', x).replace('{y}', y);
console.log('\n=== one real Accra tile, z14 ===');
console.log('  ' + tileUrl);

const res = await fetch(tileUrl);
console.log('  HTTP', res.status, res.headers.get('content-type') ?? '');

// Decoding Mapbox Vector Tiles by hand is a lot of protobuf. Rather than pull
// in a dependency, ask the tile for its size and ask the *schema* what it can
// hold: if the layer is in the TileJSON with these fields, MapLibre will
// decode it, and that is the part the style depends on.
console.log('\n  bytes: ' + (await res.arrayBuffer()).byteLength);

console.log('\n=== can the style get icons for them? ===');
const spriteCandidates = [
  'https://tiles.openfreemap.org/styles/liberty/sprite',
  'https://tiles.openfreemap.org/styles/positron/sprite',
  'https://tiles.openfreemap.org/styles/bright/sprite',
];
for (const s of spriteCandidates) {
  try {
    const r = await fetch(`${s}.json`);
    if (!r.ok) { console.log('  ' + r.status + '  ' + s); continue; }
    const index = await r.json();
    const icons = Object.keys(index);
    // The classes we would want an icon for.
    const want = ['restaurant', 'cafe', 'bar', 'fast_food', 'fuel', 'hospital',
      'pharmacy', 'bank', 'atm', 'school', 'university', 'parking', 'bus',
      'airport', 'shop', 'supermarket', 'marketplace', 'hotel', 'police',
      'fire_station', 'post', 'library', 'toilets', 'waste_basket', 'bench'];
    const have = want.filter((w) => icons.includes(w) || icons.includes('poi_' + w));
    console.log('  200  ' + s + '  (' + icons.length + ' icons)');
    console.log('        wanted classes with an icon available: ' + have.join(', '));
    console.log('        missing: ' + want.filter((w) => !have.includes(w)).join(', '));
  } catch (e) {
    console.log('  ERR ' + s + '  ' + e.message);
  }
}
