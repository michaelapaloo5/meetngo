// Puts a live `arriving` trip in front of a throwaway driver on the handset, so
// the four screens that only exist during a trip can actually be opened.
//
//   node toolchain/make-device-trip.mjs            # create, prints the sign-in
//   node toolchain/make-device-trip.mjs --teardown # remove
//
// Why this exists: leave-trip, chat, report-a-left-item and navigation all live on
// `ActiveTripScreen`, and there was no way to reach any of them without a rider who
// wanted a ride in Accra at the time. `verify-leave-trip.mjs` proves the function
// against the database; it cannot prove the sheet, the banner or the voice.
//
// It makes its own driver rather than signing in as a real one. Resetting somebody's
// password to get onto their handset is not a thing to do to someone's account
// without asking, and nothing about these four features depends on whose account
// they are. The driver is built to clear every gate on the way in -- phone, KYC,
// vehicle, location -- because a driver stopped at the phone gate is a driver
// standing on the login screen wondering why.
//
// Writes real rows to the real project. Every row is tagged `device-check` and
// `--teardown` removes exactly those, by marker, not by remembered ids.

import { readEnvOrFail } from './read-env.mjs';

const admin = readEnvOrFail('toolchain/supabase-admin.env', [
  'SUPABASE_PROJECT_REF',
  'SUPABASE_ADMIN_TOKEN',
]);
const build = readEnvOrFail('toolchain/apk-build.env', ['SB_URL', 'SB_ANON_KEY']);
const ANON = build.SB_ANON_KEY;
const url = build.SB_URL.replace(/\/+$/, '');
const teardown = process.argv.includes('--teardown');
const MARK = 'device-check';
const PASSWORD = 'DeviceCheck-123!';
const PHONE = '0200000001';

// The rider gets a number too. `profiles.phone` is NOT NULL, so a rider made by
// this script without one has `phone = ''`, the `contact` function answers with an
// empty phone and `callable: false`, and the driver's Call button is greyed for the
// whole trip. That is the right behaviour for a rider with no number and the wrong
// thing to hand somebody testing whether Call works -- it cost a round trip to
// tell the two apart.
const RIDER_PHONE = '0244321967';

const sql = async (query) => {
  const res = await fetch(
    'https://api.supabase.com/v1/projects/' + admin.SUPABASE_PROJECT_REF + '/database/query',
    { method: 'POST', headers: { Authorization: 'Bearer ' + admin.SUPABASE_ADMIN_TOKEN, 'Content-Type': 'application/json' }, body: JSON.stringify({ query }) },
  );
  const body = await res.json();
  if (!res.ok) throw new Error(body.message ?? JSON.stringify(body));
  return Array.isArray(body) ? body : (body.value ?? []);
};

if (teardown) {
  // Chat and reports point at trips; trips point at the rider. Auth rows last,
  // because a confirmed auth user with no profile is invisible to anybody looking.
  const chats = await sql(
    `delete from chat_messages where trip_id in (select id from trips where pickup->>'label' like '${MARK}%') returning id`,
  );
  const msgs = await sql(
    `delete from left_item_reports where trip_id in (select id from trips where pickup->>'label' like '${MARK}%') returning id`,
  );
  const wd = await sql(
    `delete from trip_withdrawals where trip_id in (select id from trips where pickup->>'label' like '${MARK}%') returning id`,
  );
  const trips = await sql(`delete from trips where pickup->>'label' like '${MARK}%' returning id`);
  const profs = await sql(`delete from profiles where full_name like '${MARK}%' returning id`);
  const auths = await sql(`delete from auth.users where email like '${MARK}-%@example.test' returning id`);
  console.log(
    `torn down: ${trips.length} trip, ${chats.length} chat, ${msgs.length} report, ` +
      `${wd.length} withdrawal, ${profs.length} profile, ${auths.length} auth user`,
  );
  process.exit(0);
}

const stamp = Date.now();

// `--as <email>` attaches the trip to a driver who already exists, instead of
// making a throwaway one. Needed because the handset is signed in as a real driver
// and signing it out to swap accounts is not a thing to do to somebody's phone
// mid-session. Their own trip is a normal trip on a normal account, so nothing
// about the four screens under test changes -- only whose name is on them.
const asIndex = process.argv.indexOf('--as');
const AS_EMAIL = asIndex >= 0 ? process.argv[asIndex + 1] : null;

const signupAs = async (who) => {
  const email = `${MARK}-${who}-${stamp}@example.test`;
  const res = await fetch(url + '/auth/v1/signup', {
    method: 'POST',
    headers: { apikey: ANON, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password: PASSWORD, data: { full_name: `${MARK} ${who}` } }),
  });
  const body = await res.json();
  if (!body.access_token) throw new Error(`signup ${who}: ` + JSON.stringify(body).slice(0, 200));
  // Read the id back out of `auth.users` rather than trusting the response's
  // `user.id`, which was `undefined` on this project's configuration and got as
  // far as writing the string 'undefined' into a uuid column before anything
  // objected.
  const id = (await sql(`select id from auth.users where lower(email) = lower('${email}')`))[0]?.id;
  if (!id) throw new Error(`${email} signed up but is not in auth.users`);
  return { id, email };
};

let driver;
let credentials = null;

