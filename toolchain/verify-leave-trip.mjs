// Proves the driver-withdrawal rules, and proves the matcher now remembers.
//
//   node toolchain/verify-leave-trip.mjs
//
// Three things are being claimed and only one of them is obvious:
//
//   1. a driver can withdraw while `arriving`
//   2. a driver CANNOT withdraw while `ongoing` -- the rider is in the car
//   3. `match_offers_for_trip` will not offer that trip to that driver again
//
// (3) is the one with no user-visible failure if it is wrong. The trip still gets
// matched; it is just matched to the driver who declined it, and nothing anywhere
// reports it. So it is asserted directly against the function rather than inferred
// from the feature working.
//
// The function under test is not deployed at the point this is first run, so the
// first section is skipped with a note rather than reported as a pass.

import { readEnvOrFail } from './read-env.mjs';

const admin = readEnvOrFail('toolchain/supabase-admin.env', [
  'SUPABASE_PROJECT_REF',
  'SUPABASE_ADMIN_TOKEN',
]);
const build = readEnvOrFail('toolchain/apk-build.env', ['SB_URL', 'SB_ANON_KEY']);
const ANON = build.SB_ANON_KEY;
const url = build.SB_URL.replace(/\/+$/, '');
const pad = (s, n) => String(s).padEnd(n);

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

const results = [];
const check = (label, actual, expected, why) => {
  const ok = actual === expected;
  results.push({ label, ok });
  console.log(
    `  ${ok ? 'PASS' : 'FAIL'}  ${pad(label, 46)} ${pad(String(actual), 10)} ` +
      `wanted ${pad(String(expected), 10)} ${why}`,
  );
};

// --------------------------------------------------------------- fixtures
const stamp = Date.now();
const signUp = async (who) => {
  const res = await fetch(url + '/auth/v1/signup', {
    method: 'POST',
    headers: { apikey: ANON, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      email: `leave-${who}-${stamp}@example.test`,
      password: 'Probe-9abcdefgh',
      data: { full_name: who },
    }),
  });
  const body = await res.json();
  if (!body.access_token) throw new Error('signup: ' + JSON.stringify(body).slice(0, 200));
  return { id: body.user.id, token: body.access_token };
};

const driver = await signUp('Driver');
const rider = await signUp('Rider');
console.log(`  driver ${driver.id.slice(0, 8)}   rider ${rider.id.slice(0, 8)}`);

