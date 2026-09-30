// Routing, with every engine stubbed. The point of these is that they do not
// touch the network, so they run on a machine with no internet and they keep
// running when an upstream service changes its URL or starts refusing a key --
// which is exactly what happened to the OpenRouteService account.
//
// What they cannot tell you is whether the real OSRM server is up. That is
// `toolchain/verify-route.mjs`.

import { assert, assertEquals } from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import {
  CITY_TRAFFIC_FACTOR,
  fromOpenRouteService,
  fromOsrm,
  getRoute,
  handleRoute,
  parseRouteRequest,
  stepInstruction,
} from '../route/route.ts';

const ACCRA: [number, number] = [-0.187, 5.6037];
const HOSPITAL: [number, number] = [-0.1666, 5.6052];

// A mutable OSRM body, so a test can damage one field without an `any` cast and
// without rebuilding the whole fixture.
interface StubOsrm {
  code: string;
  routes: {
    distance: number | null;
    duration: number;
    geometry: { type: string; coordinates: unknown[] };
    legs: { steps: unknown[] }[];
  }[];
}

function osrmBody(): StubOsrm {
  return {
    code: 'Ok',
    routes: [{
      distance: 9040,
      duration: 810,
      geometry: { type: 'LineString', coordinates: [ACCRA, [-0.18, 5.604], HOSPITAL] },
      legs: [{
        steps: [
          { name: 'Patrice Lumumba Road', distance: 120, maneuver: { type: 'depart', modifier: 'left' } },
          { name: 'Switchback Road', distance: 340, maneuver: { type: 'turn', modifier: 'left' } },
          { name: '', distance: 60, maneuver: { type: 'turn', modifier: 'slight right' } },
          { name: 'Main Road', distance: 90, maneuver: { type: 'arrive' } },
        ],
      }],
    }],
  };
}

function orsBody() {
  return {
    routes: [{
      summary: { distance: 9100, duration: 830 },
      geometry: { type: 'LineString', coordinates: [ACCRA, HOSPITAL] },
      legs: [{
        steps: [
          { type: 0, name: 'Patrice Lumumba Road', distance: 120, turn_type: 'left' },
          { type: 0, name: '', distance: 60, turn_type: 'slight right' },
          { type: 5, name: 'Hospital Gate', distance: 0 },
        ],
      }],
    }],
  };
}

const stub = (body: unknown, ok = true) =>
  () => Promise.resolve(new Response(JSON.stringify(body), { status: ok ? 200 : 500 }));

const REFUSING = () => Promise.resolve(new Response('{"error":"Access to this API has been disallowed"}', { status: 403 }));

Deno.test('a turn with a street name says where it turns onto', () => {
  assertEquals(
    stepInstruction('turn', 'left', 'Switchback Road'),
    'Turn left onto Switchback Road',
  );
});

Deno.test('a turn on an unnamed road does not say "onto " with nothing after it', () => {
  // The named roads in Accra outnumber the unnamed ones, so a real turn onto
  // a service road has an empty name. "Turn slight right onto " renders as a
  // dangling fragment on the driver's screen, which is the bug this pins.
  const said = stepInstruction('turn', 'slight right', '');
  assert(!said.endsWith('onto '), `dangling "onto ": ${said}`);
  assert(said.length > 0);
});

Deno.test('a sharp turn keeps its sharpness', () => {
  assertEquals(stepInstruction('turn', 'sharp left', 'Nsawam Road'), 'Make a sharp left turn onto Nsawam Road');
});

Deno.test('arrival does not name a road it has not been given', () => {
  assertEquals(stepInstruction('arrive', '', 'Hospital Gate'), 'You have arrived at your destination');
});

