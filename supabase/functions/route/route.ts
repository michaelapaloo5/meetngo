// Turn-by-turn routing, proxied so the app never holds a routing credential.
//
// The app calls this with two points and gets back one normalised shape,
// whichever engine answered. That is the whole point: the routing provider is
// an implementation detail behind a function that is already deployed and
// already authenticated, so nothing about it has to ship inside the APK where
// anyone who unzips it can read the key.
//
// Engines, in the order they are tried:
//
//   1. OpenRouteService, when `ORS_API_KEY` is set and the key is accepted.
//      2,000 routes/day, 40/min. The key is a Supabase function secret, so it
//      is never in the repository and never in the app.
//   2. The public OSRM server. No account, no key, no card, no signup. It is a
//      shared courtesy service with no SLA, which is the tradeoff for needing
//      nothing at all -- and for a pilot whose entire routing bill so far is
//      zero, that is the right side of the trade.
//
// The current state of the ORS key is that the account is refused: every
// endpoint, old and new, answers 403 "Access to this API has been disallowed",
// which is an account-level refusal rather than a bad key (a bad key is 401).
// So today every route comes from OSRM, and the day that key starts working
// this function uses it without any change to the app. The ORS branch is live
// code, not a stub, and it is exercised by the tests with a stubbed fetch.
//
// Times: neither engine has live traffic. Both return free-flow, which on the
// Las Palmas -> 37 Military Hospital run is 13.5 minutes against a real 26 on
// a normal Accra day -- roughly 1.9x optimistic. Both are returned, separately
// named, so the app can show one and reason about the other.

import { corsHeaders } from '../_shared/cors.ts';

export interface RoutePoint {
  lat: number;
  lng: number;
}

export interface RouteStep {
  /** Spoken and written form, ready to render. Never empty. */
  instruction: string;
  distanceM: number;
  /** OSRM/OSR nomenclature: turn, new name, depart, arrive, merge, ... */
  maneuver: string;
  /** The road being joined, empty where the step has no name. */
  name: string;
}

export interface RouteShape {
  /** Metres along the road, not as the crow flies. */
  distanceM: number;
  /** Free-flow seconds, exactly as the engine reported them. */
  durationFreeFlowS: number;
  /**
   * What to actually show a rider, in seconds: free-flow scaled by
   * `trafficFactor`. See `CITY_TRAFFIC_FACTOR` for why this exists and what
   * it is not.
   */
  durationS: number;
  /** [lng, lat] pairs, GeoJSON order, ready for a MapLibre `line` source. */
  geometry: Array<[number, number]>;
  steps: RouteStep[];
  /** Which engine answered. Shown in the app's diagnostics, not to riders. */
  engine: 'openrouteservice' | 'osrm';
  /**
   * True when the primary engine was tried and refused, so the app can log
   * that it is on the fallback rather than on the paid quota. A driver seeing
   * a slightly worse route and no explanation is a support ticket.
   */
  degraded: boolean;
}

/**
 * Free-flow to real-city-time, for Accra.
 *
 * Not a traffic model: OSRM and OpenRouteService have no live traffic, and no
 * free engine does. This is a single multiplier, and it is calibrated to one
 * observation -- 13.5 minutes free-flow against 26 minutes real on the
 * Las Palmas/Lapaz to 37 Military Hospital run -- which is 1.93. It is set to
 * 1.9 and it is a constant rather than a per-route guess, because a number that
 * looks computed but is not is worse than a number that is obviously a rule.
 *
 * The residual is worth stating: a 2 km hop at 3am will be reported 90%
 * optimistic, and a 40 km highway run 30% optimistic. When a real traffic
 * source is affordable this constant is what gets replaced, and it is the only
 * thing that has to change -- the app reads `durationS` and never does this
 * arithmetic itself.
 */
export const CITY_TRAFFIC_FACTOR = 1.9;

