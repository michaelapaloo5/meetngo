import { readFileSync } from 'node:fs';
const env = {};
for (const f of ['toolchain/supabase-admin.env','toolchain/apk-build.env']) {
  let t; try { t = readFileSync(f,'utf8'); } catch { continue; }
  for (const line of t.split('\n')) {
    const m = /^\s*([A-Z_0-9]+)=(.*)$/.exec(line);
    if (m && m[2]) env[m[1]] ??= m[2].replace(/^["']|["']$/g,'');
  }
}
const MGMT = 'https://api.supabase.com/v1/projects/' + env.SUPABASE_PROJECT_REF + '/database/query';
const h = { Authorization: 'Bearer ' + env.SUPABASE_ADMIN_TOKEN, 'Content-Type': 'application/json' };
const q = async (s) => { const r = await fetch(MGMT,{method:'POST',headers:h,body:JSON.stringify({query:s})}); const b = await r.json(); if(!r.ok) throw new Error(b.message); return Array.isArray(b)?b:(b.value??b); };

const checks = [
  ['saved_places table exists', `select to_regclass('public.saved_places') is not null as ok`],
  ['RLS on saved_places', `select relrowsecurity from pg_class where oid = 'public.saved_places'::regclass`],
  ['saved_places policies', `select count(*)::int as n from pg_policies where tablename = 'saved_places'`],
  ['unique index exists', `select count(*)::int as n from pg_indexes where indexname = 'saved_places_rider_label_uniq'`],
  ['scheduled_for column', `select count(*)::int as n from information_schema.columns where table_name='trips' and column_name='scheduled_for'`],
  ['vehicle trigger exists', `select count(*)::int as n from pg_trigger where tgname = 'trips_take_driver_vehicle' and not tgisinternal`],
  ['offerable function works', `select trips_is_offerable('requested', null) as now_ok, trips_is_offerable('requested', now() + interval '1 hour') as future_no, trips_is_offerable('ongoing', null) as not_requested_no`],
  ['trips backfilled with a vehicle', `select count(*)::int as n from trips where driver_id is not null and vehicle_id is not null`],
];
let pass = 0;
for (const [label, sql] of checks) {
  const rows = await q(sql);
  const v = JSON.stringify(rows[0]);
  console.log('  ' + label.padEnd(34) + v);
}
