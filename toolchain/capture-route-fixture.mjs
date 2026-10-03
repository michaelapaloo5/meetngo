// Captures a real `route` response to a fixture file, so the driver's turn-by-turn
// logic can be checked against what the engine actually returns rather than
// against coordinates someone typed.
//
//   node toolchain/capture-route-fixture.mjs
//
// The point is that a turn banner is only as good as the geometry behind it, and
// hand-written test coordinates are the one thing guaranteed not to look like a
// real road: no snaps to junctions, no unnamed service roads, no zero-length
// steps. A bug that only appears on real geometry -- a step whose distance runs
// backwards, a projection that snaps to the wrong segment -- passes every test
// written against invented points.
import { readFileSync, writeFileSync } from 'node:fs';

const env = readFileSync('toolchain/apk-build.env', 'utf8');
const url = env.match(/^\s*SB_URL=(.*)$/m)?.[1]?.trim();
const key = env.match(/^\s*SB_ANON_KEY=(.*)$/m)?.[1]?.trim();
if (!url || !key) throw new Error('toolchain/apk-build.env is missing SB_URL or SB_ANON_KEY');

// Obibini Street, Tesano to Dansoman Police Station: the run the app's own recent
// rides are on, so the fixture is a route the pilot will actually be shown.
const from = { lat: 5.5879, lng: -0.22045 };
const to = { lat: 5.54353, lng: -0.26457 };

const res = await fetch(`${url}/functions/v1/route`, {
  method: 'POST',
  headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ from, to }),
});
if (!res.ok) throw new Error(`route function answered ${res.status}`);
const body = await res.json();
if (!Array.isArray(body.geometry) || body.geometry.length < 2) {
  throw new Error('no geometry in the answer');
}

const out = 'apps/driver/test/navigation/fixtures/real_route_tesano_dansoman.json';
writeFileSync(out, JSON.stringify(body, null, 2) + '\n');

console.log(`wrote ${out}`);
console.log(`  engine      ${body.engine} degraded=${body.degraded}`);
console.log(`  distanceM   ${body.distanceM}`);
console.log(`  geometry    ${body.geometry.length} points`);
console.log(`  steps       ${body.steps.length}`);
for (const s of body.steps) {
  console.log(`    ${String(Math.round(s.distanceM)).padStart(5)} m  ${s.instruction}`);
}