/** How long to wait on an engine before falling through to the next one. */
export const ENGINE_TIMEOUT_MS = 8000;

const isFiniteNumber = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v);

/** A two-number array, which is what a GeoJSON coordinate is. */
function isCoordPair(v: unknown): v is [number, number] {
  return Array.isArray(v) && v.length >= 2 && isFiniteNumber(v[0]) && isFiniteNumber(v[1]);
}

function asRecord(v: unknown): Record<string, unknown> | null {
  return typeof v === 'object' && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : null;
}

function isRoutePoint(v: unknown): v is RoutePoint {
  const p = asRecord(v);
  if (p === null) return false;
  return isFiniteNumber(p.lat) && isFiniteNumber(p.lng)
    && p.lat >= -90 && p.lat <= 90 && p.lng >= -180 && p.lng <= 180;
}

/**
 * Turn OSRM's `maneuver.type` and street name into a sentence.
 *
 * OSRM speaks in grammar, not language: `turn` plus a modifier plus a name. A
 * screen that showed the raw token would say "turn slight right Patrice
 * Lumumba Road" or, where the name is empty, render a dangling "onto ". Both
 * are worse than a sentence a rider can act on, and a missing name is normal
 * on unnamed service roads, so the name is conditional throughout.
 */
export function stepInstruction(maneuver: string, modifier: string, name: string): string {
  const where = name ? ` onto ${name}` : '';
  switch (maneuver) {
    case 'depart':
      return name ? `Head out on ${name}` : 'Head out';
    case 'arrive':
      return 'You have arrived at your destination';
    case 'turn':
      if (modifier === 'sharp right' || modifier === 'sharp left') {
        return `Make a ${modifier} turn${where}`;
      }
      if (modifier === 'right' || modifier === 'left') return `Turn ${modifier}${where}`;
      if (modifier === 'straight') return `Continue straight${where}`;
      return `Turn${where || ' ahead'}`;
    case 'new name':
      return `Continue onto ${name || 'the road ahead'}`;
    case 'merge':
      return `Merge${where}`;
    case 'on ramp':
      return `Take the ramp${where || ' ahead'}`;
    case 'off ramp':
      return `Take the exit${where || ' ahead'}`;
    case 'fork':
      return `Keep ${modifier === 'left' ? 'left' : 'right'}${where}`;
    case 'end of road':
      return `Turn ${modifier === 'left' ? 'left' : 'right'} at the end of the road${where}`;
    case 'roundabout':
    case 'rotary':
      return `At the roundabout, take the exit${where}`;
    case 'roundabout turn':
      return `At the roundabout, take the exit${where}`;
    default:
      return name ? `Continue${where}` : 'Continue';
  }
}

function applyFactor(freeFlowS: number): number {
  return Math.round(freeFlowS * CITY_TRAFFIC_FACTOR);
}

function normalise(raw: RawRoute, degraded: boolean): RouteShape {
  return {
    distanceM: Math.round(raw.distanceM),
    durationFreeFlowS: Math.round(raw.durationS),
    durationS: applyFactor(raw.durationS),
    geometry: raw.geometry,
    steps: raw.steps,
    engine: raw.engine,
    degraded,
  };
}

type Fetch = typeof fetch;

/** An engine's answer, before the city factor and before `degraded` is known. */
interface RawRoute {
  distanceM: number;
  /** Free-flow seconds, exactly as the engine reported them. */
  durationS: number;
  geometry: Array<[number, number]>;
  steps: RouteStep[];
  engine: RouteShape['engine'];
}

