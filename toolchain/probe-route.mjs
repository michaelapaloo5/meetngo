// Asks the deployed `route` function for a real Accra road and prints what came
// back, so "the line is still straight" can be attributed to the app or to the
// service instead of guessed at.
//
//   node toolchain/probe-route.mjs
import { readFileSync } from 'node:fs';

const env = readFileSync('toolchain/apk-build.env', 'utf8');
const url = env.match(/^\s*SB_URL=(.*)$/m)?.[1]?.trim();
const key = env.match(/^\s*SB_ANON_KEY=(.*)$/m)?.[1]?.trim();
if (!url || !key) throw new Error('toolchain/apk-build.env is missing SB_URL or SB_ANON_KEY');

// Tesano -> Dansoman, roughly, which is the run the recent trips are.
const from = { lat: Number(process.argv[2] ?? 5.5676), lng: Number(process.argv[3] ?? -0.1436) };
const to = { lat: Number(process.argv[4] ?? 5.5357), lng: Number(process.argv[5] ?? -0.1600) };

const started = Date.now();
const res = await fetch(`${url}/functions/v1/route`, {
  method: 'POST',
  headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ from, to }),
});
const text = await res.text();
const ms = Date.now() - started;

console.log(`status ${res.status} in ${ms}ms`);
console.log(`body length ${text.length}`);

let body;
try {
  body = JSON.parse(text);
} catch {
  console.log('not JSON:', text.slice(0, 400));
  process.exit(1);
}

if (!body.geometry) {
  console.log('no geometry:', JSON.stringify(body).slice(0, 400));
  process.exit(1);
}

const coords = body.geometry;
console.log(`engine        ${body.engine}  degraded=${body.degraded}`);
console.log(`distanceM     ${body.distanceM}`);
console.log(`durationS     ${body.durationS} (free-flow ${body.durationFreeFlowS})`);
console.log(`geometry      ${coords.length} points`);
console.log(`steps         ${(body.steps ?? []).length}`);

// Straight-line for comparison, so the two can be compared by eye.
const R = 6371000;
const toRad = (d) => (d * Math.PI) / 180;
const dLat = toRad(to.lat - from.lat);
const dLng = toRad(to.lng - from.lng);
const a =
  Math.sin(dLat / 2) ** 2 +
  Math.cos(toRad(from.lat)) * Math.cos(toRad(to.lat)) * Math.sin(dLng / 2) ** 2;
const straightM = 2 * R * Math.asin(Math.sqrt(a));
console.log(`straight-line ${Math.round(straightM)} m`);
console.log(`road/straight ${(body.distanceM / straightM).toFixed(2)}x`);

// Is it actually a road, or two points?
let moved = 0;
for (let i = 1; i < coords.length; i++) {
  if (coords[i][0] !== coords[0][0] || coords[i][1] !== coords[0][1]) moved++;
}
console.log(`points off the first one: ${moved}/${coords.length - 1}`);
