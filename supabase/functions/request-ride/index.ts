import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';
import { corsHeaders } from '../_shared/cors.ts';
import { deleteTripAndFail } from './compensate.ts';
import { computeFare, promoDiscountGhs } from './fare.ts';
import { MAX_OFFERS, pickDrivers } from './match.ts';
import { isFiniteNumber, parseRideRequest, type Pin } from './request.ts';

const OFFER_TTL_SECONDS = 20;

const json = (status: number, payload: Record<string, unknown>) =>
  new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

// The stored jsonb is the shape `TripStop.fromJson` reads, not the shape that
// arrived. The Dart model casts `json['point'] as Map<String, dynamic>` with no
// null case, so a pin stored as `{label, address, lat, lng}` makes the rider's
// own trip unparseable in the rider app. Task 8 sends the flattened
// `{...pickup.toJson(), ...pickup.point.toJson()}`, which carries `point` as
// well and so happens to work today; normalising here means it stops depending
// on the client sending the nested copy. `label` and `address` are coerced to
// strings in `parseRideRequest` for the same reason: `TripStop` casts both.
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
  // `match_offers_for_trip`, the offers insert and the compensating delete all
  // use this one client, because `match_offers_for_trip` is reachable by
  // `service_role` alone and no role that can be impersonated by a client has an
  // RLS path to the trip or the offer insert.
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
  // Everything the fare depends on — the category, both pins and the surge,
  // including the coordinate range — is checked here, before the first RPC and
  // before the insert.
  const parsed = parseRideRequest(body);
  if (!parsed.ok) return json(400, { error: parsed.error });
  const { category, pickup, dropoff, surge, promoCode } = parsed.value;

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
  const gross = computeFare({ category, distanceKm, surge, discountGhs: 0 });

  let discountGhs = 0;
  if (promoCode) {
    const { data: promo, error: promoError } = await service
      .from('promos')
      .select('percent_off,max_discount_ghs,expires_at')
      .eq('code', promoCode)
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

  const quote = computeFare({ category, distanceKm, surge, discountGhs });

  const { data: trip, error: tripError } = await service
    .from('trips')
    .insert({
      rider_id: riderId,
      category,
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

  // From here on the trip row exists, so every failure below has to take it
  // out again: Task 8's `activeTrip()` selects `requested` trips, so an orphan
  // pins the rider's active trip and blocks every later ride request.
  const deleteTrip = async (tripId: string) => {
    const { error } = await service.from('trips').delete().eq('id', tripId);
    return { error };
  };

  // Service-role only: the migration revokes EXECUTE on this function from
  // `public`, `anon` and `authenticated`, so a user client returns 42501 here
  // and a Flutter app cannot call it at all. The error is checked rather than
  // dropped, because a dropped one turns a failed match into an empty offer
  // list that looks identical to "no drivers are online right now". If the
  // candidates are empty on a live project, check the key before anything else.
  const { data: candidates, error: matchError } = await service.rpc('match_offers_for_trip', {
    target_trip: trip.id,
  });
  if (matchError) {
    return json(500, await deleteTripAndFail(deleteTrip, trip.id, matchError.message));
  }

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
    // fan-out happened while no driver was ever told about the trip. The trip
    // goes with them, since the offers cascade from it.
    if (offerError) {
      return json(500, await deleteTripAndFail(deleteTrip, trip.id, offerError.message));
    }
  }

  return json(200, { trip, quote, offerDriverIds: driverIds });
});
