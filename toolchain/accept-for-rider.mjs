// Puts a real driver in front of a ride the rider has already booked, by calling
// the same `offers` Edge Function the driver's Accept button calls, so the rider's
// tracking screen can be looked at.
//
//   node toolchain/accept-for-rider.mjs
//
// Why a throwaway driver rather than a password reset: the handset is signed in
// as a real driver and changing somebody's password to get onto their account is
// not a thing to do without asking. Nothing about the rider's driver card depends
// on whose account it is.
//
// Writes real rows, all tagged `accept-check`, and removes the driver at the end
// while leaving the ride live for the handset.

import { readEnvOrFail } from './read-env.mjs';

const admin = readEnvOrFail('toolchain/supabase-admin.env', ['SUPABASE_PROJECT_REF','SUPABASE_ADMIN_TOKEN']);
const build = readEnvOrFail('toolchain/apk-build.env', ['SB_URL','SB_ANON_KEY']);
const url = build.SB_URL.replace(/\/+$/, '');
const ANON = build.SB_ANON_KEY;
const MARK = 'accept-check';
const PASSWORD = 'AcceptCheck-123!';

const sql = async (q) => {
  const r = await fetch('https://api.supabase.com/v1/projects/' + admin.SUPABASE_PROJECT_REF + '/database/query',
    { method:'POST', headers:{Authorization:'Bearer '+admin.SUPABASE_ADMIN_TOKEN,'Content-Type':'application/json'}, body: JSON.stringify({query:q}) });
  const b = await r.json(); if(!r.ok) throw new Error(b.message ?? JSON.stringify(b)); return Array.isArray(b)?b:(b.value??[]);
};

const trip = (await sql(`select t.id, t.fare_ghs, t.category, t.state, p.full_name as rider
  from trips t join profiles p on p.id = t.rider_id
  where t.state = 'requested' and t.driver_id is null
  order by t.created_at desc limit 1`))[0];
if (!trip) { console.error('no ride waiting for a driver; book one on the handset first'); process.exit(1); }
console.log(`ride ${trip.id}  state=${trip.state}  fare=${trip.fare_ghs}  rider=${trip.rider}`);

// `vehicles.plate` is globally unique, so the plate has to be unique per run.
// A fixed one meant the second run of this script died on the constraint before it
// accepted anything at all -- and the failure looked like "the driver never
// accepted" rather than "the plate was taken", which is how it cost a cycle.
const PLATE = `${MARK.toUpperCase()}-${Date.now() % 100000}`;
const email = `${MARK}-driver-${Date.now()}@example.test`;
const signed = await (await fetch(url + '/auth/v1/signup', {
  method:'POST', headers:{apikey:ANON,'Content-Type':'application/json'},
  body: JSON.stringify({email, password:PASSWORD, data:{full_name:`${MARK} driver`}}),
})).json();
if (!signed.access_token) throw new Error('signup: ' + JSON.stringify(signed).slice(0,200));
const driverId = (await sql(`select id from auth.users where lower(email)=lower('${email}')`))[0]?.id;
if (!driverId) throw new Error('signed up but absent from auth.users');

await sql(`update profiles set role='driver', kyc_status='approved', availability='online',
  phone='0200000001', full_name='${MARK} driver' where id='${driverId}'`);
const vehicle = (await sql(`insert into vehicles (owner_id, vehicle_category, make, model, plate, seats, approved, ride_category)
  values ('${driverId}','sedan','Toyota','Corolla','${PLATE}',4,true,'${trip.category}') returning id`))[0];
await sql(`update profiles set vehicle_id='${vehicle.id}' where id='${driverId}'`);
await sql(`insert into driver_locations (driver_id, point, heading)
  values ('${driverId}', st_makepoint(5.5639,-0.1950), 0)`);

const offer = (await sql(`insert into offers (trip_id, driver_id, fare_ghs, pickup_distance_km, state, expires_at)
  values ('${trip.id}','${driverId}','${trip.fare_ghs}',0.4,'pending', now() + interval '5 minutes')
  returning id, state`))[0];
console.log(`offer ${offer.id} ${offer.state}`);

const res = await fetch(url + '/functions/v1/offers', {
  method:'POST',
  headers:{apikey:ANON, Authorization:'Bearer '+signed.access_token, 'Content-Type':'application/json'},
  body: JSON.stringify({offerId: offer.id, action: 'accept'}),
});
console.log(`accept -> HTTP ${res.status}`);
console.log('  ' + (await res.text()).slice(0, 300));

const after = (await sql(`select state, driver_id from trips where id='${trip.id}'`))[0];
console.log(`ride is now ${after.state} with driver ${after.driver_id}`);
const who = (await sql(`select p.full_name, p.phone, p.kyc_status, v.make, v.model, v.plate
  from profiles p left join vehicles v on v.id = p.vehicle_id where p.id = '${after.driver_id}'`))[0];
console.log('  driver:', JSON.stringify(who));

// **Nothing is cleaned up while the rider is looking at the screen.**
//
// The first run deleted the driver's vehicle, the profile and the auth row the
// moment the accept returned, and the rider's card then correctly showed no car
// and no plate -- because by the time the app asked, there was no car. That looked
// like "the details do not appear" and was entirely my teardown.
//
// So this leaves everything, prints the ids, and has a `--teardown` for after.
// Deleting the profile is also refused by the trips foreign key anyway, so the
// cleanup was never as complete as it looked.
console.log(`
still live so the handset can look:
  driver id    ${driverId}
  vehicle id   ${vehicle.id}
  ride id      ${trip.id}

when finished:  node toolchain/accept-for-rider.mjs --teardown`);
if (process.argv.includes('--teardown')) {
  const r = (await sql(`select id from trips where id='${trip.id}'`))[0];
  if (r) await sql(`update trips set state='cancelled', cancelled_at=now() where id='${trip.id}'`);
  await sql(`delete from offers where driver_id='${driverId}'`);
  await sql(`delete from driver_locations where driver_id='${driverId}'`);
  await sql(`delete from vehicles where owner_id='${driverId}'`);
  await sql(`delete from profiles where id='${driverId}'`);
  await sql(`delete from auth.users where id='${driverId}'`);
  console.log('torn down');
}