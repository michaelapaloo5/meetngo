import { readEnvOrFail } from './read-env.mjs';
const admin = readEnvOrFail('toolchain/supabase-admin.env', ['SUPABASE_PROJECT_REF','SUPABASE_ADMIN_TOKEN']);
const sql = async (q) => {
  const r = await fetch('https://api.supabase.com/v1/projects/'+admin.SUPABASE_PROJECT_REF+'/database/query',
    { method:'POST', headers:{Authorization:'Bearer '+admin.SUPABASE_ADMIN_TOKEN,'Content-Type':'application/json'}, body: JSON.stringify({query:q}) });
  const b = await r.json(); if(!r.ok) return {err:b.message}; return Array.isArray(b)?b:(b.value??b);
};
console.log(JSON.stringify(await sql(`select v.id, v.owner_id, v.make, v.model, v.plate, v.approved, v.ride_category, p.vehicle_id, p.full_name
  from profiles p left join vehicles v on v.owner_id = p.id where p.id='205f573e-0310-4908-889a-a5c752a66853'`), null, 1));
console.log('trip category:', JSON.stringify(await sql(`select id, category, state from trips where id='476e9e91-2a22-4042-bbbb-9dfabe1cc9e1'`)));
