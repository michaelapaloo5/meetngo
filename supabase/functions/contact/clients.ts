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
      .select('id, rider_id, driver_id')
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
    // `full_name` and `phone` only. Not the card fields, not the selfie, not the
    // rating: this function's job is a phone number, and a function that reads
    // more than it needs is a function whose future reader cannot tell what it
    // is allowed to see.
    const { data: profile, error: profileError } = await service
      .from('profiles')
      .select('full_name, phone')
      .eq('id', otherId)
      .maybeSingle();
    if (profileError) throw new Error(profileError.message);

    return {
      trip: tripRow as { rider_id: string; driver_id: string | null },
      otherName: (profile?.full_name ?? '').toString(),
      otherPhone: (profile?.phone ?? '').toString(),
    };
  };
}
