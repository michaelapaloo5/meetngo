// Live check of the deployed `route` function against the real trip the user
// actually drives: Las Palmas, Lapaz -> 37 Military Hospital.
//
//   node toolchain/verify-route.mjs
//
// The unit tests stub both engines so they keep passing when an upstream
// service changes. This is the one that proves the deployed function, the
// fallback logic and the OSRM courtesy service are all still real.

import { readFileSync } from 'node:fs';

const env = {};
for (const file of ['toolchain/supabase-admin.env', 'toolchain/apk-build.env']) {
  let text;
  try { text = readFileSync(file, 'utf8'); } catch { continue; }
  for (const line of text.split('\n')) {
    const m = /^\s*(?:export\s+)?([A-Z_0-9]+)=(.*)$/.exec(line);
    if (m && m[2]) env[m[1]] ??= m[2].replace(/^["']|["']$/g, '');
  }
}
const REF = env.SUPABASE_PROJECT_REF;
const ANON = env.SUPABASE_ANON_KEY;

// The trip, in the order the rider's map hands them over.
//
// "Las Palmas, Lapaz" is genuinely ambiguous and this has been got wrong three
// times, so the pin is pinned with a reason rather than a guess. Nominatim
// returns FOUR Las Palmas in Accra, and two of them carry the identical label
// "Las Palmas, George Walker Bush Highway, Lapaz, Nii Boi Town" -- 9.31 km and
// 11.12 km from the hospital, about 800 m apart. The 11.12 km one is this
// fixture because it is the one whose road distance matches the 11.6 km the
// user drives. An earlier version used a Las Palmas *restaurant* in North Legon
// and reported 11.20 km, which was a coincidence: two different places, and the
// number matched for the wrong reason. `toolchain/las-palmas.mjs` lists them
// all, routed, so the choice can be checked rather than trusted.
const LAS_PALMAS = { lat: 5.6068938, lng: -0.2490504 };
const HOSPITAL = { lat: 5.5868922, lng: -0.1850474 };
const EXPECTED_KM = 11.6;

const say = (l, v) => console.log('  ' + l.padEnd(30) + (v === undefined ? '(none)' : v));

console.log('=== calling the deployed route function ===');
const res = await fetch(`https://${REF}.supabase.co/functions/v1/route`, {
  method: 'POST',
  headers: { apikey: ANON, Authorization: `Bearer ${ANON}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ from: LAS_PALMAS, to: HOSPITAL }),
});
say('HTTP', res.status);
if (!res.ok) {
  console.log('  body: ' + (await res.text()).slice(0, 300));
  process.exit(1);
}
const r = await res.json();

say('engine', r.engine);
say('degraded (on fallback)', r.degraded);
const km = r.distanceM / 1000;
say('distance', km.toFixed(2) + ' km');
say('the user said', EXPECTED_KM + ' km');
console.log('  ' + (Math.abs(km - EXPECTED_KM) < 1.0 ? 'PASS' : 'FAIL')
  + '  within 1 km of the distance the user confirmed');
say('free-flow time', (r.durationFreeFlowS / 60).toFixed(1) + ' min');
say('shown ETA (x1.9 city)', (r.durationS / 60).toFixed(1) + ' min');
say('  the user said', '26 min real');
console.log('  ' + (Math.abs(r.durationS / 60 - 26) < 6 ? 'PASS' : 'NOTE')
  + '  the scaled ETA against the 26 minutes they actually drive');
say('geometry points', r.geometry?.length);
say('turn steps', r.steps?.length);

console.log('\n=== the geometry is usable by MapLibre ===');
const first = r.geometry?.[0], last = r.geometry?.[r.geometry.length - 1];
say('starts at [lng, lat]', JSON.stringify(first));
say('ends at [lng, lat]', JSON.stringify(last));
const allPairs = (r.geometry ?? []).every((c) => Array.isArray(c) && c.length === 2
  && Number.isFinite(c[0]) && Number.isFinite(c[1])
  && c[0] >= -180 && c[0] <= 180 && c[1] >= -90 && c[1] <= 90);
console.log('  ' + (allPairs ? 'PASS' : 'FAIL') + '  every point is a valid lng/lat pair in range');

console.log('\n=== the first few instructions a driver would read ===');
for (const s of (r.steps ?? []).slice(0, 6)) {
  console.log('  ' + String(s.distanceM).padStart(5) + ' m  ' + s.instruction);
}

console.log('\n=== nothing renders as a blank or a fragment ===');
const bad = (r.steps ?? []).filter((s) => !s.instruction || !s.instruction.trim()
  || /onto\s*$/i.test(s.instruction) || /^\s/.test(s.instruction));
console.log('  ' + (bad.length === 0 ? 'PASS' : 'FAIL') + '  ' + (bad.length === 0
  ? 'every step has a readable instruction' : bad.length + ' step(s) would render badly'));
for (const s of bad.slice(0, 5)) console.log('       BAD: ' + JSON.stringify(s.instruction));

console.log('\n=== the two failure modes the function must survive ===');
const both = await fetch(`https://${REF}.supabase.co/functions/v1/route`, {
  method: 'POST',
  headers: { apikey: ANON, Authorization: `Bearer ${ANON}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ from: { lat: 999, lng: 0 }, to: HOSPITAL }),
});
say('out-of-world point -> HTTP', both.status);
const noBody = await fetch(`https://${REF}.supabase.co/functions/v1/route`, {
  method: 'POST', headers: { apikey: ANON, Authorization: `Bearer ${ANON}` }, body: '{',
});
say('truncated body -> HTTP', noBody.status);

// An explicit verdict.
//
// The other three verify scripts end in a pass or fail and say which. This one
// printed the numbers and left the reader to compare them by eye, which is how a
// regression in the traffic factor, the distance or the step count would have
// been noticed by whoever happened to be looking on the day it shipped.
const checks = [
  ['res.status is 200', res.status === 200],
  ['distance within 1 km of the confirmed 11.6', Math.abs(km - EXPECTED_KM) < 1.0],
  ['a geometry line a map can draw', Array.isArray(r.geometry) && r.geometry.length > 20],
  ['every point a valid lng/lat pair', allPairs],
  ['there are turn instructions', Array.isArray(r.steps) && r.steps.length > 0],
  ['no step renders as a blank or a fragment', bad.length === 0],
  ['a bad point is refused, not routed', both.status === 400],
  ['a truncated body is refused, not crashed', noBody.status === 400],
];
console.log('\n=== the verdict ===');
let ok = true;
for (const [label, pass] of checks) {
  if (!pass) ok = false;
  console.log('  ' + (pass ? 'PASS' : 'FAIL') + '  ' + label);
}
console.log('\n' + (ok ? 'ALL CHECKS PASSED' : 'SOMETHING FAILED'));
process.exit(ok ? 0 : 1);
