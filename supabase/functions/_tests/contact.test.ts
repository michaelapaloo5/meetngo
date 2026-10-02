import { assert, assertEquals } from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import {
  CONTACT_NOT_A_PARTY,
  CONTACT_NO_TRIP,
  CONTACT_UNAUTHENTICATED,
  handleContact,
  type ContactDeps,
} from '../contact/contact.ts';

// What `buildContactLookup` would find for a trip the caller IS on.
//
// `otherProfile` and `otherVehicle` are absent by default, which is the
// driver-asking case: `buildContactLookup` returns early in that direction, so
// the fields never come back and the response carries no `driver` object at all.
function lookupFor(tripId: string, callerId: string, other: { name?: string; phone?: string } = {}) {
  return async (askedTripId: string, askedCaller: string) => {
    assertEquals(askedTripId, tripId);
    assertEquals(askedCaller, callerId);
    return {
      trip: { rider_id: 'rider-1', driver_id: 'driver-1' },
      otherName: other.name ?? 'Michael Apaloo',
      otherPhone: other.phone ?? '0241234567',
    };
  };
}

/// A rider asking about the driver: the lookup returns the extra fields.
function riderLookup(
  over: {
    name?: string;
    phone?: string;
    photoUrl?: string;
    rating?: number | null;
    vehicle?: { make: string; model: string; plate: string } | null;
  } = {},
) {
  return async () => ({
    trip: { rider_id: 'rider-1', driver_id: 'driver-1' },
    otherName: over.name ?? 'Michael Apaloo',
    otherPhone: over.phone ?? '0241234567',
    otherProfile: { photoUrl: over.photoUrl ?? '', rating: over.rating ?? null },
    otherVehicle: over.vehicle === undefined
      ? { make: 'Toyota', model: 'Corolla', plate: 'GR-1234-22' }
      : over.vehicle,
  });
}

const deps = (over: Partial<ContactDeps> = {}): ContactDeps => ({
  callerId: 'driver-1',
  lookup: lookupFor('t1', 'driver-1'),
  ...over,
});

Deno.test('a driver gets the rider\'s number', async () => {
  const r = await handleContact('t1', deps());
  assertEquals(r.status, 200);
  assertEquals((r.body as { role: string }).role, 'rider');
  assertEquals((r.body as { phone: string }).phone, '0241234567');
});

Deno.test('a rider gets the driver\'s number', async () => {
  // The function is symmetric and that is the point: neither party can read the
  // other\'s profile, so both directions need it.
  const r = await handleContact('t1', deps({
    callerId: 'rider-1',
    lookup: async () => ({
      trip: { rider_id: 'rider-1', driver_id: 'driver-1' },
      otherName: 'Ama Boateng',
      otherPhone: '0559988776',
    }),
  }));
  assertEquals(r.status, 200);
  assertEquals((r.body as { role: string }).role, 'driver');
  assertEquals((r.body as { phone: string }).phone, '0559988776');
});

Deno.test('a rider gets the driver\'s car and photo, not just a number', async () => {
  // The thing a rider standing at a rank actually needs: a name, a face, and a
  // plate they can read off a windscreen. Before this, the rider direction
  // answered with a phone number alone, so the tracking screen had nothing to
  // draw and the driver card never rendered.
  const r = await handleContact('t1', deps({
    callerId: 'rider-1',
    lookup: riderLookup({
      name: 'Michael Apaloo',
      photoUrl: 'https://example.test/michael.jpg',
      rating: 4.8,
    }),
  }));
  assertEquals(r.status, 200);
  const driver = (r.body as { driver: Record<string, unknown> }).driver;
  assertEquals(driver.name, 'Michael Apaloo');
  assertEquals(driver.photoUrl, 'https://example.test/michael.jpg');
  assertEquals(driver.rating, 4.8);
  assertEquals(
    (driver.vehicle as Record<string, string>).plate,
    'GR-1234-22',
  );
});

Deno.test('a driver never receives the rider\'s photo or rating', async () => {
  // Asymmetric on purpose. A rider needs to identify their driver; a driver does
  // not need the rider's photograph, and a response that carried those fields as
  // empty strings would make "we chose not to send this" indistinguishable from
  // "this person has none". Absent, not empty.
  const r = await handleContact('t1', deps({
    callerId: 'driver-1',
    lookup: async () => ({
      trip: { rider_id: 'rider-1', driver_id: 'driver-1' },
      otherName: 'Ama Boateng',
      otherPhone: '0559988776',
      otherProfile: { photoUrl: 'https://example.test/ama.jpg', rating: 5 },
      otherVehicle: { make: 'Toyota', model: 'Corolla', plate: 'GR-9999-22' },
    }),
  }));
  assertEquals(r.status, 200);
  assertEquals('driver' in (r.body as object), false);
});

Deno.test('a driver with no vehicle gives the rider a name and nothing else', async () => {
  // No car yet is a real state: `trips.vehicle_id` is null until a driver
  // accepts. The rider's card must still work rather than fail, because there
  // is a driver and a number and those are worth showing.
  const r = await handleContact('t1', deps({
    callerId: 'rider-1',
    lookup: riderLookup({ vehicle: null }),
  }));
  assertEquals(r.status, 200);
  const driver = (r.body as { driver: Record<string, unknown> }).driver;
  assertEquals(driver.name, 'Michael Apaloo');
  assertEquals(driver.vehicle, null);
});