if (AS_EMAIL) {
  const row = (
    await sql(
      `select p.id, p.full_name, p.kyc_status, p.availability, p.phone, p.vehicle_id,
              u.email
         from profiles p
         join auth.users u on u.id = p.id
        where lower(u.email) = lower('${AS_EMAIL}')`,
    )
  )[0];
  if (!row) {
    console.error(`no profile for ${AS_EMAIL}`);
    process.exit(1);
  }
  driver = row;
  // Stated rather than assumed: attaching a trip to a driver who cannot be matched
  // would produce an app sitting on "Waiting for ride requests" and a verifier that
  // reports success.
  const vehicles = (
    await sql(`select count(*)::int as n from vehicles where owner_id = '${row.id}' and approved`)
  )[0].n;
  const locations = (
    await sql(`select count(*)::int as n from driver_locations where driver_id = '${row.id}'`)
  )[0].n;
  if (row.kyc_status !== 'approved' || vehicles < 1 || locations < 1) {
    console.error(
      `${AS_EMAIL} cannot be matched: kyc=${row.kyc_status} vehicles=${vehicles} locations=${locations}`,
    );
    process.exit(1);
  }
} else {
  driver = await signupAs('driver');
  await sql(
    `update profiles set role = 'driver', kyc_status = 'approved', availability = 'online',
                          phone = '${PHONE}', full_name = '${MARK} driver'
      where id = '${driver.id}'`,
  );
  await sql(
    `insert into vehicles (owner_id, vehicle_category, make, model, plate, seats, approved, ride_category)
     values ('${driver.id}', 'sedan', 'Toyota', 'Corolla', '${MARK.toUpperCase()}-${stamp}', 4, true, 'standard')`,
  );
  // `profiles.vehicle_id` is what the Profile tab actually reads --
  // `DriverProfileScreen` gates the car card on `(who.vehicleId ?? '').isNotEmpty` and
  // shows "No vehicle added yet" otherwise. A `vehicles` row on its own is not
  // enough, and the app is right to say so; this script left it unset on its first
  // run and the handset displayed "No vehicle added yet" next to a perfectly good
  // Corolla sitting in the table.
  await sql(
    `update profiles set vehicle_id = (
        select id from vehicles where owner_id = '${driver.id}' and approved limit 1
     ) where id = '${driver.id}'`,
  );
  // Osu, so the routing function has a real start; the driver's own position is what
  // navigation measures from.
  await sql(
    `insert into driver_locations (driver_id, point, heading)
     values ('${driver.id}', st_makepoint(5.5639, -0.1950), 0)`,
  );
  credentials = { email: driver.email, password: PASSWORD };
}

const rider = await signupAs('rider');
await sql(
  `update profiles set role = 'rider', full_name = '${MARK} rider', phone = '${RIDER_PHONE}'
    where id = '${rider.id}'`,
);

// Osu -> Kotoka. About 6km of real road, so the turn banner gets real steps and
// not the degenerate two-point route a trip to where you already are returns.
//
// `pickup.point` is NOT optional. `TripStop.fromJson` reads `json['point'] as
// Map<String, dynamic>` and the app writes it (`TripStop.toJson`), so a stop built
// as `{label, address}` with no point makes the whole Trips tab die on
// `type 'Null' is not a subtype of type 'Map<String, dynamic>'`. That is exactly
// what the first version of this script wrote, and it cost a round trip to find.
const trip = (
  await sql(
    `insert into trips (rider_id, driver_id, category, state, pickup, dropoff,
                        pickup_point, dropoff_point, distance_km, fare_ghs, is_demo, matched_at)
     values ('${rider.id}', '${driver.id}', 'standard', 'arriving',
             '{"label":"${MARK} Osu","point":{"lat":5.5639,"lng":-0.195},"address":"Osu, Accra"}'::jsonb,
             '{"label":"${MARK} Airport","point":{"lat":5.6052,"lng":-0.1668},"address":"Kotoka International Airport, Accra"}'::jsonb,
             st_makepoint(5.5639, -0.1950), st_makepoint(5.6052, -0.1668),
             6.4, 22.40, true, now())
     returning id, state, fare_ghs`,
  )
)[0];

const gates = (
  await sql(
    `select p.kyc_status, p.availability, p.phone, p.full_name,
            (p.vehicle_id is not null) as has_vehicle_id,
            (select count(*) from vehicles v where v.owner_id = p.id and v.approved)::int as vehicles,
            (select count(*) from driver_locations l where l.driver_id = p.id)::int as locations
       from profiles p where p.id = '${driver.id}'`,
  )
)[0];

console.log(`driver  ${gates.full_name}  ${gates.kyc_status}  ${gates.availability}  phone ${gates.phone}`);
console.log(
  `        ${gates.vehicles} vehicle  vehicle_id=${gates.has_vehicle_id}  ${gates.locations} location`,
);
console.log(`trip    ${trip.id}  state=${trip.state}  fare=GH\u20b5${Number(trip.fare_ghs).toFixed(2)}`);
if (credentials) {
  console.log(`\nsign in on the handset with:`);
  console.log(`  email     ${credentials.email}`);
  console.log(`  password  ${credentials.password}`);
} else {
  console.log(`\nattached to an existing driver; no sign-in needed.`);
}
console.log(`\nwhen done:  node toolchain/make-device-trip.mjs --teardown`);