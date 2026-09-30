// Does `match_offers_for_trip` actually refuse a driver selling the wrong tier?
//
//   node toolchain/verify-match.mjs
//
// This is the check that catches the bug this migration fixes, and it has to be
// live: the whole function is one SQL join, and a unit test cannot tell you
// whether the join condition is in the deployed database. The check builds two
// drivers who are identical in every respect the function filters on -- approved
// KYC, approved vehicle, online, a location inside 5 km -- differing ONLY in the
// category their vehicle sells, and asserts that a premium trip reaches one and
// not the other. If the category condition is missing, both come back and this
// fails.

import { readFileSync } from 'node:fs';

const env = {};
for (const file of ['toolchain/supabase-admin.env', 'toolchain/apk-build.env']) {
  let text;
  try { text = readFileSync(file, 'utf8'); } catch { continue; }
  for (const line of text.split('\n')) {
    const m = /^\s*(?:export\s+)?([A-Z_0-9]+)=(.*)$/.exec(line);
    if (m && m[2]) env[m[1]] ??= m[2].replace(/^["']|["']$/g, '');
  }
}
const REF = env.SUPABASE_PROJECT_REF;
const ANON = env.SUPABASE_ANON_KEY;
const MGMT = 'https://api.supabase.com/v1/projects/' + REF + '/database/query';
const headers = { Authorization: 'Bearer ' + env.SUPABASE_ADMIN_TOKEN, 'Content-Type': 'application/json' };

async function q(sql) {
  const res = await fetch(MGMT, { method: 'POST', headers, body: JSON.stringify({ query: sql }) });
  const body = await res.json();
  if (!res.ok) throw new Error(body.message ?? JSON.stringify(body));
  return Array.isArray(body) ? body : (body.value ?? body);
}
const one = async (sql) => (await q(sql))[0]?.id;

const say = (l, v) => console.log('  ' + l.padEnd(52) + (v === undefined ? '(none)' : v));
let ok = true;
const check = (label, got, want) => {
  const pass = String(got) === String(want);
  if (!pass) ok = false;
  console.log('  ' + (pass ? 'PASS' : 'FAIL') + '  ' + label.padEnd(48) + got + (pass ? '' : '   expected ' + want));
};

// A pickup and a drop, both in Accra, close enough that one driver is inside
// 5 km of the pickup and the other is the same distance away.
const PICKUP = 'POINT(-0.1870 5.6037)';   // Independence Arch
const DROPOFF = 'POINT(-0.1660 5.6052)';  // Airport Residential

const made = [];
try {
  // Two drivers, one trip category apart, nothing else different.
  for (const [who, category] of [['premium-driver', 'premium'], ['standard-driver', 'standard']]) {
    const email = `matchtest_${who}_${Math.random().toString(36).slice(2, 8)}@example.com`;
    const su = await (await fetch(`https://${REF}.supabase.co/auth/v1/signup`, {
      method: 'POST',
      headers: { apikey: ANON, 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password: 'Testdrive123!' }),
    })).json();
    const uid = su.user?.id;
    if (!uid) throw new Error('signup failed for ' + who + ': ' + JSON.stringify(su));

    // Signup ALREADY creates the profile: `on_auth_user_created` runs
    // `handle_new_user()`, which inserts a `profiles` row with the role read
    // from `raw_user_meta_data`. So this is an UPDATE, not an INSERT, and the
    // first version of this script inserted and died on `profiles_pkey`.
    //
    // That also means the signup response's role is honoured, which is worth
    // knowing: `data: { role: 'driver' }` in the signup body is what makes the
    // trigger create a driver rather than a rider.
    await q(`insert into profiles (id, role, full_name)
             values ('${uid}','driver','${who}')
             on conflict (id) do nothing`);
    // Then set the two columns the match function filters on, which signup
    // deliberately leaves at their defaults ('notStarted' and 'offline').
    await q(`update profiles
             set role = 'driver', kyc_status = 'approved', availability = 'online', full_name = '${who}'
             where id = '${uid}'`);
    const vid = await one(
      `insert into vehicles (owner_id, vehicle_category, ride_category, make, model, plate, seats, approved)
       values ('${uid}','sedan','${category}','Toyota','Corolla',
               'MT-${who.slice(0, 4).toUpperCase()}-${Math.random().toString(36).slice(2, 6)}',4,true)
       returning id::text`);
    // A location row. The function requires one to exist; the distance check is
    // `driver_pickup_distance_km(...) <= 5.0`, so this is right on the pickup.
    // A location row. The function requires one to exist; the distance check is
    // `driver_pickup_distance_km(...) <= 5.0`, so this sits on the pickup.
    //
    // The four columns are `driver_id`, `point`, `heading`, `updated_at` -- there
    // is no `speed_kph` and no `recorded_at`, which the first version of this
    // script assumed and Postgres rejected. `toolchain/print-columns.mjs
    // driver_locations` is where to look them up.
    await q(`insert into driver_locations (driver_id, point, heading)
             values ('${uid}', st_geogfromtext('${PICKUP}'), 0)`);
    made.push({ who, uid, category, vid });
    say('driver ' + who, uid.slice(0, 8) + '...  sells ' + category);
  }

  // The trip is premium. Only the premium driver may be offered it.
  const tripId = await one(
    `insert into trips (rider_id, driver_id, vehicle_id, category, state, pickup, dropoff,
                        pickup_point, dropoff_point, distance_km, fare_ghs, is_demo)
     values ('${made[0].uid}', null, null, 'premium', 'requested', '{}', '{}',
             st_geogfromtext('${PICKUP}'), st_geogfromtext('${DROPOFF}'), 3.0, 1.05, true)
     returning id::text`);
  console.log('\n  premium trip ' + tripId.slice(0, 8) + '...');

  const matched = await q(`select driver_id::text as d from match_offers_for_trip('${tripId}')`);
  const ids = new Set(matched.map((r) => r.d));
  console.log('\n=== a premium trip, and two identical drivers on different tiers ===');
  for (const m of made) {
    check(m.who + ' (sells ' + m.category + ') was offered it', ids.has(m.uid), m.category === 'premium');
  }

  const howMany = matched.length;
  check('exactly one driver matched', howMany, 1);

  // And the other direction, so the filter is not simply excluding everybody.
  const standardTrip = await one(
    `insert into trips (rider_id, driver_id, vehicle_id, category, state, pickup, dropoff,
                        pickup_point, dropoff_point, distance_km, fare_ghs, is_demo)
     values ('${made[0].uid}', null, null, 'standard', 'requested', '{}', '{}',
             st_geogfromtext('${PICKUP}'), st_geogfromtext('${DROPOFF}'), 3.0, 1.05, true)
     returning id::text`);
  const matched2 = await q(`select driver_id::text as d from match_offers_for_trip('${standardTrip}')`);
  const ids2 = new Set(matched2.map((r) => r.d));
  console.log('\n=== a standard trip: the tiers must swap, proving the filter reads the trip ===');
  for (const m of made) {
    check(m.who + ' (sells ' + m.category + ') was offered it', ids2.has(m.uid), m.category === 'standard');
  }
  // Only the two fixtures are counted, NOT `matched2.length`. The live database
  // has a real approved driver (lonelymic04, selling standard, with a location
  // row), so a standard trip legitimately matches three drivers in total and
  // asserting `length === 1` fails for a reason that has nothing to do with the
  // category filter. What matters is which of MY two drivers came back.
  const mine = matched2.filter((r) => made.some((m) => m.uid === r.d));
  check('exactly one of my two drivers matched', mine.length, 1);
  console.log('  (the live data has ' + (matched2.length - mine.length)
    + ' other matchable driver(s), which is why the total is not 1)');

  await q(`delete from trips where id in ('${tripId}','${standardTrip}')`);
} catch (e) {
  ok = false;
  console.log('  ERROR: ' + e.message);
} finally {
  for (const m of made) {
    for (const sql of [
      `delete from trips where rider_id='${m.uid}' or driver_id='${m.uid}'`,
      `delete from driver_locations where driver_id='${m.uid}'`,
      `delete from vehicles where owner_id='${m.uid}'`,
      `delete from profiles where id='${m.uid}'`,
      `delete from auth.users where id='${m.uid}'`,
    ]) { try { await q(sql); } catch { /* already gone */ } }
  }
  if (made.length) {
    const left = await q(`select (select count(*) from profiles where id in (${made.map((m) => `'${m.uid}'`).join(',')}))::text p`);
    console.log('\n  cleanup: ' + left[0].p + ' test profiles left');
  }
}
console.log('\n' + (ok ? 'ALL CHECKS PASSED' : 'SOMETHING FAILED'));
process.exit(ok ? 0 : 1);
