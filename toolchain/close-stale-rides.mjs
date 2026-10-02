import { readEnvOrFail } from './read-env.mjs';
const admin = readEnvOrFail('toolchain/supabase-admin.env', ['SUPABASE_PROJECT_REF','SUPABASE_ADMIN_TOKEN']);
const sql = async (q) => {
  const r = await fetch('https://api.supabase.com/v1/projects/'+admin.SUPABASE_PROJECT_REF+'/database/query',
    { method:'POST', headers:{Authorization:'Bearer '+admin.SUPABASE_ADMIN_TOKEN,'Content-Type':'application/json'}, body: JSON.stringify({query:q}) });
  const b = await r.json(); if(!r.ok) throw new Error(b.message); return Array.isArray(b)?b:(b.value??b);
};
// Two rides left `requested` from earlier verification runs. They are not real
// rides and they are what `activeTrip` hands the app when the ride it booked is
// gone -- which is how this bug reproduced twice.
const stale = await sql(`select id, fare_ghs, created_at from trips
  where state='requested' and driver_id is null and id <> '59373703-b70e-4c70-945d-a5dc69944a55'`);
console.log('stale open trips:', JSON.stringify(stale));
const gone = await sql(`update trips set state='cancelled', cancelled_at=now()
  where state='requested' and driver_id is null and id <> '59373703-b70e-4c70-945d-a5dc69944a55' returning id`);
console.log('closed:', gone.length);
const left = await sql(`select id, state, driver_id from trips where state not in ('completed','cancelled')`);
console.log('open rides now:', JSON.stringify(left));
