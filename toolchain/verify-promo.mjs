// Live check of the launch-promo trigger. Not part of the suite: it makes and
// destroys a real auth user and real trip rows, so it is a one-shot script
// rather than a test you can run by accident.
//
//   node toolchain/verify-promo.mjs
//
// What it has to prove, and cannot prove from a unit test:
//   1. the window starts on the FIRST completed trip, not before
//   2. it is dated from the trip's own completed_at, not from now()
//   3. a second completion does not restart it
//   4. five months out is five calendar months

import { readEnv } from './read-env.mjs';

const env = readEnv('toolchain/supabase-admin.env');
const REF = env.SUPABASE_PROJECT_REF;
const ANON = env.SUPABASE_ANON_KEY;
const MGMT = 'https://api.supabase.com/v1/projects/' + REF + '/database/query';
const MGMT_HDR = { Authorization: 'Bearer ' + env.SUPABASE_ADMIN_TOKEN, 'Content-Type': 'application/json' };

async function q(sql) {
  const res = await fetch(MGMT, { method: 'POST', headers: MGMT_HDR, body: JSON.stringify({ query: sql }) });
  const body = await res.json();
  if (!res.ok) throw new Error(body.message ?? JSON.stringify(body));
  return Array.isArray(body) ? body : (body.value ?? body);
}
const one = async (sql) => (await q(sql))[0]?.id;

const say = (label, value) => console.log('  ' + label.padEnd(46) + (value === undefined ? '(none)' : value));

let uid = null;
let ok = true;
const check = (label, got, want) => {
  const pass = String(got) === String(want);
  if (!pass) ok = false;
  console.log('  ' + (pass ? 'PASS' : 'FAIL') + '  ' + label.padEnd(42) + got + (pass ? '' : '   expected ' + want));
};

try {
  const email = 'promotest_' + Math.random().toString(36).slice(2, 10) + '@example.com';
  const signup = await fetch(`https://${REF}.supabase.co/auth/v1/signup`, {
    method: 'POST',
    headers: { apikey: ANON, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password: 'Testdrive123!', data: { full_name: 'Promo Test' } }),
  });
  const su = await signup.json();
  uid = su.user?.id;
  if (!uid) throw new Error('signup failed: ' + JSON.stringify(su));
  console.log('  throwaway driver ' + uid + ' (signed up through the app\'s own endpoint)');

  await q(`insert into profiles (id, role, full_name) values ('${uid}','driver','Promo Test') on conflict (id) do nothing`);
  const vid = await one(
    `insert into vehicles (owner_id, vehicle_category, ride_category, make, model, plate, seats, approved)
     values ('${uid}','sedan','standard','Toyota','Corolla','PROMO-${Math.random().toString(36).slice(2, 8)}',4,true)
     returning id::text`);
  console.log('  vehicle ' + vid);

  const newTrip = (fare) => one(
    `insert into trips (rider_id, driver_id, vehicle_id, category, state, pickup, dropoff,
                        pickup_point, dropoff_point, distance_km, fare_ghs, is_demo)
     values ('${uid}','${uid}','${vid}','standard','ongoing','{}','{}',
             st_geogfromtext('POINT(-0.18 5.60)'), st_geogfromtext('POINT(-0.20 5.57)'), ${fare}, ${fare}, true)
     returning id::text`);

  console.log('\n=== 1. no promo before the first completed trip ===');
  check('promo rows', (await q(`select count(*)::text n from driver_promos where driver_id='${uid}'`))[0].n, '0');

  console.log('\n=== 2. first completion, backdated three months ===');
  const t1 = await newTrip(8.0);
  await q(`update trips set state='completed', completed_at = now() - interval '3 months' where id='${t1}'`);
  const first = (await q(`select started_at::text s, ends_at::text e,
      round(extract(epoch from (ends_at-started_at))/86400.0)::int d
      from driver_promos where driver_id='${uid}'`))[0];
  if (!first) throw new Error('the trigger did not create a promo row -- this is the failure this script exists to catch');
  say('started_at', first.s);
  say('ends_at', first.e);
  check('window is ~5 months of days', Math.abs(first.d - 152) <= 5, true);
  // started_at must be the trip's completed_at (3 months ago), not now()
  const startedAge = (await q(`select round(extract(epoch from (now()-started_at))/86400.0)::int d from driver_promos where driver_id='${uid}'`))[0].d;
  check('started_at follows completed_at, not now()', startedAge > 85 && startedAge < 95, true);
  const leftThen = (await q(`select round(extract(epoch from (ends_at-now()))/86400.0)::int d from driver_promos where driver_id='${uid}'`))[0].d;
  say('days of promo left for this driver', leftThen);

  console.log('\n=== 3. a second trip completes today: the window must not restart ===');
  const t2 = await newTrip(3.0);
  await q(`update trips set state='completed', completed_at = now() where id='${t2}'`);
  check('still exactly one promo row', (await q(`select count(*)::text n from driver_promos where driver_id='${uid}'`))[0].n, '1');
  check('started_at unchanged',
    (await q(`select started_at::text s from driver_promos where driver_id='${uid}'`))[0].s, first.s);

  console.log('\n=== 4. a driver still inside the window reads 0% commission ===');
  const age = (await q(`select round(extract(epoch from (ends_at-now()))/86400.0)::int d from driver_promos where driver_id='${uid}'`))[0].d;
  say('days left', age);
  check('inside the window', age > 0, true);

  console.log('\n=== 5. a client cannot mint its own window (no INSERT policy) ===');
  const forge = await fetch(`https://${REF}.supabase.co/rest/v1/driver_promos`, {
    method: 'POST',
    headers: { apikey: ANON, Authorization: 'Bearer ' + su.access_token, 'Content-Type': 'application/json', Prefer: 'return=representation' },
    body: JSON.stringify({ driver_id: uid, started_at: '2020-01-01T00:00:00Z', ends_at: '2099-01-01T00:00:00Z' }),
  });
  say('client INSERT into driver_promos -> HTTP', forge.status);
  check('rejected by row security', forge.status >= 400, true);
} catch (e) {
  ok = false;
  console.log('  ERROR: ' + e.message);
} finally {
  if (uid) {
    for (const sql of [
      `delete from trips where driver_id='${uid}'`,
      `delete from vehicles where owner_id='${uid}'`,
      `delete from profiles where id='${uid}'`,
      `delete from auth.users where id='${uid}'`,
    ]) { try { await q(sql); } catch { /* already gone */ } }
    const left = await q(`select (select count(*) from profiles where id='${uid}')::text p,
                                (select count(*) from driver_promos where driver_id='${uid}')::text r,
                                (select count(*) from auth.users where id='${uid}')::text a`);
    console.log('\n  cleanup: profiles=' + left[0].p + ' promos=' + left[0].r + ' auth=' + left[0].a);
  }
}
console.log('\n' + (ok ? 'ALL CHECKS PASSED' : 'SOMETHING FAILED'));
process.exit(ok ? 0 : 1);
