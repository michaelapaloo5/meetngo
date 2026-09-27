import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';
import { corsHeaders } from '../_shared/cors.ts';
import {
  computeFare,
  promoDiscountGhs,
  RIDE_CATEGORY_NAMES,
  type RideCategoryName,
} from './fare.ts';
import { MAX_OFFERS, pickDrivers } from './match.ts';

const OFFER_TTL_SECONDS = 20;

interface Pin {
  label: string;
  address: string;
  lat: number;
  lng: number;
}

const json = (status: number, payload: Record<string, unknown>) =>
  new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

// A number, not a string that happens to parse, and not a boolean or a
// one-element array, all of which `Number()` would happily accept. Postgres
// `numeric` stores NaN, so a non-finite value here does not fail on the way in:
// it lands in `fare_ghs` and `surge` and is inherited by Task 11's settlement
// and Task 15's payout. Measured on PostgreSQL 17.11: `select
// 'NaN'::numeric(10,2)` succeeds, `sum()` over such a row is NaN, and
// `fare_ghs >= 0` counts the row as passing, so nothing downstream catches it
// either. The only place it can be refused is here, before the insert.
const isFiniteNumber = (value: unknown): value is number =>
  typeof value === 'number' && Number.isFinite(value);

// Validated, and narrowed on the way in rather than on the way to the database.
const readPin = (value: unknown): Pin | null => {
  if (!isRecord(value)) return null;
  if (!isFiniteNumber(value.lat) || !isFiniteNumber(value.lng)) return null;
  return {
    label: typeof value.label === 'string' ? value.label : '',
    address: typeof value.address === 'string' ? value.address : '',
    lat: value.lat,
    lng: value.lng,
  };
};

// The stored jsonb is the shape `TripStop.fromJson` reads, not the shape that
// arrived. The Dart model casts `json['point'] as Map<String, dynamic>` with no
// null case, so a pin stored as `{label, address, lat, lng}` makes the rider's
// own trip unparseable in the rider app. Task 8 sends the flattened
// `{...pickup.toJson(), ...pickup.point.toJson()}`, which carries `point` as
// well and so happens to work today; normalising here means it stops depending
// on the client sending the nested copy. `label` and `address` are coerced to
// strings above for the same reason: `TripStop` casts both.
const stopJson = (pin: Pin) => ({
  label: pin.label,
  address: pin.address,
  point: { lat: pin.lat, lng: pin.lng },
});

