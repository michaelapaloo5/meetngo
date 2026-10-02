import { readEnvOrFail } from './read-env.mjs';
const admin = readEnvOrFail('toolchain/supabase-admin.env', ['SUPABASE_PROJECT_REF','SUPABASE_ADMIN_TOKEN']);
const sql = async (q) => {
  const r = await fetch('https://api.supabase.com/v1/projects/'+admin.SUPABASE_PROJECT_REF+'/database/query',
    { method:'POST', headers:{Authorization:'Bearer '+admin.SUPABASE_ADMIN_TOKEN,'Content-Type':'application/json'}, body: JSON.stringify({query:q}) });
  const b = await r.json(); if(!r.ok) throw new Error(b.message); return Array.isArray(b)?b:(b.value??b);
};
const rows = await sql(`select sp.id, sp.label, sp.address, sp.point, p.full_name as rider,
  (sp.point->>'lat')::float as lat, (sp.point->>'lng')::float as lng
  from saved_places sp join profiles p on p.id = sp.rider_id
  order by sp.created_at desc limit 5`);
console.log('saved_places rows:', rows.length);
for (const r of rows) {
  console.log('  rider    ', r.rider);
  console.log('  label    ', JSON.stringify(r.label));
  console.log('  address  ', JSON.stringify(r.address));
  console.log('  point    ', r.lat, r.lng, '| label looks like a coordinate?', /^-?\d+\.\d+,\s*-?\d+\.\d+$/.test(r.label));
  console.log();
}
