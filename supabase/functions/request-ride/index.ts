import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';
import { corsHeaders } from '../_shared/cors.ts';
import { compensating } from './compensate.ts';
import { computeFare, promoDiscountGhs } from './fare.ts';
import { MAX_OFFERS, pickDrivers } from './match.ts';
import { pickupOtp } from './otp.ts';
import { isFiniteNumber, parseRideRequest, type Pin } from './request.ts';

// How long an offer stays live.
//
// This was 20 seconds, and it was the single most damaging number in the
// product. A driver has to notice a notification, read a destination they have
// never heard of, decide whether the fare is worth the drive, and tap accept. In
// Accra, with the phone in a pocket and traffic at a standstill, that is not
// twenty seconds -- it is one to three minutes. Every driver slower than the
// timer lost the ride to a faster one, and since the driver who *is* nearby
// always wins the race, the practical effect was that the nearest driver got
// every offer and everyone else got none. A driver's phone is also frequently
// on a slow network; the offer arrives, the screen renders, and the row is
// already past its deadline.
//
// Five minutes. Long enough to read the destination and think about it, short
// enough that a trip nobody wanted does not sit in the offer queue of every
// driver in the city, and long enough that the release that happens on the
// other driver's acceptance (migration `release_sibling_offers`) is what ends
// most offers rather than this clock.
//
// What expiry is still FOR, and this is the reason it is not infinite: a driver
// who is offered a trip and looks away for six minutes should not come back to
// a pickup that is no longer happening. The trip's own state is the real
// authority -- `accept_offer` refuses an offer whose trip is no longer
// awaiting a driver -- so a long TTL cannot produce a double booking. It only
// decides how long a stale card sits on a phone.
const OFFER_TTL_SECONDS = 300;

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
  const { category, pickup, dropoff, surge, promoCode, scheduledFor } = parsed.value;

  const { data: distanceRow, error: distanceError } = await service.rpc('trip_distance_km', {
    a: wkt(pickup),
    b: wkt(dropoff),
  });
  if (distanceError) return json(500, { error: distanceError.message });
  // A null result is not a zero-kilometre ride. The RPC cannot return null
  // today, so `?? 0` here would only be dead code that hides a future break as
  // a base-fare quote: a 6.00 GHS ride on a route nobody priced.
  if (distanceRow === null || distanceRow === undefined) {
    return json(500, { error: 'trip_distance_km returned no distance' });
  }
  const distanceKm = Number(distanceRow);
  if (!Number.isFinite(distanceKm)) return json(500, { error: 'trip_distance_km was not finite' });

  // Price the ride gross first, then take the promo off that gross. Discounting
  // `percent_off / 100 * distanceKm * 1.8` instead, which is what this used to
  // do, hard-codes the standard per-km rate, so a premium ride is discounted at
  // the standard rate and the base and booking fee are ignored.
  const gross = computeFare({ category, distanceKm, surge, discountGhs: 0 });

  let discountGhs = 0;
  if (promoCode) {
    const { data: promoRows, error: promoError } = await service
      .from('promos')
      .select('percent_off,max_discount_ghs,expires_at')
      .eq('code', promoCode)
      .eq('active', true)
      .limit(1);
    // A dropped error here would leave discountGhs at 0 and quote the rider
    // full price for a code they supplied, which is a worse outcome than
    // failing: nothing in the response says the promo was not applied.
    if (promoError) return json(500, { error: promoError.message });
    // `promoRows?.[0]` rather than `maybeSingle()`, and not for the reason this
    // comment used to give. Measured with the shipped client and a stub fetch:
    // on a GET, `maybeSingle()` sends `Accept: application/json`, not
    // `application/vnd.pgrst.object+json`
    // (`@supabase/postgrest-js@1.16.1/src/PostgrestTransformBuilder.ts:209-210`,
    // the version supabase-js 2.45.4 resolves), so a 0-row read is a 200 with
    // `[]` and the client turns it into `data = null` itself
    // (`@supabase/postgrest-js@1.16.1/src/PostgrestBuilder.ts:118-134`). The
    // `details.includes('0 rows')` comparison at `:162` is on the error branch,
    // which a GET does not take. So a typo'd promo code reads as `null` here and
    // is not a 500. `limit(1)` is used because it never asks the client to
    // interpret a row count at all, so the shape of a 0-row read does not rest
    // on a client-side coercion step in someone else's API, and because every
    // read in this function is then the same shape.
    const promo = promoRows?.[0] ?? null;
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
      // This is a backstop on `max_discount_ghs`, and only that column.
      // `promos.percent_off` carries `check (percent_off > 0 and percent_off
      // <= 100)`, and because that is a conjunction it does reject NaN: on this
      // host `'NaN'::numeric > 0` is true but `'NaN'::numeric <= 100` is false,
      // so an insert of a NaN percent is refused (measured). `max_discount_ghs`
      // has no CHECK at all, and PostgREST serialises a numeric NaN as the JSON
      // string `"NaN"`, so `Number("NaN")` is NaN and that is the one column
      // that can arrive non-finite. `promoDiscountGhs` does not clamp a
      // non-finite argument, deliberately: `Math.max(0, NaN)` is NaN, and
      // turning a corrupt row into a silent no-discount is the failure this
      // check exists to prevent.
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
      // Minted here, at booking, and not when the driver sets off.
      //
      // This line was missing. `pickupOtp` was imported and never called, so
      // every trip was booked with `pickup_otp = null` -- and
      // `SupabaseDriverRepository.verifyPickupOtp` refuses a null expected
      // value, so *every* code a driver typed was rejected with "That code is
      // not right" while the rider's own screen read "Not available". No ride
      // could be started at all.
      //
      // Minted at booking rather than on arrival because the rider has to read
      // it out to the driver from their phone. A code generated after the driver
      // has arrived is a code the rider cannot possibly know.
      pickup_otp: pickupOtp(),
      is_demo: true,
      // Null for an ordinary booking, which is then offerable immediately
      // exactly as before. A future value stores the moment, and the trip
      // sits in the requested state doing nothing until it arrives.
      scheduled_for: scheduledFor,
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

  // The whole post-insert region runs inside `compensating`, so an *unchecked*
  // failure takes the same compensating delete as a checked one. That route is
  // the one that needed guarding: it used to escape to `serve`'s default
  // onError, which returns a bare 500 and leaves the trip row behind, which is
  // the same orphan the delete exists to prevent.
  const outcome = await compensating(deleteTrip, trip.id, async () => {
    // Service-role only: the migration revokes EXECUTE on this function from
    // `public`, `anon` and `authenticated`, so a user client returns 42501 here
    // and a Flutter app cannot call it at all. The error is checked rather than
    // dropped, because a dropped one turns a failed match into an empty offer
    // list that looks identical to "no drivers are online right now". If the
    // candidates are empty on a live project, check the key before anything else.
    const { data: candidates, error: matchError } = await service.rpc('match_offers_for_trip', {
      target_trip: trip.id,
    });
    if (matchError) throw new Error(matchError.message);

    const rows = (candidates ?? []) as { driver_id: string; pickup_distance_km: number }[];
    const driverIds = pickDrivers(
      rows.map((r) => ({ id: r.driver_id, pickupDistanceKm: Number(r.pickup_distance_km) })),
      MAX_OFFERS,
    );
    const distanceById = new Map(
      rows.map((r) => [r.driver_id, Number(r.pickup_distance_km)] as const),
    );

    // Whether this ride is waiting for its time.
  //
  // A scheduled ride is offered to nobody yet, and this is the only place offers
  // are created -- so this one flag is the whole of the mechanic. Without it a
  // trip booked for eight o'clock is put to every nearby driver the moment it is
  // booked, which is precisely what "schedule this for eight o'clock" is not.
  //
  // `trip.state` stays `requested` throughout, so the rider's app already knows a
  // trip exists and can already cancel it, and the trip is returned to the rider
  // as normal: the ride *is* booked.
  const isScheduled =
    scheduledFor !== null && new Date(scheduledFor).getTime() > Date.now();

    if (driverIds.length > 0 && !isScheduled) {
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
      if (offerError) throw new Error(offerError.message);
    }

    return driverIds;
  });

  if (!outcome.ok) {
    return json(500, { error: outcome.error, cleanupError: outcome.cleanupError });
  }

  return json(200, { trip, quote, offerDriverIds: outcome.value });
});
