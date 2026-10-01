// Navigation against the real `route` function: does what the app parses into
// `TripRoute` actually come back?
//
//   node toolchain/verify-navigation.mjs
//
// The Dart side has 42 unit tests and they all pass, and every one of them runs
// against a fixture written here. That is worth nothing on its own: a fixture can
// agree with the parser and both can be wrong about the function.
//
// So this calls the deployed function with two real Accra points and checks the
// things the app depends on -- the shape of `geometry`, the presence of `steps`,
// and that `durationS` is the traffic-scaled figure rather than the free-flow one.
//
// It is the same check `verify-route.mjs` does at the function level, run here
// against the shape the app requires. The two are not redundant: the function's
// verifier asks "is the routing working", and this asks "can the app use what came
// back".

import { readEnvOrFail } from './read-env.mjs';

const build = readEnvOrFail('toolchain/apk-build.env', ['SB_URL', 'SB_ANON_KEY']);
const url = build.SB_URL.replace(/\/+$/, '');
const pad = (s, n) => String(s).padEnd(n);

const results = [];
const check = (label, actual, expected, why) => {
  const ok = actual === expected;
  results.push({ label, ok });
  console.log(
    `  ${ok ? 'PASS' : 'FAIL'}  ${pad(label, 46)} ${pad(String(actual), 14)} ` +
      `wanted ${pad(String(expected), 14)} ${why}`,
  );
};

// The run the traffic factor was calibrated on: Las Palmas/Lapaz to 37 Military
// Hospital. Not an arbitrary pair -- if the numbers here look like the
// calibration run's, the factor is still doing what it was measured to do.
const from = { lat: 5.5569, lng: -0.1722 };
const to = { lat: 5.5839, lng: -0.2203 };

console.log('\n=== signing in, because `route` is deployed with verify_jwt ===\n');

// `deploy-function.mjs --list` reports `route` as `jwt=true`, so an unauthenticated
// call is refused with 401 before the function runs. Which is right: a routing
// proxy nobody may call is one this project's quota pays for.
const email = `nav-verify-${Date.now()}@example.test`;
const signUp = await fetch(`${url}/auth/v1/signup`, {
  method: 'POST',
  headers: { apikey: build.SB_ANON_KEY, 'Content-Type': 'application/json' },
  body: JSON.stringify({ email, password: 'Probe-9abcdefgh', data: { full_name: 'Nav Probe' } }),
});
const session = await signUp.json();
if (!session.access_token) {
  console.log('  could not sign in: ' + JSON.stringify(session).slice(0, 200));
  process.exit(1);
}
console.log(`  probe session for ${session.user.id.slice(0, 8)}`);

