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
const q = async (sql, label) => {
  const r = await fetch(MGMT, { method:'POST', headers:h, body: JSON.stringify({ query: sql }) });
  const b = await r.json();
  const okFlag = r.ok;
  console.log((okFlag ? 'OK   ' : 'FAIL ') + label + (okFlag ? '' : ' :: ' + (b.message ?? JSON.stringify(b)).slice(0,160)));
  return okFlag;
};
const sql = readFileSync('supabase/migrations/20260930000011_saved_places_scheduled_and_vehicle.sql','utf8');
const ok = await q(sql, 'whole migration as one multi-statement query');
if (!ok) process.exit(1);