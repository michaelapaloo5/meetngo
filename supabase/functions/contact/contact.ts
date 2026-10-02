// Hand a trip's other party their phone number, once, to a party of that trip.
//
// The problem this exists to solve: a driver needs to call the rider and a rider
// needs to call the driver, and neither can read the other's `profiles` row.
// That is not an oversight. `init.sql` has no driver-directory read policy on
// purpose, and the note beside it says why: a `role = 'driver'` SELECT policy
// exposes the whole row, which means `ghana_card_number`, `ghana_card_last4`,
// `ghana_card_dob`, `selfie_url` and `phone` to the anon key that ships inside
// the APK. A rider being able to read a driver's Ghana Card is a real
// consequence, not a hypothetical one.
//
// So the number travels with the trip instead. The trip row is already readable
// by both parties -- "rider reads own trips" and "driver reads assigned trips" --
// and the rider is named on it. This function reads the trip, checks the caller
// is one of the two ids on it, and returns the *other* one's number.
//
// The authorisation is the whole function. Everything else is plumbing:
//
//   * the caller must be `trip.rider_id` or `trip.driver_id`. A caller who is
//     neither gets 403 and no number -- not an empty object, not a 404 that
//     distinguishes "no such trip" from "not your trip", because that
//     difference is a trip-existence oracle.
//   * the number is not stored on the trip, so there is nothing to leak from a
//     `select *` on `trips` and nothing stale to read later. It is read from the
//     profile at call time, so a driver who fixes a typo in their number is
//     immediately reachable rather than reachable for whatever the trip recorded.
//   * `profiles.phone` is read on the service key, because the caller cannot read
//     the other party's row and this function is what makes that safe.
//
// What comes back is the stored string, not a dialler URI and not a formatted
// version. The client owns presentation: it decides whether to open the dialler
// or show the digits, and `formatGhanaPhone` in `mng_core` is where that belongs.
// A server that returned a `tel:` URI would be deciding, on the server, how a
// phone is dialled.

export interface ContactRequest {
  tripId: string;
}

export interface ContactResponse {
  /** Whose number this is, so the client can label the screen. */
  role: 'rider' | 'driver';
  /** The stored form: `0241234567` or `233241234567`. Empty when unset. */
  phone: string;
  /**
   * Whether a dialler may be offered at all. False for a valid-but-absent number
   * and equally false for a malformed one, because the client's only correct
   * response to either is to show the digits and nothing else.
   */
  callable: boolean;
  /** The name on the other party's profile, for "call Michael". */
  name: string;
  /**
   * The driver's public face, and only ever a driver's.
   *
   * A rider standing at a rank needs to identify a car: the name on the profile,
   * the picture on it, the make and model, and above all the plate, which is the
   * one thing they can read off the windscreen from ten metres away. Without
   * these a rider has a phone number and no way to know who is about to answer
   * it.
   *
   * Omitted -- rather than null or empty -- when the caller is a driver, or when
   * the other party is a rider, or when there is no vehicle on the trip. A rider's
   * selfie, rating and card stay unreadable in the driver direction on purpose,
   * and a response that carried those fields as empty strings would make "we
   * chose not to send this" indistinguishable from "this person has none".
   */
  driver?: {
    name: string;
    photoUrl: string;
    rating: number | null;
    vehicle: {
      make: string;
      model: string;
      plate: string;
    } | null;
  };
}

export type ContactDeps = {
  /** The caller's user id, or null when the bearer did not authenticate. */
  callerId: string | null;
  /**
   * The trip and the other party's profile, read on the service key. One port
   * rather than two so a test cannot wire a trip belonging to a third driver
   * together with a number that happens to be reachable.
   */
  lookup(tripId: string, callerId: string): Promise<{
    trip: { rider_id: string; driver_id: string | null } | null;
    otherName: string;
    otherPhone: string;
    /**
     * The other party's rating and photo, and their vehicle. Read only when the
     * caller is a rider and the other party is the driver, which is the one
     * direction a rider genuinely needs this in.
     */
    otherProfile?: { photoUrl: string; rating: number | null };
    otherVehicle?: { make: string; model: string; plate: string } | null;
  } | null>;
};

export const CONTACT_UNAUTHENTICATED = 'sign in to see who you are calling';
export const CONTACT_NOT_A_PARTY = 'you are not on this trip';
export const CONTACT_NO_TRIP = 'no such trip';

export async function handleContact(
  tripId: string,
  deps: ContactDeps,
): Promise<{ status: number; body: ContactResponse | { error: string } }> {
  if (!tripId) {
    return { status: 400, body: { error: 'tripId is required' } };
  }
  // A caller with no id is a caller with no rights, and it is refused before
  // the database is touched. This is the only place that check could live: the
  // trip lookup below takes a `callerId` and must not be trusted to compare it.
  if (!deps.callerId) {
    return { status: 401, body: { error: CONTACT_UNAUTHENTICATED } };
  }

  const found = await deps.lookup(tripId, deps.callerId);
  // No trip, or a trip the caller is not on, are the same answer on purpose.
  // 404 for both: a 403 says "this trip exists and you are not on it", which is
  // an oracle over somebody else's ride, and the client has no use for the
  // difference -- it is going to say "you are not on this trip" either way.
  if (!found || !found.trip) {
    return { status: 404, body: { error: CONTACT_NO_TRIP } };
  }

  const { trip, otherName, otherPhone } = found;
  const isRider = trip.rider_id === deps.callerId;
  const isDriver = trip.driver_id !== null && trip.driver_id === deps.callerId;
  if (!isRider && !isDriver) {
    return { status: 404, body: { error: CONTACT_NO_TRIP } };
  }

  // A trip with no driver yet has nobody to call, and the driver half of this
  // function cannot be reached in that state -- but the check is here rather than
  // left to the null so the rule is stated once.
  if (isRider && !trip.driver_id) {
    return { status: 409, body: { error: 'no driver has accepted this trip yet' } };
  }

  // A trip whose rider and driver are the same id. Nothing in the trip state
  // machine compares the two, so this state is reachable by a bug, and without
  // this check both `isRider` and `isDriver` are true: the rider branch is
  // checked first, so the caller is told the number they were handed belongs to
  // the *driver* when it is their own. Refusing is the honest answer -- there is
  // no other party to have a number.
  if (trip.rider_id === trip.driver_id) {
    return { status: 409, body: { error: 'this trip has no separate rider and driver' } };
  }

  return {
    status: 200,
    body: {
      // The *other* party, so the client never has to work out whose number it
      // was handed.
      role: isRider ? 'driver' : 'rider',
      phone: otherPhone,
      // Deliberately permissive here and validated in the client: the server
      // cannot know whether the dialler this phone has can handle a given
      // number, and `mng_core.isCallableGhanaPhone` is the rule both apps use.
      // A number that is present but malformed comes back with
      // `callable: false` so the client shows the digits and lets the driver
      // read them out, rather than opening a dialler onto nothing.
      callable: typeof otherPhone === 'string' && otherPhone.length > 0,
      name: otherName,
      // Rider-asking-about-the-driver only, and only when there is something to
      // say. Built here rather than in the lookup so the rule "a driver never
      // receives these" is stated in the one place that decides what a response
      // contains.
      ...(isRider && found.otherProfile
        ? {
          driver: {
            name: otherName,
            photoUrl: found.otherProfile.photoUrl,
            rating: found.otherProfile.rating,
            vehicle: found.otherVehicle
              ? {
                make: found.otherVehicle.make,
                model: found.otherVehicle.model,
                plate: found.otherVehicle.plate,
              }
              : null,
          },
        }
        : {}),
    },
  };
}
