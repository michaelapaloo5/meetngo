// What icons does OpenFreeMap's sprite actually have?
//
//   node toolchain/sprite-keys.mjs
//
// The style's POI layers filter on OpenMapTiles class names and look the icon up
// by the same string, so a class the sprite does not contain draws nothing --
// silently, with no error, which looks identical to "there is no bank round
// here". Six of the major classes and twenty-five of the minor ones were in that
// state, so this prints the sheet's real contents and what each missing class
// could be mapped onto instead.

import { readFileSync } from 'node:fs';

const SPRITE = 'https://tiles.openfreemap.org/sprites/ofm_f384/ofm';
const res = await fetch(SPRITE + '.json');
if (!res.ok) { console.log('sprite index HTTP ' + res.status); process.exit(1); }
const index = await res.json();
const keys = Object.keys(index).sort();

console.log('  sprite: ' + SPRITE);
console.log('  icons:  ' + keys.length + '\n');
console.log('  every key:\n');
for (let i = 0; i < keys.length; i += 5) {
  console.log('    ' + keys.slice(i, i + 5).map((k) => k.padEnd(20)).join(''));
}

const style = JSON.parse(readFileSync('packages/mng_core/assets/maps/ride_premium.json', 'utf8'));
const have = new Set(keys);
const wanted = new Set();
for (const layer of style.layers.filter((l) => l['source-layer'] === 'poi')) {
  const lit = layer.filter.find((f) => Array.isArray(f) && f[0] === 'in')?.find((c) => c?.type === 'literal');
  for (const c of lit?.literal ?? []) wanted.add(c);
}
const missing = [...wanted].filter((c) => !have.has(c)).sort();
console.log('\n  the style asks for ' + wanted.size + ' classes; ' + missing.length + ' have no icon:\n');
for (const c of missing) {
  const head = c.split('_')[0];
  const guess = keys.filter((k) => k === head || k.startsWith(head) || k.includes(head)).slice(0, 4);
  console.log('    ' + c.padEnd(20) + (guess.length ? 'nearest: ' + guess.join(', ') : 'nothing similar in the sheet'));
}
