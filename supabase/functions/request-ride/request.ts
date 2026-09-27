import { RIDE_CATEGORY_NAMES, type RideCategoryName } from './fare.ts';

export interface Pin {
  label: string;
  address: string;
  lat: number;
  lng: number;
}

export interface RideRequest {
  category: RideCategoryName;
  pickup: Pin;
  dropoff: Pin;
  surge: number;
  promoCode: string | null;
}

export type RideRequestResult =
  | { ok: true; value: RideRequest }
  | { ok: false; error: string };

type Checked<T> = { ok: true; value: T } | { ok: false; error: string };

const refuse = (error: string): { ok: false; error: string } => ({ ok: false, error });

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

// A number, not a string that happens to parse, and not a boolean or a
// one-element array, all of which `Number()` would happily accept. Postgres
// `numeric` stores NaN, so a non-finite value does not fail on the way in: it
// lands in `fare_ghs` and `surge` and is inherited by Task 11's settlement and
// Task 15's payout. Measured on PostgreSQL 17.11: `'NaN'::numeric(10,2)`
// inserts, `sum()` over such a row is NaN, and `fare_ghs >= 0` counts the row
// as passing, so nothing downstream catches it either. The only place it can be
// refused is here, before the insert.
export const isFiniteNumber = (value: unknown): value is number =>
  typeof value === 'number' && Number.isFinite(value);

// The range check is not optional and is not what the database does for us.
// PostGIS coerces an out-of-range coordinate into range with a NOTICE instead
// of rejecting it: measured on this host, `st_astext('POINT(-0.187 999)'
// ::geography)` is `POINT(-0.187 -81)`, 9618.25 km from the real pickup. A
// `lat: 999` would therefore price as a real ride in the thousands of GHS, so
// silent coordinate wrapping is not validation and the fare is money.
const readPin = (value: unknown, which: 'pickup' | 'dropoff'): Checked<Pin> => {
  if (!isRecord(value)) return refuse(`${which} must be an object`);
  if (!isFiniteNumber(value.lat) || !isFiniteNumber(value.lng)) {
    return refuse(`${which} must carry finite numeric lat and lng`);
  }
  if (value.lat < -90 || value.lat > 90) {
    return refuse(`${which} lat must be within [-90, 90], got ${value.lat}`);
  }
  if (value.lng < -180 || value.lng > 180) {
    return refuse(`${which} lng must be within [-180, 180], got ${value.lng}`);
  }
  return {
    ok: true,
    value: {
      label: typeof value.label === 'string' ? value.label : '',
      address: typeof value.address === 'string' ? value.address : '',
      lat: value.lat,
      lng: value.lng,
    },
  };
};

// Everything the fare depends on, checked before the function reads or writes
// anything. `PER_KM['deluxe']` is `undefined`, so an unchecked category also
// makes the fare NaN, and it does so before the `trips_category_check`
// constraint ever sees the value, which is how an input bug becomes an opaque
// 500. `label` and `address` are coerced to strings because `TripStop` casts
// both when the stored trip is read back.
export function parseRideRequest(body: unknown): RideRequestResult {
  if (!isRecord(body)) return refuse('body must be a JSON object');

  const category = body.category;
  if (typeof category !== 'string' || !RIDE_CATEGORY_NAMES.includes(category as RideCategoryName)) {
    return refuse(`category must be one of ${RIDE_CATEGORY_NAMES.join(', ')}`);
  }

  const pickup = readPin(body.pickup, 'pickup');
  if (!pickup.ok) return pickup;
  const dropoff = readPin(body.dropoff, 'dropoff');
  if (!dropoff.ok) return dropoff;

  const surge = body.surge ?? 1;
  if (!isFiniteNumber(surge)) return refuse('surge must be a finite number');

  // Only a non-empty string is a code. The plan's clients send `String?`, and
  // stringifying anything else here would turn a client bug into a lookup for a
  // code nobody typed.
  const promoCode = typeof body.promoCode === 'string' && body.promoCode !== ''
    ? body.promoCode.toUpperCase()
    : null;

  return {
    ok: true,
    value: {
      category: category as RideCategoryName,
      pickup: pickup.value,
      dropoff: dropoff.value,
      surge,
      promoCode,
    },
  };
}