/** Normalise an OpenRouteService `driving-car` response. */
export function fromOpenRouteService(body: unknown): RawRoute | null {
  const root = asRecord(body);
  const routes = root?.routes;
  if (!Array.isArray(routes) || routes.length === 0) return null;
  const route = asRecord(routes[0]);
  if (route === null) return null;

  const summary = asRecord(route.summary);
  const geometry = asRecord(route.geometry)?.coordinates;
  if (summary === null || !Array.isArray(geometry) || geometry.length < 2) return null;
  if (!isFiniteNumber(summary.distance) || !isFiniteNumber(summary.duration)) return null;

  const steps: RouteStep[] = [];
  for (const leg of Array.isArray(route.legs) ? route.legs : []) {
    const legRecord = asRecord(leg);
    if (legRecord === null) continue;
    for (const s of Array.isArray(legRecord.steps) ? legRecord.steps : []) {
      const step = asRecord(s);
      if (step === null || !isFiniteNumber(step.distance)) continue;
      const name = typeof step.name === 'string' ? step.name : '';
      // ORS uses a numeric `type` of 0-12 where OSRM uses words. Only the ones
      // that produce a different sentence are mapped; the rest fall through to
      // the default, which is what ORS calls most of its steps anyway.
      const type = isFiniteNumber(step.type) ? step.type : -1;
      const maneuver = type === 0 ? 'turn' : type === 1 ? 'new name' : type === 5 ? 'arrive' : 'continue';
      const modifier = typeof step.turn_type === 'string' ? step.turn_type : '';
      steps.push({
        instruction: stepInstruction(maneuver, modifier, name),
        distanceM: Math.round(step.distance),
        maneuver,
        name,
      });
    }
  }
  return {
    distanceM: summary.distance,
    durationS: summary.duration,
    geometry: geometry.filter(isCoordPair),
    steps,
    engine: 'openrouteservice',
  };
}

/** Normalise an OSRM `route/v1/driving` response. */
export function fromOsrm(body: unknown): RawRoute | null {
  const root = asRecord(body);
  const routes = root?.routes;
  if (!Array.isArray(routes) || routes.length === 0) return null;
  const route = asRecord(routes[0]);
  if (route === null) return null;
  if (!isFiniteNumber(route.distance) || !isFiniteNumber(route.duration)) return null;

  const coords = asRecord(route.geometry)?.coordinates;
  if (!Array.isArray(coords) || coords.length < 2) return null;

  const steps: RouteStep[] = [];
  for (const leg of Array.isArray(route.legs) ? route.legs : []) {
    const legRecord = asRecord(leg);
    if (legRecord === null) continue;
    for (const s of Array.isArray(legRecord.steps) ? legRecord.steps : []) {
      const step = asRecord(s);
      if (step === null) continue;
      const maneuverRecord = asRecord(step.maneuver);
      const maneuver = typeof maneuverRecord?.type === 'string' ? maneuverRecord.type : 'continue';
      const modifier = typeof maneuverRecord?.modifier === 'string' ? maneuverRecord.modifier : '';
      const name = typeof step.name === 'string' ? step.name : '';
      steps.push({
        instruction: stepInstruction(maneuver, modifier, name),
        distanceM: isFiniteNumber(step.distance) ? Math.round(step.distance) : 0,
        maneuver,
        name,
      });
    }
  }
  return {
    distanceM: route.distance,
    durationS: route.duration,
    geometry: coords.filter(isCoordPair),
    steps,
    engine: 'osrm',
  };
}

const ORS_BASE = 'https://api.heigit.org/openrouteservice/v2/directions/driving';

/**
 * Ask OSRM, and only OSRM.
 *
 * Split out from `getRoute` so the fallback is directly callable: a test, and
 * any future call that has decided it does not want the primary at all, can
 * reach it without going through the fall-through logic that is the other
 * reason it exists.
 */
export async function fetchOsrm(
  from: RoutePoint,
  to: RoutePoint,
  deps: { fetch: Fetch; timeoutMs?: number },
): Promise<RouteShape | null> {
  const { lat: aLat, lng: aLng } = from;
  const { lat: bLat, lng: bLng } = to;
  const url = `https://router.project-osrm.org/route/v1/driving/`
    + `${aLng},${aLat};${bLng},${bLat}`
    + `?overview=full&geometries=geojson&steps=true`;
  const res = await withTimeout(deps.fetch(url, {
    headers: { 'User-Agent': 'MeetNGo/1.0 (routing proxy)' },
  }), deps.timeoutMs ?? ENGINE_TIMEOUT_MS);
  if (!res.ok) return null;
  const body = await res.json();
  const parsed = fromOsrm(body);
  return parsed ? normalise(parsed, false) : null;
}

