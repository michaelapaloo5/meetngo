// Does the `contact` function actually keep a number inside the trip?
//
//   node toolchain/verify-contact.mjs
//
// The unit tests stub the lookup, so they prove the *rule* and not the query.
// This proves the query, against the deployed function and a real trip, and the
// part that matters is the refusal: a rider must not be able to walk up to the
// function with somebody else's trip id and come away with that driver's number.
//
// It also proves the direction that could plausibly be broken in a way a test
// would not catch -- a driver asking for the rider, which is the whole feature,
// and the one the driver app will call on every live trip.

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
const adminHeaders = { Authorization: 'Bearer ' + env.SUPABASE_ADMIN_TOKEN, 'Content-Type': 'application/json' };

const q = async (sql) => {
  const res = await fetch(MGMT, { method: 'POST', headers: adminHeaders, body: JSON.stringify({ query: sql }) });
  const body = await res.json();
  if (!res.ok) throw new Error(body.message ?? JSON.stringify(body));
  return Array.isArray(body) ? body : (body.value ?? body);
};
const one = async (sql) => (await q(sql))[0]?.id;

const say = (l, v) => console.log('  ' + l.padEnd(48) + (v === undefined ? '(none)' : v));
let ok = true;
const check = (label, got, want) => {
  const pass = String(got) === String(want);
  if (!pass) ok = false;
  console.log('  ' + (pass ? 'PASS' : 'FAIL') + '  ' + label.padEnd(44) + got + (pass ? '' : '   expected ' + want));
};

/** Call the deployed function as `token`, asking about `tripId`. */
async function ask(tripId, token) {
  const res = await fetch(`https://${REF}.supabase.co/functions/v1/contact`, {
    method: 'POST',
    headers: {
      apikey: ANON,
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ tripId }),
  });
  const body = await res.json();
  return { status: res.status, body };
}