Deno.test('the number is the stored string, not a tel: URI or a formatted one', async () => {
  // Presentation is the client's job. A server that returned `tel:` would be
  // deciding how a phone is dialled, and one that returned `024 123 4567` would
  // be deciding how a number is displayed.
  const r = await handleContact('t1', deps());
  assertEquals((r.body as { phone: string }).phone, '0241234567');
});

// The whole reason this function exists is the refusal below, so it gets the
// most attention: the number must not go to somebody who is not on the trip.

Deno.test('somebody who is not on the trip gets no number', async () => {
  const r = await handleContact('t1', deps({
    callerId: 'a-stranger',
    lookup: async () => ({
      trip: { rider_id: 'rider-1', driver_id: 'driver-1' },
      otherName: 'Michael Apaloo',
      otherPhone: '0241234567',
    }),
  }));
  // 404, not 403. A 403 says "this trip exists and you are not on it", which is
  // an oracle over somebody else\'s ride: a caller could enumerate trip ids and
  // learn which ones are real.
  assertEquals(r.status, 404);
  assertEquals((r.body as { error: string }).error, CONTACT_NO_TRIP);
});

Deno.test('a caller with no id is refused before the database is touched', async () => {
  let called = false;
  const r = await handleContact('t1', deps({
    callerId: null,
    lookup: async () => {
      called = true;
      return null;
    },
  }));
  assertEquals(r.status, 401);
  assertEquals((r.body as { error: string }).error, CONTACT_UNAUTHENTICATED);
  // `reason` is the third positional argument in Deno's assertEquals, not a
  // named one. `reason:` is Dart's syntax and it does not parse here, which is
  // what the first run of this file said.
  assertEquals(called, false, 'the lookup must not run for an unauthenticated caller');
});

Deno.test('a trip that does not exist and a trip you are not on are the same answer', async () => {
  // Otherwise the difference is a trip-existence oracle.
  const missing = await handleContact('nope', deps({ lookup: async () => null }));
  const notMine = await handleContact('t1', deps({ callerId: 'stranger', lookup: async () => null }));
  assertEquals(missing.status, 404);
  assertEquals(notMine.status, 404);
  assertEquals((missing.body as { error: string }).error, (notMine.body as { error: string }).error);
});

Deno.test('a trip with no driver yet tells the rider so', async () => {
  // 409 rather than 404: the trip exists, the rider is on it, and the answer
  // "no driver has accepted yet" is the one they can act on.
  const r = await handleContact('t1', deps({
    callerId: 'rider-1',
    lookup: async () => ({
      trip: { rider_id: 'rider-1', driver_id: null },
      otherName: '',
      otherPhone: '',
    }),
  }));
  assertEquals(r.status, 409);
});

Deno.test('a missing trip id is a 400, not a lookup', async () => {
  let called = false;
  const r = await handleContact('', deps({
    lookup: async () => {
      called = true;
      return null;
    },
  }));
  assertEquals(r.status, 400);
  assertEquals(called, false);
});

Deno.test('a driver who has not entered a number comes back empty, not blank-looking', async () => {
  // Every driver signed up before the phone field existed has `phone = ''`, and
  // a client that cannot tell "no number" from "a number that failed to load"
  // shows a call button that does nothing.
  const r = await handleContact('t1', deps({ lookup: lookupFor('t1', 'driver-1', { phone: '' }) }));
  assertEquals(r.status, 200);
  assertEquals((r.body as { phone: string }).phone, '');
  assertEquals((r.body as { callable: boolean }).callable, false);
});

Deno.test('a number that is present is reported as callable', async () => {
  // The real validity check is `isCallableGhanaPhone` in `mng_core`, on the
  // client. The server only knows whether there is a string.
  const r = await handleContact('t1', deps());
  assertEquals((r.body as { callable: boolean }).callable, true);
});

Deno.test('the name comes back so the client can say "call Michael"', async () => {
  const r = await handleContact('t1', deps());
  assertEquals((r.body as { name: string }).name, 'Michael Apaloo');
});

Deno.test('a trip whose rider and driver are the same id does not crash', async () => {
  // If `rider_id` and `driver_id` were the same id -- which a bug could produce,
  // since nothing in the trip transition guard compares them -- both `isRider`
  // and `isDriver` are true. The rider branch is checked first, so `role` comes
  // back as `driver`, meaning the caller is told the number is the driver's when
  // it is their own.
  //
  // That is wrong, and it is a state the schema permits, so it is asserted
  // rather than left: a self-trip returns 409 and no number, because there is no
  // "other party" to hand one to. The earlier version of this test asserted the
  // wrong label and passed, which is why the comment above now says what the code
  // does instead of what it should do.
  const r = await handleContact('t1', deps({
    callerId: 'same-person',
    lookup: async () => ({
      trip: { rider_id: 'same-person', driver_id: 'same-person' },
      otherName: 'Somebody',
      otherPhone: '0241234567',
    }),
  }));
  assertEquals(r.status, 409);
  assert(!('phone' in (r.body as Record<string, unknown>)),
    'a self-trip must not hand anybody a phone number');
});