async function fetchOpenRouteService(
  from: RoutePoint,
  to: RoutePoint,
  key: string,
  deps: { fetch: Fetch; timeoutMs?: number },
): Promise<RouteShape | null> {
  const res = await withTimeout(deps.fetch(`${ORS_BASE}?profile=driving-car`, {
    method: 'POST',
    headers: { Authorization: key, 'Content-Type': 'application/json' },
    body: JSON.stringify({ coordinates: [[from.lng, from.lat], [to.lng, to.lat]] }),
  }), deps.timeoutMs ?? ENGINE_TIMEOUT_MS);
  if (!res.ok) return null;
  const body = await res.json();
  const parsed = fromOpenRouteService(body);
  return parsed ? normalise(parsed, false) : null;
}

async function withTimeout(work: Promise<Response>, ms: number): Promise<Response> {
  // `Promise.race` with a rejecting timeout rather than `AbortSignal`, so the
  // rejection is observable here instead of arriving as an unhandled rejection
  // from a signal the caller never wired up.
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      work,
      new Promise<never>((_resolve, reject) => {
        timer = setTimeout(() => reject(new Error(`routing engine timed out after ${ms}ms`)), ms);
      }),
    ]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

/**
 * Route between two points, trying the keyed engine first and falling through
 * to the keyless one.
 *
 * `degraded` is true whenever the primary was *attempted and did not answer*,
 * which is the case worth reporting: the app is on the fallback quota rather
 * than the paid one, and a driver on a worse route deserves to know that is
 * why.
 */
export async function getRoute(
  from: RoutePoint,
  to: RoutePoint,
  deps: { fetch: Fetch; orsKey?: string | null; timeoutMs?: number },
): Promise<RouteShape | null> {
  const key = deps.orsKey?.trim();
  let degraded = false;
  if (key) {
    try {
      const primary = await fetchOpenRouteService(from, to, key, deps);
      if (primary) return primary;
      degraded = true;
    } catch {
      // A timeout, a network failure or a 403: all of them mean "try the
      // fallback", and none of them are worth failing the rider's navigation
      // over. The reason is in `degraded`.
      degraded = true;
    }
  }
  try {
    const fallback = await fetchOsrm(from, to, deps);
    if (fallback) return { ...fallback, degraded };
  } catch {
    return null;
  }
  return null;
}

export function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

export function parseRouteRequest(body: unknown): { from: RoutePoint; to: RoutePoint } | null {
  const b = asRecord(body);
  if (b === null) return null;
  if (!isRoutePoint(b.from) || !isRoutePoint(b.to)) return null;
  // A route to the same place is a real thing to ask -- "how far am I from the
  // pickup" -- and OSRM answers it with a two-point line. It is not an error.
  return { from: b.from, to: b.to };
}

export async function handleRoute(
  req: Request,
  deps: { fetch: Fetch; orsKey?: string | null; timeoutMs?: number },
): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json(405, { error: 'POST required' });

  let payload: unknown;
  try {
    payload = await req.json();
  } catch {
    return json(400, { error: 'body must be JSON' });
  }
  const request = parseRouteRequest(payload);
  if (!request) {
    return json(400, { error: 'from and to must each be { lat, lng } within range' });
  }

  const route = await getRoute(request.from, request.to, deps);
  if (!route) {
    // 503, not 500: nothing is broken here, both engines are simply not
    // answering right now, and the caller should retry rather than log a fault.
    return json(503, { error: 'no routing engine could answer right now' });
  }
  return json(200, route);
}