const made = [];
try {
  // A rider and a driver, each with a phone, on one trip -- plus a stranger with
  // their own valid account, because the refusal that matters is a signed-in
  // user being refused, not an anonymous one.
  const users = {};
  for (const who of ['rider', 'driver', 'stranger']) {
    const email = `contacttest_${who}_${Math.random().toString(36).slice(2, 8)}@example.com`;
    const su = await (await fetch(`https://${REF}.supabase.co/auth/v1/signup`, {
      method: 'POST',
      headers: { apikey: ANON, 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password: 'Testdrive123!', data: { role: who } }),
    })).json();
    const uid = su.user?.id;
    if (!uid) throw new Error('signup failed for ' + who + ': ' + JSON.stringify(su));
    users[who] = { uid, token: su.access_token };
    made.push(uid);
  }
  // Phones written on the service key, because a client can only write its own
  // and this test is not testing that.
  for (const who of ['rider', 'driver']) {
    await q(`update profiles set full_name = '${who} person', phone = '0241234567' where id = '${users[who].uid}'`);
  }
  // The stranger's phone is DIFFERENT, so "did the rider get the right number" is
  // answerable rather than "did they get any number".
  await q(`update profiles set full_name = 'stranger person', phone = '0550000000' where id = '${users.stranger.uid}'`);

  const vid = await one(
    `insert into vehicles (owner_id, vehicle_category, ride_category, make, model, plate, seats, approved)
     values ('${users.driver.uid}','sedan','standard','Toyota','Corolla',
             'CT-${Math.random().toString(36).slice(2, 7)}',4,true)
     returning id::text`);
  const tripId = await one(
    `insert into trips (rider_id, driver_id, vehicle_id, category, state, pickup, dropoff,
                        pickup_point, dropoff_point, distance_km, fare_ghs, is_demo)
     values ('${users.rider.uid}','${users.driver.uid}','${vid}','standard','arriving','{}','{}',
             st_geogfromtext('POINT(-0.1870 5.6037)'), st_geogfromtext('POINT(-0.1660 5.6052)'), 4.0, 1.40, true)
     returning id::text`);
  say('trip', tripId.slice(0, 8) + '...');

  console.log('\n=== 1. the driver gets the rider\'s number: the feature ===');
  const asDriver = await ask(tripId, users.driver.token);
  say('HTTP', asDriver.status);
  check('status', asDriver.status, 200);
  check('told whose number it is', asDriver.body.role, 'rider');
  check('the rider\'s number', asDriver.body.phone, '0241234567');
  check('reported callable', asDriver.body.callable, true);

  console.log('\n=== 2. the rider gets the driver\'s number: the same rule, other way ===');
  const asRider = await ask(tripId, users.rider.token);
  check('status', asRider.status, 200);
  check('told whose number it is', asRider.body.role, 'driver');

  console.log('\n=== 3. somebody not on the trip gets NOTHING ===');
  // The whole point of the function. A signed-in user with a valid account, a
  // valid trip id and a real request must come away with no number at all.
  const asStranger = await ask(tripId, users.stranger.token);
  say('HTTP', asStranger.status);
  check('refused', asStranger.status, 404);
  check('no phone in the body', asStranger.body.phone, undefined);
  check('no name in the body', asStranger.body.name, undefined);
  console.log('    (404 rather than 403: a 403 would confirm the trip exists)');

  console.log('\n=== 4. no token at all ===');
  const anonymous = await ask(tripId, null);
  check('refused', anonymous.status, 401);
  check('no phone in the body', anonymous.body.phone, undefined);

  console.log('\n=== 5. a trip id that does not exist reads the same as one you are not on ===');
  const missing = await ask('00000000-0000-0000-0000-000000000000', users.stranger.token);
  check('same status', missing.status, asStranger.status);
  check('same message', missing.body.error, asStranger.body.error);

  console.log('\n=== 6. the function does not echo a caller-supplied profile id ===');
  // There is no such parameter, and there must not become one. If the body
  // carried a `userId`, the function would be a lookup service for anybody's
  // phone number with a trip-membership check in the wrong place.
  const withUserId = await fetch(`https://${REF}.supabase.co/functions/v1/contact`, {
    method: 'POST',
    headers: {
      apikey: ANON,
      Authorization: `Bearer ${users.stranger.token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ tripId, userId: users.rider.uid }),
  });
  const injected = await withUserId.json();
  check('still refused with a userId in the body', withUserId.status, 404);
  check('no phone in the body', injected.phone, undefined);

  console.log('\n=== 7. the other party is unreachable without the function ===');
  // The reason the function exists. A rider reading the driver's profile row
  // directly must get nothing, phone or otherwise.
  const direct = await fetch(
    `https://${REF}.supabase.co/rest/v1/profiles?id=eq.${users.driver.uid}&select=phone,full_name`,
    { headers: { apikey: ANON, Authorization: `Bearer ${users.rider.token}` } });
  const rows = await direct.json();
  check('rider cannot read the driver profile', Array.isArray(rows) ? rows.length : -1, 0);
  console.log('    -> so the number genuinely has to come through this function');

  // Added after watching a real driver on an A06: the Call button was disabled
  // with a rider whose phone had been set to nothing, and there was no way to tell
  // from the outside whether the function had failed or whether there was genuinely
  // nobody to call. Those are different things to a driver and they must not look
  // the same.
  console.log('\n=== 8. a rider with no number is an answer, not a failure ===');
  // `profiles.phone` is NOT NULL, so "no number" is the empty string. Setting null
  // here fails the not-null constraint and reports a type error several steps later,
  // a long way from what is being tested.
  await q(`update profiles set phone = '' where id='${users.rider.uid}'`);
  const silent = await ask(tripId, users.driver.token);
  say('HTTP', silent.status);
  check('not a server error', silent.status === 500, false);
  check('and not dialable', silent.body.callable, false);
  check('and no number is invented', silent.body.phone, '');
  console.log('    -> the driver gets a disabled button, which is the truth');
  await q(`update profiles set phone = '0241234567' where id='${users.rider.uid}'`);

  await q(`delete from trips where id='${tripId}'`);
} catch (e) {
  ok = false;
  console.log('  ERROR: ' + e.message);
} finally {
  for (const uid of made) {
    for (const sql of [
      `delete from trips where rider_id='${uid}' or driver_id='${uid}'`,
      `delete from driver_locations where driver_id='${uid}'`,
      `delete from vehicles where owner_id='${uid}'`,
      `delete from profiles where id='${uid}'`,
      `delete from auth.users where id='${uid}'`,
    ]) { try { await q(sql); } catch { /* already gone */ } }
  }
  if (made.length) {
    const left = await q(`select count(*)::text n from profiles where id in (${made.map((u) => `'${u}'`).join(',')})`);
    console.log('\n  cleanup: ' + left[0].n + ' test profiles left');
  }
}
console.log('\n' + (ok ? 'ALL CHECKS PASSED' : 'SOMETHING FAILED'));
process.exit(ok ? 0 : 1);
