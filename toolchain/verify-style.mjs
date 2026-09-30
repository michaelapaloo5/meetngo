// Confirm the style's expression operands are in the shape MapLibre's style
// format expects, and that both readers of the file agree.
//
//   node toolchain/verify-style.mjs
//
// The first version of the POI layers wrote `{"type": "literal", "literal":
// [...]}`. MapLibre's own parser accepts that, so the style loaded and nothing
// errored -- but the Dart test reads the filter back out looking for
// `["literal", [...]]`, finds nothing, and reports that the layer filters on no
// classes. A test that passes by finding nothing is worse than no test, so this
// checks the shape directly.

import { readFileSync } from 'node:fs';

const style = JSON.parse(readFileSync('packages/mng_core/assets/maps/ride_premium.json', 'utf8'));
let ok = true;
const fail = (m) => { ok = false; console.log('  FAIL  ' + m); };
const pass = (m) => console.log('  ok    ' + m);

/** Walk every array in the style and collect what looks like an operand. */
function operands(node, out = []) {
  if (Array.isArray(node)) {
    if (node.length && typeof node[0] === 'string' && node.length === 2
      && node[0] === 'literal' && Array.isArray(node[1])) {
      out.push(node);
    }
    for (const v of node) operands(v, out);
  } else if (node && typeof node === 'object') {
    for (const v of Object.values(node)) operands(v, out);
  }
  return out;
}

console.log('=== literal operands ===');
const lits = operands(style);
console.log('  found ' + lits.length + ' literal operands, all in the ["literal", [...]] form');
if (lits.length === 0) fail('no literal operands at all');

const asObjects = JSON.stringify(style).includes('"type":"literal"');
asObjects
  ? fail('the style still contains a {"type":"literal"} object form somewhere')
  : pass('no {"type":"literal"} object form anywhere in the file');

console.log('\n=== every class filter reads back the way the Dart test reads it ===');
for (const layer of style.layers) {
  const f = layer.filter;
  const direct = (Array.isArray(f) && f[0] === 'in' && Array.isArray(f[2])
    && f[2][0] === 'literal') ? f[2][1] : null;
  let found = direct;
  if (!found && Array.isArray(f)) {
    for (const c of f) {
      if (Array.isArray(c) && c[0] === 'in' && Array.isArray(c[2]) && c[2][0] === 'literal') {
        found = c[2][1];
        break;
      }
    }
  }
  if (found) console.log('  ' + layer.id.padEnd(20) + found.length + ' classes');
}

console.log('\n=== the two POI layers specifically ===');
for (const id of ['poi-label', 'poi-icon-minor']) {
  const l = style.layers.find((x) => x.id === id);
  if (!l) { fail(id + ' is missing'); continue; }
  const f = l.filter.find((c) => Array.isArray(c) && c[0] === 'in');
  const classes = f?.[2]?.[1];
  Array.isArray(classes) && classes.length
    ? pass(id + ' reads back ' + classes.length + ' classes')
    : fail(id + ' reads back nothing -- the Dart test would pass vacuously');
}

console.log('\n' + (ok ? 'EVERY CHECK PASSED' : 'SOMETHING FAILED'));
process.exit(ok ? 0 : 1);
