// Calls `complete-trip` twice on one already-completed trip, as the rider.
//
//   node toolchain/verify-complete-trip-twice.mjs
//
// Why this exists: when the driver finishes a ride, the rider's own `complete()`
// call is the second caller, and it used to come back with no settlement -- so
// no receipt rendered and the rider was left on "Your ride". The rider app works
// around it with a toast and a hop to the Bookings tab; this script establishes
// whether that is the only thing standing between a rider and their receipt.
//
// It also checks the money rather than the status code. A second call that
// answers 200 with a settlement while writing a *second* fare into the ledger
// would look like a fix and be a doubling, and a status-only check cannot tell
// those apart.
//
// Writes real rows to the real project. Everything is tagged `complete-check` and
// removed at the end, so a rerun does not pile up.

import { readEnvOrFail } from './read-env.mjs';

const admin = readEnvOrFail('toolchain/supabase-admin.env', [
  'SUPABASE_PROJECT_REF',
  'SUPABASE_ADMIN_TOKEN',
]);
const build = readEnvOrFail('toolchain/apk-build.env', ['SB_URL', 'SB_ANON_KEY']);
const ANON = build.SB_ANON_KEY;
const url = build.SB_URL.replace(/\/+$/, '');
const MARK = 'complete-check';
const PASSWORD = 'CompleteCheck-123!';

const sql = async (query) => {
  const res = await fetch(
    'https://api.supabase.com/v1/projects/' + admin.SUPABASE_PROJECT_REF +
      '/database/query',
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
const made = [];

const signupAs = async (who) => {
  const email = `${MARK}-${who}-${stamp}@example.test`;
  const res = await fetch(url + '/auth/v1/signup', {
    method: 'POST',
    headers: { apikey: ANON, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password: PASSWORD, data: { full_name: `${MARK} ${who}` } }),
  });
  const body = await res.json();
  if (!body.access_token) throw new Error(`signup ${who}: ` + JSON.stringify(body).slice(0, 200));
  // The id is read back out of auth.users rather than trusted from the response:
  // `user.id` came back `undefined` on this project's configuration and got as far
  // as writing the string 'undefined' into a uuid column.
  const id = (await sql(`select id from auth.users where lower(email) = lower('${email}')`))[0]?.id;
  if (!id) throw new Error(`${email} signed up but is not in auth.users`);
  made.push({ email, id });
  return { id, email, token: body.access_token };
};

const call = async (token, tripId) => {
  const res = await fetch(url + '/functions/v1/complete-trip', {
    method: 'POST',
    headers: {
      apikey: ANON,
      Authorization: 'Bearer ' + token,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ tripId }),
  });
  const text = await res.text();
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    parsed = { raw: text.slice(0, 200) };
  }
  return { status: res.status, body: parsed };
};

const money = async (tripId) => {
  const ledger = await sql(
    `select kind, amount_ghs from ledger_entries where trip_id = '${tripId}' order by kind`,
  );
  const payouts = await sql(
    `select amount_ghs from payouts where trip_id = '${tripId}'`,
  );
  const payments = await sql(
    `select state, amount_ghs from payments where trip_id = '${tripId}'`,
  );
  return { ledger, payouts, payments };
};

