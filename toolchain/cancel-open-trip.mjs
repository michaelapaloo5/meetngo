import { readEnvOrFail } from './read-env.mjs';
const admin = readEnvOrFail('toolchain/supabase-admin.env', ['SUPABASE_PROJECT_REF','SUPABASE_ADMIN_TOKEN']);
const sql = async (q) => {
  const r = await fetch('https://api.supabase.com/v1/projects/'+admin.SUPABASE_PROJECT_REF+'/database/query',
    { method:'POST', headers:{Authorization:'Bearer '+admin.SUPABASE_ADMIN_TOKEN,'Content-Type':'application/json'}, body: JSON.stringify({query:q}) });
  const b = await r.json(); if(!r.ok) throw new Error(b.message); return Array.isArray(b)?b:(b.value??b);
};
const open = await sql(`select id, state, driver_id, fare_ghs from trips
  where state not in ('completed','cancelled') order by created_at desc limit 3`);
console.log('open trips:', JSON.stringify(open));
if (!open.length) { console.log('nothing open to cancel'); process.exit(0); }
const id = open[0].id;
// Cancelled with **no driver**, which is the case the finding stage never handled.
const done = await sql(`update trips set state='cancelled', cancelled_at=now()
  where id='${id}' and driver_id is null returning id, state`);
console.log('cancelled:', JSON.stringify(done));
