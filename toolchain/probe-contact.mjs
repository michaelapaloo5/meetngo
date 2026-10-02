// Calls the `contact` Edge Function as a rider and prints the raw body.
//
//   node toolchain/probe-contact.mjs <driverId>
//
// The rider's driver card renders the name but not the car or plate. The data is
// right -- the vehicle is approved, the plate is there, `profiles.vehicle_id`
// points at it -- so the question is what the function actually answers, and the
// only way to know that is to call it.
//
// Uses a throwaway rider on a synthetic trip rather than resetting the signed-in
// rider's password: changing somebody's password to get onto their account is not
// a thing to do without asking.

import { readEnvOrFail } from './read-env.mjs';

const admin = readEnvOrFail('toolchain/supabase-admin.env', ['SUPABASE_PROJECT_REF','SUPABASE_ADMIN_TOKEN']);
const build = readEnvOrFail('toolchain/apk-build.env', ['SB_URL','SB_ANON_KEY']);
const url = build.SB_URL.replace(/\/+$/, '');
const ANON = build.SB_ANON_KEY;

const sql = async (q) => {
  const r = await fetch('https://api.supabase.com/v1/projects/' + admin.SUPABASE_PROJECT_REF + '/database/query',
    { method:'POST', headers:{Authorization:'Bearer '+admin.SUPABASE_ADMIN_TOKEN,'Content-Type':'application/json'}, body: JSON.stringify({query:q}) });
  const b = await r.json(); if(!r.ok) throw new Error(b.message ?? JSON.stringify(b)); return Array.isArray(b)?b:(b.value??[]);
};

const driverId = process.argv[2];
if (!driverId) { console.error('usage: probe-contact.mjs <driverId>'); process.exit(1); }

const stamp = Date.now();
const email = `probe-rider-${stamp}@example.test`;
const signed = await (await fetch(url + '/auth/v1/signup', {
  method:'POST', headers:{apikey:ANON,'Content-Type':'application/json'},
  body: JSON.stringify({email, password:'ProbeRider-123!', data:{full_name:'probe rider'}}),
})).json();
const riderId = (await sql(`select id from auth.users where lower(email)=lower('${email}')`))[0]?.id;
await sql(`update profiles set role='rider', phone='0244321967' where id='${riderId}'`);

const trip = (await sql(`insert into trips (rider_id, driver_id, category, state, pickup, dropoff,
    pickup_point, dropoff_point, distance_km, fare_ghs, is_demo, matched_at)
  values ('${riderId}','${driverId}','standard','matched',
    '{"label":"Osu","point":{"lat":5.5639,"lng":-0.195},"address":"Osu, Accra"}'::jsonb,
    '{"label":"Dansoman","point":{"lat":5.5435,"lng":-0.2646},"address":"Dansoman, Accra"}'::jsonb,
    st_makepoint(5.5639,-0.195), st_makepoint(5.5435,-0.2646), 6.9, 55.20, true, now())
  returning id, vehicle_id`))[0];
console.log(`probe ride ${trip.id}  trips.vehicle_id = ${trip.vehicle_id}`);

const res = await fetch(url + '/functions/v1/contact', {
  method:'POST',
  headers:{apikey:ANON, Authorization:'Bearer '+signed.access_token, 'Content-Type':'application/json'},
  body: JSON.stringify({tripId: trip.id}),
});
const body = await res.json();
console.log(`contact -> HTTP ${res.status}`);
console.log(JSON.stringify(body, null, 2));

await sql(`delete from trips where id='${trip.id}'`);
await sql(`delete from profiles where id='${riderId}'`);
await sql(`delete from auth.users where id='${riderId}'`);