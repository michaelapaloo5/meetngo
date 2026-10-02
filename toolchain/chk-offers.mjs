import { readEnvOrFail } from './read-env.mjs';
const admin = readEnvOrFail('toolchain/supabase-admin.env', ['SUPABASE_PROJECT_REF','SUPABASE_ADMIN_TOKEN']);
const sql = async (q) => {
  const r = await fetch('https://api.supabase.com/v1/projects/'+admin.SUPABASE_PROJECT_REF+'/database/query',
    { method:'POST', headers:{Authorization:'Bearer '+admin.SUPABASE_ADMIN_TOKEN,'Content-Type':'application/json'}, body: JSON.stringify({query:q}) });
  const b = await r.json(); if(!r.ok) throw new Error(b.message); return Array.isArray(b)?b:(b.value??b);
};
const offers = await sql(`select column_name from information_schema.columns where table_name='offers' order by ordinal_position`);
console.log('offers columns:', offers.map(o=>o.column_name).join(', '));
const rows = await sql(`select * from offers order by created_at desc limit 5`);
for (const r of rows) console.log(JSON.stringify(r));