const wkt = (p: Pin) => `POINT(${p.lng} ${p.lat})`;

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  // Deliberately a pure service-role client, with no caller's `Authorization`
  // header forwarded onto it. supabase-js only sets `Authorization` when it is
  // absent, so pairing the service key with a forwarded bearer leaves the
  // user's token as the effective credential: PostgREST resolves the role to
  // `authenticated`, RLS applies, and this function then fails in three places
  // at once, because the migration has no INSERT policy on `trips`, no INSERT
  // policy on `offers`, and revokes EXECUTE on `match_offers_for_trip` from
  // `anon` and `authenticated` (42501).
  //
  // Bypassing RLS is what makes the bare service client necessary, and the
  // authorisation it removes is not replaced by the database here, so it is
  // replaced by this function: the caller must present a token that
  // `getUser` validates, and the trip's `rider_id` is that validated identity
  // and never a field of the request body. No other part of the body can decide
  // who the trip belongs to. The distance RPC, the promo read, the trip insert,
  // `match_offers_for_trip` and the offers insert all use this one client,
  // because `match_offers_for_trip` is reachable by `service_role` alone and no
  // role that can be impersonated by a client has an RLS path to the trip or
  // the offer insert.
  const service = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  const header = req.headers.get('Authorization') ?? '';
  const token = header.replace(/^Bearer\s+/i, '');
  if (!token) return json(401, { error: 'unauthenticated' });

  const { data: userData, error: userError } = await service.auth.getUser(token);
  if (userError || !userData.user) return json(401, { error: 'unauthenticated' });
  const riderId = userData.user.id;

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json(400, { error: 'body must be JSON' });
  }
  if (!isRecord(body)) return json(400, { error: 'body must be a JSON object' });

  // Every field the fare depends on is checked before anything is read or
  // written. `PER_KM['deluxe']` is `undefined`, so an unchecked category also
  // makes the fare NaN, and it does so before the `trips_category_check`
  // constraint ever sees the value, which is how an input bug turns into an
  // opaque 500.
  const category = body.category;
  if (typeof category !== 'string' || !RIDE_CATEGORY_NAMES.includes(category as RideCategoryName)) {
    return json(400, { error: `category must be one of ${RIDE_CATEGORY_NAMES.join(', ')}` });
  }
  const rideCategory = category as RideCategoryName;

  const pickup = readPin(body.pickup);
  if (!pickup) return json(400, { error: 'pickup must carry finite numeric lat and lng' });
  const dropoff = readPin(body.dropoff);
  if (!dropoff) return json(400, { error: 'dropoff must carry finite numeric lat and lng' });

  const surge = body.surge ?? 1;
  if (!isFiniteNumber(surge)) return json(400, { error: 'surge must be a finite number' });

  const { data: distanceRow, error: distanceError } = await service.rpc('trip_distance_km', {
    a: wkt(pickup),
    b: wkt(dropoff),
  });
  if (distanceError) return json(500, { error: distanceError.message });
  const distanceKm = Number(distanceRow ?? 0);
  if (!Number.isFinite(distanceKm)) return json(500, { error: 'trip_distance_km was not finite' });

  // Price the ride gross first, then take the promo off that gross. Discounting
  // `percent_off / 100 * distanceKm * 1.8` instead, which is what this used to
  // do, hard-codes the standard per-km rate, so a premium ride is discounted at
  // the standard rate and the base and booking fee are ignored.
  const gross = computeFare({ category: rideCategory, distanceKm, surge, discountGhs: 0 });

  let discountGhs = 0;
  if (body.promoCode) {
    const { data: promo, error: promoError } = await service
      .from('promos')
      .select('percent_off,max_discount_ghs,expires_at')
      .eq('code', String(body.promoCode).toUpperCase())
      .eq('active', true)
      .maybeSingle();
    // A dropped error here would leave discountGhs at 0 and quote the rider
    // full price for a code they supplied, which is a worse outcome than
    // failing: nothing in the response says the promo was not applied.
    if (promoError) return json(500, { error: promoError.message });
    // `expires_at` is filtered here rather than in the query because a
    // PostgREST filter value is a literal, not SQL: `expires_at.gt.now()` is
    // not something the API can evaluate, and its own documentation answers a
    // `now()`-dependent filter with a view or an RPC. The seeded RIDE30 has a
    // null expiry, so nothing is broken today either way.
    const live = promo !== null &&
      (promo.expires_at === null || new Date(promo.expires_at).getTime() > Date.now());
    if (live) {
      const percentOff = Number(promo.percent_off);
      const maxDiscountGhs = Number(promo.max_discount_ghs);
      // `percent_off` and `max_discount_ghs` are `numeric`, so a row written
      // with NaN would pass the `percent_off > 0` check constraint and turn
      // every fare that used the code into NaN. The rows are only writable by
      // a privileged role, so this is a backstop, not an input check.
      if (!isFiniteNumber(percentOff) || !isFiniteNumber(maxDiscountGhs)) {
        return json(500, { error: 'promo row carries non-finite discount data' });
      }
      discountGhs = promoDiscountGhs(gross.fareGhs, percentOff, maxDiscountGhs);
    }
  }

  const quote = computeFare({ category: rideCategory, distanceKm, surge, discountGhs });

  const { data: trip, error: tripError } = await service
    .from('trips')
    .insert({
      rider_id: riderId,
      category: rideCategory,
      state: 'requested',
      pickup: stopJson(pickup),
      dropoff: stopJson(dropoff),
      pickup_point: wkt(pickup),
      dropoff_point: wkt(dropoff),
      distance_km: distanceKm,
      surge: quote.surge,
      fare_ghs: quote.fareGhs,
      is_demo: true,
    })
    .select()
    .single();
  if (tripError) return json(500, { error: tripError.message });

  // Service-role only: the migration revokes EXECUTE on this function from
  // `public`, `anon` and `authenticated`, so a user client returns 42501 here
  // and a Flutter app cannot call it at all. The error is checked rather than
  // dropped, because a dropped one turns a failed match into an empty offer
  // list that looks identical to "no drivers are online right now". If the
  // candidates are empty on a live project, check the key before anything else.
  const { data: candidates, error: matchError } = await service.rpc('match_offers_for_trip', {
    target_trip: trip.id,
  });
  if (matchError) return json(500, { error: matchError.message });

  const rows = (candidates ?? []) as { driver_id: string; pickup_distance_km: number }[];
  const driverIds = pickDrivers(
    rows.map((r) => ({ id: r.driver_id, pickupDistanceKm: Number(r.pickup_distance_km) })),
    MAX_OFFERS,
  );
  const distanceById = new Map(
    rows.map((r) => [r.driver_id, Number(r.pickup_distance_km)] as const),
  );

  if (driverIds.length > 0) {
    const expiresAt = new Date(Date.now() + OFFER_TTL_SECONDS * 1000).toISOString();
    const { error: offerError } = await service.from('offers').insert(
      driverIds.map((driverId) => ({
        trip_id: trip.id,
        driver_id: driverId,
        fare_ghs: quote.fareGhs,
        pickup_distance_km: distanceById.get(driverId) ?? 0,
        state: 'pending',
        expires_at: expiresAt,
      })),
    );
    // Checked, and this is the check the brief left out: reporting
    // `offerDriverIds` for offers that were never written tells the rider the
    // fan-out happened while no driver was ever told about the trip.
    if (offerError) return json(500, { error: offerError.message });
  }

  return json(200, { trip, quote, offerDriverIds: driverIds });
});