Deno.test('an unrecognised maneuver still produces something readable', () => {
  // OSRM adds maneuvers between releases, and an empty string is what a rider
  // sees if this returns one.
  for (const m of ['u_turn', 'roundabout', 'notification', 'exit', 'exit_rotary', '']) {
    const said = stepInstruction(m, '', 'Something Road');
    assert(said.length > 0, `empty instruction for ${JSON.stringify(m)}`);
  }
});

Deno.test('OSRM geometry comes out in GeoJSON lng-lat order', () => {
  // Getting this backwards draws the line in the Indian Ocean and is invisible
  // in a test that only checks the length.
  const parsed = fromOsrm(osrmBody());
  assert(parsed !== null);
  assertEquals(parsed!.geometry[0], ACCRA);
  assertEquals(parsed!.geometry[parsed!.geometry.length - 1], HOSPITAL);
});

Deno.test('a route with one point is refused, not drawn as a stub', () => {
  const body = osrmBody();
  body.routes[0].geometry = { type: 'LineString', coordinates: [ACCRA] };
  assertEquals(fromOsrm(body), null);
});

Deno.test('a non-finite distance is refused rather than becoming NaN metres', () => {
  const body = osrmBody();
  body.routes[0].distance = null;
  assertEquals(fromOsrm(body), null);
});

Deno.test('both engines normalise to the same shape', () => {
  const a = fromOsrm(osrmBody());
  const b = fromOpenRouteService(orsBody());
  assert(a !== null && b !== null);
  assertEquals(Object.keys(a!).sort(), Object.keys(b!).sort());
});

Deno.test('ORS steps are read even though ORS speaks in numeric type codes', () => {
  const parsed = fromOpenRouteService(orsBody());
  assertEquals(parsed!.steps.length, 3);
  assert(parsed!.steps.every((s) => s.instruction.length > 0), 'an ORS step rendered as an empty string');
});

Deno.test('with no key configured the function uses OSRM and is not degraded', async () => {
  const calls: string[] = [];
  const route = await getRoute(
    { lat: ACCRA[1], lng: ACCRA[0] },
    { lat: HOSPITAL[1], lng: HOSPITAL[0] },
    {
      fetch: ((url: string) => { calls.push(String(url)); return stub(osrmBody())(); }) as typeof fetch,
      orsKey: null,
    },
  );
  assert(route !== null);
  assertEquals(route!.engine, 'osrm');
  assertEquals(route!.degraded, false, 'no key is the normal state, not a degradation');
  assertEquals(calls.length, 1);
  assert(String(calls[0]).startsWith('https://router.project-osrm.org/'));
});

Deno.test('a refused ORS key falls through to OSRM and says so', async () => {
  // The real state of the account today: 403 on every endpoint. Without the
  // fall-through the rider gets no route at all; without `degraded` the driver
  // gets a worse route and no explanation, which becomes a support ticket.
  const calls: string[] = [];
  const route = await getRoute(
    { lat: ACCRA[1], lng: ACCRA[0] },
    { lat: HOSPITAL[1], lng: HOSPITAL[0] },
    {
      fetch: ((url: string) => {
        calls.push(String(url));
        return String(url).includes('heigit') ? REFUSING() : stub(osrmBody())();
      }) as typeof fetch,
      orsKey: 'a-key',
    },
  );
  assert(route !== null);
  assertEquals(route!.engine, 'osrm');
  assertEquals(route!.degraded, true);
  assertEquals(calls.length, 2, 'the primary must actually be tried before falling back');
});

Deno.test('a working ORS key is used and is not reported as degraded', async () => {
  const route = await getRoute(
    { lat: ACCRA[1], lng: ACCRA[0] },
    { lat: HOSPITAL[1], lng: HOSPITAL[0] },
    { fetch: stub(orsBody()) as typeof fetch, orsKey: 'a-key' },
  );
  assert(route !== null);
  assertEquals(route!.engine, 'openrouteservice');
  assertEquals(route!.degraded, false);
});