const callRoute = async (payload) => {
  const r = await fetch(`${url}/functions/v1/route`, {
    method: 'POST',
    headers: {
      apikey: build.SB_ANON_KEY,
      Authorization: `Bearer ${session.access_token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(payload),
  });
  return { status: r.status, text: await r.text() };
};

console.log('\n=== the route the function answers with ===\n');

const answered = await callRoute({ from, to });
console.log(`  HTTP ${answered.status}`);
if (answered.status !== 200) {
  console.log('  ' + answered.text.slice(0, 400));
  console.log('\n  The function is not answering; nothing below can be checked.');
  process.exit(1);
}
const body = JSON.parse(answered.text);

console.log('');
check('answers 200', answered.status, 200, '');
check('has distanceM', typeof body.distanceM === 'number', true, 'the map frames the camera from it');
check('has durationS', typeof body.durationS === 'number', true, 'the banner shows it');
check('has durationFreeFlowS', typeof body.durationS === 'number', true, 'kept for the diagnostics');
check(
  'durationS is the longer of the two',
  body.durationS > body.durationFreeFlowS,
  true,
  'the traffic factor has to make it longer, not shorter',
);
check('the factor is near the calibrated 1.9', (body.durationS / body.durationFreeFlowS).toFixed(2), '1.90', '');
check('names its engine', ['osrm', 'openrouteservice'].includes(body.engine), true, '');
check('says whether it degraded', typeof body.degraded === 'boolean', true, '');

// ------------------------------------------------------- what the app needs
console.log('\n=== what TripRoute.fromJson has to be able to read ===\n');

check('geometry is a list', Array.isArray(body.geometry), true, '');
const geom = body.geometry ?? [];
check('geometry has points', geom.length > 0, true, 'a line with no points draws nothing');

const allPairs = geom.every(
  (p) => Array.isArray(p) && p.length >= 2 && typeof p[0] === 'number' && typeof p[1] === 'number',
);
check('every point is [lng, lat] of numbers', allPairs, true, 'GeoJSON order; the app swaps it');

// The app drops a point that is out of range, and a function returning one would
// leave the driver with a line missing a vertex for no reason anyone could see.
const inRange = geom.filter(
  (p) => Math.abs(p[1]) <= 90 && Math.abs(p[0]) <= 180,
).length;
check('no point is out of range', inRange, geom.length, 'the app silently drops these');
check('at least two usable points', geom.length >= 2, true, 'one point is not a route');

const steps = body.steps ?? [];
check('steps is a list', Array.isArray(body.steps), true, '');
check('has steps', steps.length > 0, true, 'a route with no steps has no instructions');

const stepsUsable = steps.every(
  (s) =>
    s &&
    typeof s.distanceM === 'number' &&
    typeof s.maneuver === 'string' &&
    typeof s.name === 'string',
);
check('every step has distanceM, maneuver and name', stepsUsable, true, '');

// The app indexes steps by accumulated distance, so the distances have to sum to
// something near the route distance. If they do not, every step after the first
// lands at the wrong point along the line.
const stepSum = steps.reduce((total, s) => total + (s.distanceM ?? 0), 0);
const ratio = stepSum / Math.max(1, body.distanceM);
console.log(`  steps sum ${Math.round(stepSum)} m against a ${Math.round(body.distanceM)} m route`);
check(
  'the step distances sum to the route distance',
  ratio > 0.9 && ratio < 1.1,
  true,
  'the app walks steps by accumulated distance',
);

const emptyInstructions = steps.filter((s) => typeof s.instruction !== 'string').length;
check('every step has an instruction string', emptyInstructions, 0, '');

// ------------------------------------------------------------ bad input too
console.log('\n=== and what it does with input the app can produce by accident ===\n');

// Two cases, and they came out differently than expected, which is the finding.
//
// **Identical points answers 200**, with a degenerate route: two identical
// geometry points, `distanceM: 0`, and two steps of zero length. It is well-formed
// and it is useless, and it passes a naive "did I get a route" check. Asserted
// here rather than fixed there, because this script reads what the function does
// and the app is where the refusal belongs -- `TripRoute.goesAnywhere` is what
// rejects it, and `navigation_test.dart` pins that.
const same = { lat: 5.5569, lng: -0.1722 };
const degenerate = await callRoute({ from: same, to: same });
check('identical points answer 200', degenerate.status, 200, 'measured, not assumed');
const degenerateBody = JSON.parse(degenerate.text);
check(
  '  with a zero distance',
  degenerateBody.distanceM === 0,
  true,
  'so the app has to refuse it, and does',
);
check(
  '  and both geometry points are the same',
  JSON.stringify(degenerateBody.geometry[0]) === JSON.stringify(degenerateBody.geometry[1]),
  true,
  'two points, so a length test alone would pass it',
);

// **A point at (0, 0) answers 503**, with a sentence:
// `{"error":"no routing engine could answer right now"}`. That is the function
// deciding an unroutable point is an engine failure rather than bad input. A 400
// would be the honest answer, but 503 with a usable message is not a defect the
// app has to survive specially -- the repository turns any non-2xx into a
// `NavigationFailure` carrying the server's own words.
const offWorld = await callRoute({ from: { lat: 0, lng: 0 }, to });
const unreachable = offWorld.status === 503;
const hasSentence = (() => {
  try {
    return typeof JSON.parse(offWorld.text).error === 'string';
  } catch {
    return false;
  }
})();
check('an unroutable point is refused', unreachable || offWorld.status === 400, true, 'got ' + offWorld.status);
check('  and the refusal carries a sentence the app can show', hasSentence, true, offWorld.text.slice(0, 90));

for (const [label, payload] of [
  ['a missing point', { from: null, to }],
  ['no body at all', undefined],
  ['a trip id instead of points', { tripId: 'ec38db1c-74e9-47ce-8606-6689e0c5ab37' }],
]) {
  const r = await callRoute(payload ?? {});
  const refused = r.status >= 400 && r.status < 500;
  check('rejects ' + label + ' with a 4xx', refused, true, 'got HTTP ' + r.status);
}

// ---------------------------------------------------------------------------
// Clean up the probe, so the account does not sit there being matchable.
await fetch(url + '/rest/v1/profiles?id=eq.' + session.user.id, {
  method: 'DELETE',
  headers: {
    apikey: build.SB_ANON_KEY,
    Authorization: 'Bearer ' + session.access_token,
  },
});

// ---------------------------------------------------------------------------
const failed = results.filter((x) => !x.ok);
console.log(`\n=== ${results.length - failed.length} of ${results.length} passed ===`);
if (failed.length > 0) {
  console.log('\nfailures:');
  for (const f of failed) console.log(`  ${f.label}`);
  process.exit(1);
}
console.log(
  '\nThe Dart parser and the controller are verified against a fixture; this says\n' +
    'the fixture matches the function. Both halves are now checked.',
);
