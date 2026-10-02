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
  /**
   * When this ride should start entering the offer pool, ISO in UTC, or null
   * for an immediate ride.
   *
   * Null is the ordinary case and is not a second code path: the column is
   * nullable, `trips_is_offerable` treats null as "now", and an ordinary booking
   * is written and offered exactly as it was before scheduling existed.
   */
  scheduledFor: string | null;
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

  // A present-but-non-string code is a client bug and is refused like every
  // other wrong-typed field here, rather than dropped: dropping it returns 200
  // at full price to a rider who was promised a discount, with nothing in the
  // response saying the code was discarded. An absent code, `null` and an empty
  // string are all "no code", which is not a discard and needs no signal.
  const promoCode = body.promoCode;
  if (promoCode !== undefined && promoCode !== null && typeof promoCode !== 'string') {
    return refuse('promoCode must be a string');
  }

  // When this ride should start entering the offer pool. Null is "now", which is
  // the ordinary case and takes exactly the path it took before this existed.
  //
  // Validated rather than passed through: an unparseable date would otherwise be
  // stored as null by the driver and quietly turn a scheduled ride into an
  // immediate one, which is the one failure a scheduling feature cannot have.
  const rawScheduled = body.scheduledFor;
  let scheduledFor: string | null = null;
  if (rawScheduled !== undefined && rawScheduled !== null) {
    if (typeof rawScheduled !== 'string') return refuse('scheduledFor must be an ISO timestamp');
    const parsedDate = new Date(rawScheduled);
    if (Number.isNaN(parsedDate.getTime())) return refuse('scheduledFor is not a date');
    // Stored in UTC. Everything else in this function compares timestamps and a
    // local-time string would compare wrongly against `now()`.
    scheduledFor = parsedDate.toISOString();
  }

  return {
    ok: true,
    value: {
      category: category as RideCategoryName,
      pickup: pickup.value,
      dropoff: dropoff.value,
      surge,
      promoCode: promoCode ? promoCode.toUpperCase() : null,
      scheduledFor,
    },
  };
}