let failed = false;
const check = (ok, label, detail) => {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}${detail ? '  -- ' + detail : ''}`);
  if (!ok) failed = true;
};

try {
  const driver = await signupAs('driver');
  await sql(
    `update profiles set role = 'driver', kyc_status = 'approved', availability = 'online',
                          phone = '0200000001', full_name = '${MARK} driver'
      where id = '${driver.id}'`,
  );
  const vehicle = (
    await sql(
      `insert into vehicles (owner_id, vehicle_category, make, model, plate, seats, approved, ride_category)
       values ('${driver.id}', 'sedan', 'Toyota', 'Corolla', '${MARK.toUpperCase()}-${stamp}', 4, true, 'standard')
       returning id`,
    )
  )[0];
  await sql(
    `update profiles set vehicle_id = '${vehicle.id}' where id = '${driver.id}'`,
  );
  await sql(
    `insert into driver_locations (driver_id, point, heading)
     values ('${driver.id}', st_makepoint(5.5639, -0.1950), 0)`,
  );

  const rider = await signupAs('rider');
  await sql(
    `update profiles set role = 'rider', full_name = '${MARK} rider', phone = '0244321967'
      where id = '${rider.id}'`,
  );

  // Already `completed`, exactly the state the rider's app finds when the driver
  // has finished. 6.4 km standard: 8 GHS/km = 51.20, and 51.20 clears the 23.00
  // standard floor, so the fare is the per-km one and the number is checkable.
  const trip = (
    await sql(
      `insert into trips (rider_id, driver_id, vehicle_id, category, state, pickup, dropoff,
                          pickup_point, dropoff_point, distance_km, fare_ghs, is_demo,
                          matched_at, started_at, completed_at)
       values ('${rider.id}', '${driver.id}', '${vehicle.id}', 'standard', 'completed',
               '{"label":"${MARK} Osu","point":{"lat":5.5639,"lng":-0.195},"address":"Osu, Accra"}'::jsonb,
               '{"label":"${MARK} Airport","point":{"lat":5.6052,"lng":-0.1668},"address":"Kotoka International Airport, Accra"}'::jsonb,
               st_makepoint(5.5639, -0.1950), st_makepoint(5.6052, -0.1668),
               6.4, 51.20, true, now() - interval '30 minutes',
                   now() - interval '20 minutes', now() - interval '10 minutes')
       returning id, state, fare_ghs`,
    )
  )[0];
  console.log(`trip ${trip.id}  state=${trip.state}  fare=GH¢${Number(trip.fare_ghs).toFixed(2)}\n`);

  const before = await money(trip.id);
  console.log(`before: ledger ${before.ledger.length}, payouts ${before.payouts.length}, payments ${before.payments.length}\n`);

  const first = await call(rider.token, trip.id);
  const afterFirst = await money(trip.id);
  console.log(`call 1: HTTP ${first.status}`);
  console.log(`        settlement: ${first.body.settlement ? 'present' : 'ABSENT'}`);
  if (first.body.error) console.log(`        error: ${first.body.error}`);
  if (first.body.settlement) {
    console.log(`        fare=${first.body.settlement.fareGhs} ` +
      `payout=${first.body.settlement.driverPayoutGhs}`);
  }
  console.log(`        ledger ${afterFirst.ledger.length}, payouts ${afterFirst.payouts.length}, payments ${afterFirst.payments.length}\n`);

  const second = await call(rider.token, trip.id);
  const afterSecond = await money(trip.id);
  console.log(`call 2: HTTP ${second.status}`);
  console.log(`        settlement: ${second.body.settlement ? 'present' : 'ABSENT'}`);
  if (second.body.error) console.log(`        error: ${second.body.error}`);
  if (second.body.settlement) {
    console.log(`        fare=${second.body.settlement.fareGhs} ` +
      `payout=${second.body.settlement.driverPayoutGhs}`);
  }
  console.log(`        ledger ${afterSecond.ledger.length}, payouts ${afterSecond.payouts.length}, payments ${afterSecond.payments.length}\n`);

  console.log('--- what this means ---');
  // The rider's app asks for `settlement`; without it there is no receipt.
  check(
    second.status === 200,
    'the second call answers 200',
    `got ${second.status}`,
  );
  check(
    Boolean(second.body.settlement),
    'the second call carries a settlement, so a receipt can render',
    second.body.error ?? 'no settlement key',
  );
  check(
    afterSecond.ledger.length === afterFirst.ledger.length,
    'the second call writes no extra ledger row',
    `${afterFirst.ledger.length} -> ${afterSecond.ledger.length}`,
  );
  check(
    afterSecond.payouts.length === afterFirst.payouts.length,
    'the second call writes no extra payout',
    `${afterFirst.payouts.length} -> ${afterSecond.payouts.length}`,
  );
  if (first.body.settlement && second.body.settlement) {
    check(
      first.body.settlement.fareGhs === second.body.settlement.fareGhs &&
        first.body.settlement.driverPayoutGhs ===
          second.body.settlement.driverPayoutGhs,
      'both calls agree on the money',
      `${first.body.settlement.fareGhs}/${first.body.settlement.driverPayoutGhs} vs ` +
        `${second.body.settlement.fareGhs}/${second.body.settlement.driverPayoutGhs}`,
    );
  }
} finally {
  // Auth rows last: a confirmed auth user with no profile is invisible to
  // anybody auditing afterwards.
  await sql(`delete from ledger_entries where trip_id in (select id from trips where pickup->>'label' like '${MARK}%')`);
  await sql(`delete from payouts where trip_id in (select id from trips where pickup->>'label' like '${MARK}%')`);
  await sql(`delete from payments where trip_id in (select id from trips where pickup->>'label' like '${MARK}%')`);
  await sql(`delete from trips where pickup->>'label' like '${MARK}%'`);
  await sql(`delete from driver_locations where driver_id in (select id from profiles where full_name like '${MARK}%')`);
  await sql(`delete from vehicles where owner_id in (select id from profiles where full_name like '${MARK}%')`);
  await sql(`delete from profiles where full_name like '${MARK}%'`);
  await sql(`delete from auth.users where email like '${MARK}-%@example.test'`);
  console.log(`\ncleaned up ${made.length} accounts`);
}

process.exit(failed ? 1 : 0);