Deno.test('an ORS key that times out still produces a route', async () => {
  // A hung primary must not hang the rider. 403 is easy; a socket that never
  // answers is what actually happens to a service you do not control.
  const route = await getRoute(
    { lat: ACCRA[1], lng: ACCRA[0] },
    { lat: HOSPITAL[1], lng: HOSPITAL[0] },
    {
      fetch: ((url: string) =>
        String(url).includes('heigit')
          ? new Promise<Response>(() => {}) // never settles
          : stub(osrmBody())()) as typeof fetch,
      orsKey: 'a-key',
      timeoutMs: 40,
    },
  );
  assert(route !== null);
  assertEquals(route!.engine, 'osrm');
  assertEquals(route!.degraded, true);
});

Deno.test('the ETA is the free-flow time scaled for a city, and both are reported', async () => {
  // The whole reason `durationS` and `durationFreeFlowS` are separate fields.
  // 810s free-flow against 26 minutes real in Accra is the calibration, and a
  // UI that shows the free-flow number is showing a driver an arrival time
  // that is nearly two hours out.
  const route = await getRoute(
    { lat: ACCRA[1], lng: ACCRA[0] },
    { lat: HOSPITAL[1], lng: HOSPITAL[0] },
    { fetch: stub(osrmBody()) as typeof fetch },
  );
  assert(route !== null);
  assertEquals(route!.durationFreeFlowS, 810);
  assertEquals(route!.durationS, Math.round(810 * CITY_TRAFFIC_FACTOR));
  assert(route!.durationS > route!.durationFreeFlowS, 'the ETA must not be better than free-flow');
});

Deno.test('both engines down is a 503, not a 500', async () => {
  // Nothing is broken on our side, so this is "try again", not "log a fault".
  const res = await handleRoute(
    new Request('https://x/route', { method: 'POST', body: JSON.stringify({ from: { lat: 1, lng: 1 }, to: { lat: 2, lng: 2 } }) }),
    { fetch: REFUSING as typeof fetch, orsKey: 'a-key' },
  );
  assertEquals(res.status, 503);
});

Deno.test('a point outside the world is refused', () => {
  assertEquals(parseRouteRequest({ from: { lat: 91, lng: 0 }, to: { lat: 1, lng: 1 } }), null);
  assertEquals(parseRouteRequest({ from: { lat: 0, lng: 181 }, to: { lat: 1, lng: 1 } }), null);
  assertEquals(parseRouteRequest({ from: { lat: 'x', lng: 0 }, to: { lat: 1, lng: 1 } }), null);
  assertEquals(parseRouteRequest({ from: { lat: 0, lng: 0 } }), null);
  assertEquals(parseRouteRequest({ lat: 0, lng: 0, to: { lat: 1, lng: 1 } }), null);
});

Deno.test('a point given as a string is refused rather than coerced', () => {
  // `"5.6"` would become 5.6 and quietly place the pickup somewhere the rider
  // is not. Coercing coordinates is how a navigation screen ends up pointing
  // at an empty field.
  assertEquals(parseRouteRequest({ from: { lat: '5.6', lng: '-0.2' }, to: { lat: 1, lng: 1 } }), null);
});

Deno.test('a trip to where you already are is a route, not an error', () => {
  const parsed = parseRouteRequest({ from: { lat: 5.6, lng: -0.2 }, to: { lat: 5.6, lng: -0.2 } });
  assert(parsed !== null, 'the driver asking "how far is the pickup" is a real question');
});

Deno.test('a truncated body is a 400, not an unhandled throw', () => {
  return handleRoute(
    new Request('https://x/route', { method: 'POST', body: '{"from":' }),
    { fetch: stub(osrmBody()) as typeof fetch },
  ).then((res) => assertEquals(res.status, 400));
});

Deno.test('the only method accepted is POST', () => {
  return handleRoute(new Request('https://x/route'), { fetch: stub(osrmBody()) as typeof fetch })
    .then((res) => assertEquals(res.status, 405));
});
