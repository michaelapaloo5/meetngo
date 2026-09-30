// Who could `match_offers_for_trip` possibly return right now?
//
//   node toolchain/who-can-be-matched.mjs
//
// The category fix is deployed and its own test passes with two fixture drivers.
// That proves the *condition* works. It does not prove a single real driver is
// matchable, because the function requires six things at once and the live data
// satisfies none or one of them. This walks the six and says which are missing,
// so "no drivers are being offered rides" is a fact rather than a mystery.

import { readEnv } from './read-env.mjs';

const env = readEnv('toolchain/supabase-admin.env');
const q = async (sql) => {
  const res = await fetch('https://api.supabase.com/v1/projects/' + env.SUPABASE_PROJECT_REF + '/database/query', {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + env.SUPABASE_ADMIN_TOKEN, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(body.message ?? JSON.stringify(body));
  return Array.isArray(body) ? body : (body.value ?? body);
};

// The same six conditions `match_offers_for_trip` filters on, counted.
const conditions = [
  ["role = 'driver'", "select count(*)::text n from profiles where role='driver'"],
  ["kyc_status = 'approved'", "select count(*)::text n from profiles where role='driver' and kyc_status='approved'"],
  ['an approved vehicle', `select count(*)::text n from profiles d
     join vehicles v on v.owner_id = d.id and v.approved where d.role='driver'`],
  ["availability = 'online'", "select count(*)::text n from profiles where role='driver' and availability='online'"],
  ['a driver_locations row', `select count(*)::text n from profiles d
     where d.role='driver' and exists (select 1 from driver_locations l where l.driver_id = d.id)`],
  ['all of the above together', `select count(*)::text n from profiles d
     join vehicles v on v.owner_id = d.id and v.approved
     where d.role='driver' and d.kyc_status='approved' and d.availability='online'
       and exists (select 1 from driver_locations l where l.driver_id = d.id)`],
];

console.log('=== how many drivers satisfy each condition, cumulatively ===');
for (const [label, sql] of conditions) {
  const rows = await q(sql);
  const n = rows[0]?.n ?? '?';
  const mark = n === '0' ? '  <- nothing here yet' : '';
  console.log('  ' + String(n).padStart(4) + '  ' + label + mark);
}

console.log('\n=== every driver, and which condition it is missing ===');
const drivers = await q(`
  select d.id, d.full_name, d.kyc_status::text as kyc, d.availability::text as avail,
         v.ride_category, coalesce(v.approved, false) as vehicle_approved,
         exists (select 1 from driver_locations l where l.driver_id = d.id) as has_location
  from profiles d
  left join vehicles v on v.owner_id = d.id
  where d.role = 'driver'
  order by d.created_at`);

if (drivers.length === 0) {
  console.log('  (no driver accounts at all)');
}
for (const d of drivers) {
  const missing = [];
  if (d.kyc !== 'approved') missing.push('KYC is ' + d.kyc);
  if (!d.vehicle_approved) missing.push('vehicle not approved');
  if (d.avail !== 'online') missing.push('availability is ' + d.avail);
  if (!d.has_location) missing.push('no location reported');
  console.log('  ' + d.id.slice(0, 8) + '  ' + (d.full_name || '(no name)').padEnd(22)
    + ' sells ' + String(d.ride_category ?? '(no vehicle)').padEnd(9)
    + (missing.length === 0
      ? 'MATCHABLE'
      : 'blocked by: ' + missing.join('; ')));
}

console.log('\n  The one that is a phone-side behaviour and not a database setting is');
console.log('  `availability = online` and the location row: both are written by the');
console.log('  driver app while the app is open. A driver who has finished onboarding');
console.log('  and closed the app is online = offline and has no location, which is');
console.log('  correct -- nobody should be offered a ride they are not there for.');
