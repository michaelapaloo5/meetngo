// Asks leave-trip what is actually wrong, because verify-leave-trip.mjs only
// compares statuses and a 500 and a 503 look identical from the outside.
//
//   node toolchain/probe-leave-trip.mjs
//
// Prints the raw response body for each call. Verifiers assert on status and go
// quiet on the body, which is fine while you are checking a rule and useless the
// moment the function itself is broken: four rules pass and the feature 500s, and
// nothing says why.
//
// Same fixtures as the verifier, same stamp-in-everything discipline, same cleanup.

import { readEnvOrFail } from './read-env.mjs';

const admin = readEnvOrFail('toolchain/supabase-admin.env', [
  'SUPABASE_PROJECT_REF',
  'SUPABASE_ADMIN_TOKEN',
]);
const build = readEnvOrFail('toolchain/apk-build.env', ['SB_URL', 'SB_ANON_KEY']);
const ANON = build.SB_ANON_KEY;
const url = build.SB_URL.replace(/\/+$/, '');

const sql = async (query) => {
  const res = await fetch(
    'https://api.supabase.com/v1/projects/' + admin.SUPABASE_PROJECT_REF + '/database/query',
    {
      method: 'POST',
      headers: {
        Authorization: 'Bearer ' + admin.SUPABASE_ADMIN_TOKEN,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ query }),
    },
  );
  const body = await res.json();
  if (!res.ok) throw new Error(body.message ?? JSON.stringify(body));
  return Array.isArray(body) ? body : (body.value ?? []);
};

const stamp = Date.now();

const signUp = async (who) => {
  const res = await fetch(url + '/auth/v1/signup', {
    method: 'POST',
    headers: { apikey: ANON, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      email: `probe-${who}-${stamp}@example.test`,
      password: 'Probe-9abcdefgh',
      data: { full_name: who },
    }),
  });
  const body = await res.json();
  if (!body.access_token) throw new Error('signup: ' + JSON.stringify(body).slice(0, 300));
  return { id: body.user.id, token: body.access_token };
};

const call = async (tripId, who, reason = 'rider_absent') => {
  const res = await fetch(url + '/functions/v1/leave-trip', {
    method: 'POST',
    headers: {
      apikey: ANON,
      Authorization: 'Bearer ' + who.token,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ tripId, reason }),
  });
  const text = await res.text();
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    parsed = text;
  }
  return { status: res.status, body: parsed };
};

const driver = await signUp('Driver');
const rider = await signUp('Rider');
console.log(`  driver ${driver.id}   rider ${rider.id}`);

await sql(
  `insert into vehicles (owner_id, vehicle_category, make, model, plate, seats,
                         approved, ride_category)
   values ('${driver.id}', 'sedan', 'Toyota', 'Corolla', 'PROBE-${stamp}', 4, true, 'standard')`,
);
await sql(
  `update profiles set role = 'driver', kyc_status = 'approved', availability = 'online'
    where id = '${driver.id}'`,
);
await sql(
  `insert into driver_locations (driver_id, point, heading)
   values ('${driver.id}', st_makepoint(5.6037, -0.1870), 0)`,
);

const makeTrip = async (state) =>
  (
    await sql(
      `insert into trips (rider_id, driver_id, category, state, pickup, dropoff,
                          pickup_point, dropoff_point, distance_km, fare_ghs, is_demo, matched_at)
       values ('${rider.id}', '${driver.id}', 'standard', '${state}',
               '{"label":"Osu","point":{"lat":5.6037,"lng":-0.187},"address":"Osu"}'::jsonb,
               '{"label":"Airport","point":{"lat":5.6200,"lng":-0.187},"address":"Airport"}'::jsonb,
               st_makepoint(5.6037, -0.1870), st_makepoint(5.6200, -0.1870),
               2.02, 12.50, true, now())
       returning id`,
    )
  )[0].id;

const show = async (label, tripId, who) => {
  const r = await call(tripId, who);
  console.log(`\n--- ${label}\n  status ${r.status}`);
  console.log('  body: ' + JSON.stringify(r.body, null, 2).split('\n').join('\n        '));
  return r;
};

console.log('\n=== raw responses from the deployed leave-trip ===');

const arriving = await makeTrip('arriving');
await show('driver withdraws while arriving (want 200)', arriving, driver);

const ongoing = await makeTrip('ongoing');
await show('driver withdraws while ongoing (want 409)', ongoing, driver);

await show('rider tries it (want 403)', arriving, rider);
await show('second press (want 409)', arriving, driver);

// And the trip state afterwards, because a 500 that still changed the row would be
// a different bug from a 500 that changed nothing.
const rows = await sql(
  `select state, matched_at, driver_id is null as driver_cleared from trips where id in ('${arriving}','${ongoing}')`,
);
console.log('\n=== trips afterwards ===');
console.log('  ' + JSON.stringify(rows));

await sql(`delete from trips where rider_id = '${rider.id}' or driver_id = '${driver.id}'`);
await sql(`delete from profiles where id in ('${driver.id}','${rider.id}')`);
console.log('\nprobe rows removed.');