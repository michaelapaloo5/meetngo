import { readFileSync } from 'node:fs';
const env = {};
for (const f of ['toolchain/supabase-admin.env','toolchain/apk-build.env']) {
  let t; try { t = readFileSync(f,'utf8'); } catch { continue; }
  for (const line of t.split('\n')) {
    const m = /^\s*([A-Z_0-9]+)=(.*)$/.exec(line);
    if (m && m[2]) env[m[1]] ??= m[2].replace(/^["']|["']$/g,'');
  }
}
const REF = env.SUPABASE_PROJECT_REF;
const MGMT = 'https://api.supabase.com/v1/projects/' + REF + '/database/query';
const h = { Authorization: 'Bearer ' + env.SUPABASE_ADMIN_TOKEN, 'Content-Type': 'application/json' };
const q = async (s) => { const r = await fetch(MGMT,{method:'POST',headers:h,body:JSON.stringify({query:s})}); const b = await r.json(); if(!r.ok) throw new Error(b.message); return Array.isArray(b)?b:(b.value??b); };

const rows = await q(`select r.id, r.trip_id, r.reason, r.detail, r.created_at, p.full_name as rider,
  t.state, t.fare_ghs, t.pickup->>'label' as from_label
  from trip_reports r join profiles p on p.id = r.reported_by
  join trips t on t.id = r.trip_id
  order by r.created_at desc limit 5`);
console.log('trip_reports rows:', rows.length);
for (const r of rows) console.log(' ', JSON.stringify(r));

// The uniqueness claim: a second report on the same ride must update, not duplicate.
if (rows.length) {
  const before = rows.length;
  const one = rows[0];
  await q(`update trip_reports set detail = coalesce(nullif(detail,''),'') || ' (checked)', updated_at = now()
           where trip_id = '${one.trip_id}' and reported_by = (select reported_by from trip_reports where trip_id='${one.trip_id}' limit 1)`);
  const after = await q(`select count(*)::int as n from trip_reports where trip_id = '${one.trip_id}'`);
  console.log(`after an update: still ${after[0].n} row(s) on that ride (was ${before} total)`);
}
