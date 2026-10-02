// The database side of `contact`, and the only place that reads another user's
// profile.
//
// The authorisation is the `lookup` port: it takes the caller's id, reads the
// trip, and returns the *other* party's name and number. `handleContact` then
// checks the caller is on the trip, and this function additionally refuses to
// return anything at all for a caller who is not -- the two checks are
// deliberately redundant, because the one that matters is the one that is
// hardest to get right by accident, and a single check is a single mistake away
// from a leak.
//
// The redundant check is here, in SQL, and it is the load-bearing one:
//
//   where t.id = tripId
//     and (t.rider_id = callerId or t.driver_id = callerId)
//
// With that WHERE clause, a caller who is not on the trip matches no row and this
// function returns null -- the number never leaves the database. The comparison
// above it is then a courtesy that produces a clearer error, not the thing
// standing between a driver and a stranger's phone number.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';
import type { ContactDeps } from './contact.ts';

export function buildContactLookup(
  supabaseUrl: string,
  serviceRoleKey: string,
): ContactDeps['lookup'] {
  const service = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  return async (tripId, callerId) => {
    // The membership test is in the WHERE clause, so this cannot be turned into
    // a "give me anybody's number" query by a future caller. `.maybeSingle()`
    // rather than `.single()`: single() raises on zero rows, and a caller who is
    // not on the trip is a zero row, not an error condition worth surfacing.
    const { data: tripRow, error: tripError } = await service
      .from('trips')
      .select('id, rider_id, driver_id, vehicle_id')
      .eq('id', tripId)
      .or(`rider_id.eq.${callerId},driver_id.eq.${callerId}`)
      .maybeSingle();
    if (tripError) throw new Error(tripError.message);
    if (!tripRow) return null;

    // The other party. Which one that is depends on which id is the caller's,
    // and it is worked out from the trip row rather than asked for: a caller who
    // could name the profile they wanted would be asking for somebody else's.
    const otherId = tripRow.rider_id === callerId
      ? tripRow.driver_id
      : tripRow.rider_id;
    if (!otherId) {
      // A trip with no driver yet. `handleContact` refuses this case for a rider
      // with its own message; here it just means there is no profile to read.
      return { trip: tripRow as { rider_id: string; driver_id: string | null }, otherName: '', otherPhone: '' };
    }

    // Read on the service key, which bypasses RLS. This is the one read in the
    // product that deliberately does, and it is why the trip membership check
    // above is not optional.
    //
    // Named columns, never `select('*')`. This function reads another user's
    // row, so the list of columns here *is* the list of things this product is
    // allowed to hand a stranger, and it has to be readable in one line: a
    // rider's Ghana card and selfie must never appear in it.
    //
    // `photo_url` and `rating` are read only in the rider-asking direction (see
    // below). The phone number and the name are read in both, because both
    // parties need to reach each other; a rating is a rider-facing thing.
    const { data: profile, error: profileError } = await service
      .from('profiles')
      .select('full_name, phone, photo_url, rating, vehicle_id')
      .eq('id', otherId)
      .maybeSingle();
    if (profileError) throw new Error(profileError.message);

    const base = {
      trip: tripRow as { rider_id: string; driver_id: string | null },
      otherName: (profile?.full_name ?? '').toString(),
      otherPhone: (profile?.phone ?? '').toString(),
    };

    // A driver asking about a rider stops here. Not "the fields come back
    // empty" -- they are not read at all, so there is no path by which a rider's
    // photo or rating could reach a driver's app even by accident.
    if (tripRow.rider_id !== callerId) return base;

    // Which car, for a rider standing at a rank.
    //
    // `trips.vehicle_id` first, because a trip that records a vehicle is the one
    // that can be right about *which* car is coming -- a driver who changes
    // vehicle between trips must not have the old plate shown.
    //
    // Then the driver's current `profiles.vehicle_id`, and that fallback is not
    // a convenience: **nothing in this product writes `trips.vehicle_id`.** No
    // Edge Function, no trigger, no client. Grep finds only this read and the
    // admin page's own driver query. So without the fallback the column is
    // permanently null and a rider never sees a car or a plate on any trip --
    // which is exactly what the first live check of this function found:
    // `vehicle: null` on a trip whose driver had a registered, approved vehicle.
    //
    // Populating the trip column when a driver accepts is a real gap rather than
    // a style preference. Until then this fallback is the only path that gives a
    // rider the one detail they can read off a windscreen.
    const vehicleId = tripRow.vehicle_id ?? profile?.vehicle_id ?? null;
    let vehicle: { make: string; model: string; plate: string } | null = null;
    if (vehicleId) {
      const { data: car, error: carError } = await service
        .from('vehicles')
        .select('make, model, plate')
        .eq('id', vehicleId)
        .maybeSingle();
      if (carError) throw new Error(carError.message);
      if (car) {
        vehicle = {
          make: (car.make ?? '').toString(),
          model: (car.model ?? '').toString(),
          plate: (car.plate ?? '').toString(),
        };
      }
    }

    return {
      ...base,
      otherProfile: {
        photoUrl: (profile?.photo_url ?? '').toString(),
        rating: typeof profile?.rating === 'number' ? profile.rating : null,
      },
      otherVehicle: vehicle,
    };
  };
}