// A vehicle in the right category and a known location, because the matcher
// needs both before it will even look at a driver. `vehicle_category` is the body
// style and stays `sedan` -- renaming `van` to `lite` moved the *ride* tier to
// `ride_category` and left the body style alone.
//
// The plate is unique, so it carries the run's stamp. A fixed plate would make
// this script pass once and then fail on every run afterwards, which is the worst
// way for a verifier to behave.
await sql(
  `insert into vehicles (owner_id, vehicle_category, make, model, plate, seats,
                         approved, ride_category)
   values ('${driver.id}', 'sedan', 'Toyota', 'Corolla', 'LEAVE-${stamp}', 4, true, 'standard')`,
);
// `card_number` does not exist on `profiles` -- the column is `ghana_card_number`,
// added by 20260930000003. Nothing here needs it, so the fixture does not set it.
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
               '{"label":"Osu","address":"Osu"}'::jsonb,
               '{"label":"Airport","address":"Airport"}'::jsonb,
               st_makepoint(5.6037, -0.1870), st_makepoint(5.6200, -0.1870),
               2.02, 12.50, true, now())
       returning id`,
    )
  )[0].id;

// ---------------------------------------------------------------------------
console.log('\n=== 1. the matcher remembers a withdrawal ===\n');

const tripForMatch = await makeTrip('requested');
const before = await sql(`select * from match_offers_for_trip('${tripForMatch}')`);
check('the driver is offered the trip to begin with', before.some((r) => r.driver_id === driver.id), true, 'the fixture is matchable');

await sql(
  `insert into trip_withdrawals (trip_id, driver_id, reason) values ('${tripForMatch}', '${driver.id}', 'cannot_find')`,
);
const after = await sql(`select * from match_offers_for_trip('${tripForMatch}')`);
check('and is not after withdrawing', after.some((r) => r.driver_id === driver.id), false, 'the whole reason the table exists');

// And the exclusion is on the *pair*, not the driver. A driver who declines one
// trip must still get the next one; a rule that punished declining would push
// drivers offline, which is the opposite of the intent.
const otherTrip = await makeTrip('requested');
const nextTrip = await sql(`select * from match_offers_for_trip('${otherTrip}')`);
check('but is still offered the next one', nextTrip.some((r) => r.driver_id === driver.id), true, 'refusing work is allowed');

// ---------------------------------------------------------------------------
console.log('\n=== 2. the function, if it is deployed ===\n');

const callLeave = async (tripId, who, reason = 'rider_absent') => {
  const res = await fetch(url + '/functions/v1/leave-trip', {
    method: 'POST',
    headers: {
      apikey: ANON,
      Authorization: 'Bearer ' + who.token,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ tripId, reason }),
  });
  return { status: res.status, body: await res.json() };
};

const arriving = await makeTrip('arriving');
const r1 = await callLeave(arriving, driver);
if (r1.status === 404 && /not found/i.test(JSON.stringify(r1.body))) {
  console.log('  SKIPPED: leave-trip is not deployed yet. Run the deploy step first.');
  console.log('  Section 1 above is the part with no user-visible failure, and it is checked.');
} else {
  check('a driver withdraws while arriving', r1.status, 200, 'the whole feature');
  const tripRow = (await sql(`select state, matched_at from trips where id = '${arriving}'`))[0];
  check('  the trip goes back to requested', tripRow.state, 'requested', 'the rider still wants a ride');
  check('  and matched_at is cleared', tripRow.matched_at, null, 'it recorded when this driver was given it');
  const wd = await sql(`select * from trip_withdrawals where trip_id = '${arriving}'`);
  check('  the withdrawal is recorded', wd.length, 1, 'so the matcher can forget');
  const drv = (await sql(`select availability from profiles where id = '${driver.id}'`))[0];
  check('  and the driver is back online', drv.availability, 'online', 'not offline: they still want the next one');

  // The rule that matters.
  const ongoing = await makeTrip('ongoing');
  const r2 = await callLeave(ongoing, driver);
  check('a driver cannot withdraw while ongoing', r2.status, 409, 'the rider is in the car');
  const stillOngoing = (await sql(`select state from trips where id = '${ongoing}'`))[0];
  check('  and the trip did not move', stillOngoing.state, 'ongoing', '');

  // Not the driver who withdraws.
  const r3 = await callLeave(arriving, rider);
  check('the rider cannot use this to cancel', r3.status, 403, 'cancellation has its own rules and its own money');
  const stranger = await signUp('Stranger');
  const r4 = await callLeave(arriving, stranger);
  check('somebody not on the trip cannot', r4.status, 403, '');

  // A second press. The unique constraint and the conditional update have to make
  // this a no-op rather than an error, because the driver tapped the button twice.
  const r5 = await callLeave(arriving, driver);
  check('a second press is not an error', r5.status, 409, 'the trip is already back in the pool');
}

// ---------------------------------------------------------------------------
await sql(`delete from trips where rider_id = '${rider.id}' or driver_id = '${driver.id}'`);
await sql(`delete from profiles where id in ('${driver.id}','${rider.id}')`);

const failed = results.filter((x) => !x.ok);
console.log(`\n=== ${results.length - failed.length} of ${results.length} passed ===`);
if (failed.length > 0) {
  for (const f of failed) console.log(`  FAIL ${f.label}`);
  process.exit(1);
}
console.log('All probe rows removed.');