import { assert, assertEquals } from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import { parseRideRequest, type Pin } from '../request-ride/request.ts';

const pin = (over: Partial<Pin> = {}): Pin => ({
  label: 'Pickup',
  address: 'Osu, Accra',
  lat: 5.6037,
  lng: -0.187,
  ...over,
});

const body = (over: Record<string, unknown> = {}) => ({
  category: 'standard',
  pickup: pin(),
  dropoff: pin({ label: 'Dropoff', address: 'Airport Residential', lat: 5.62 }),
  ...over,
});

const refuse = (raw: unknown): string => {
  const result = parseRideRequest(raw);
  assert(!result.ok, `expected a refusal, got ${JSON.stringify(result)}`);
  return result.error;
};

Deno.test('a valid request yields the category, both pins and the surge', () => {
  const result = parseRideRequest(body());
  assert(result.ok, JSON.stringify(result));
  assertEquals(result.value.category, 'standard');
  assertEquals(result.value.pickup.lat, 5.6037);
  assertEquals(result.value.dropoff.lat, 5.62);
  assertEquals(result.value.surge, 1);
  assertEquals(result.value.promoCode, null);
});

Deno.test('a promo code is uppercased and anything that is not one is dropped', () => {
  const upper = parseRideRequest(body({ promoCode: 'ride30' }));
  assert(upper.ok, JSON.stringify(upper));
  assertEquals(upper.value.promoCode, 'RIDE30');
  const empty = parseRideRequest(body({ promoCode: '' }));
  assert(empty.ok, JSON.stringify(empty));
  assertEquals(empty.value.promoCode, null);
  const numeric = parseRideRequest(body({ promoCode: 30 }));
  assert(numeric.ok, JSON.stringify(numeric));
  assertEquals(numeric.value.promoCode, null);
});

Deno.test('an absent surge defaults to 1 and label and address are coerced to strings', () => {
  const result = parseRideRequest(
    body({ pickup: pin({ label: 7 as unknown as string, address: null as unknown as string }) }),
  );
  assert(result.ok, JSON.stringify(result));
  assertEquals(result.value.surge, 1);
  assertEquals(result.value.pickup.label, '');
  assertEquals(result.value.pickup.address, '');
});

Deno.test('a body that is not a JSON object is refused', () => {
  assertEquals(refuse([]), 'body must be a JSON object');
  assertEquals(refuse(5), 'body must be a JSON object');
  assertEquals(refuse(null), 'body must be a JSON object');
});

Deno.test('a category outside the three the schema allows is refused', () => {
  assertEquals(
    refuse(body({ category: 'deluxe' })),
    'category must be one of standard, premium, van',
  );
});

// PostGIS coerces an out-of-range coordinate instead of rejecting it, so
// `lat: 999` would otherwise become a real point 9618 km away and a quote in
// the thousands. Measured on this host: `select st_astext('POINT(-0.187 999)'
// ::geography)` returns `POINT(-0.187 -81)`. These four pin both bounds of
// both axes; a one-sided check would pass all four.
Deno.test('a lat above 90 is refused', () => {
  assertEquals(refuse(body({ pickup: pin({ lat: 999 }) })), 'pickup lat must be within [-90, 90], got 999');
});

Deno.test('a lat below -90 is refused', () => {
  assertEquals(
    refuse(body({ pickup: pin({ lat: -91 }) })),
    'pickup lat must be within [-90, 90], got -91',
  );
});

Deno.test('an lng above 180 is refused', () => {
  assertEquals(
    refuse(body({ dropoff: pin({ lng: 181 }) })),
    'dropoff lng must be within [-180, 180], got 181',
  );
});

Deno.test('an lng below -180 is refused', () => {
  assertEquals(
    refuse(body({ dropoff: pin({ lng: -180.5 }) })),
    'dropoff lng must be within [-180, 180], got -180.5',
  );
});

Deno.test('the poles and the antimeridian are inside the range', () => {
  const result = parseRideRequest(
    body({ pickup: pin({ lat: 90, lng: 180 }), dropoff: pin({ lat: -90, lng: -180 }) }),
  );
  assert(result.ok, JSON.stringify(result));
  assertEquals(result.value.pickup.lat, 90);
  assertEquals(result.value.pickup.lng, 180);
  assertEquals(result.value.dropoff.lat, -90);
  assertEquals(result.value.dropoff.lng, -180);
});

Deno.test('a pin that is not an object, or whose coordinates are not finite numbers, is refused', () => {
  assertEquals(refuse(body({ pickup: 'Osu' })), 'pickup must be an object');
  assertEquals(
    refuse(body({ pickup: pin({ lat: '5.6037' as unknown as number }) })),
    'pickup must carry finite numeric lat and lng',
  );
  assertEquals(
    refuse(body({ dropoff: pin({ lng: NaN }) })),
    'dropoff must carry finite numeric lat and lng',
  );
  assertEquals(
    refuse(body({ dropoff: pin({ lng: Infinity }) })),
    'dropoff must carry finite numeric lat and lng',
  );
});

Deno.test('a surge that is not a finite number is refused', () => {
  assertEquals(refuse(body({ surge: 'x' })), 'surge must be a finite number');
  assertEquals(refuse(body({ surge: 1e999 })), 'surge must be a finite number');
  assertEquals(refuse(body({ surge: true })), 'surge must be a finite number');
  assertEquals(refuse(body({ surge: NaN })), 'surge must be a finite number');
});
