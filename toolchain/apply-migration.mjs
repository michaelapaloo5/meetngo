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
// The file to apply comes from the command line.
//
// It used to be hardcoded to `20260930000012_trip_reports.sql`, which meant
// passing any other migration was silently ignored and that one was re-applied
// instead -- an idempotent no-op that reported OK, so applying a new migration
// looked like it had worked when it had done nothing at all.
const target = process.argv[2];
if (!target) {
  console.error('usage: node toolchain/apply-migration.mjs <path-to-migration.sql>');
  process.exit(2);
}
let sql;
try {
  sql = readFileSync(target, 'utf8');
} catch (e) {
  console.error('cannot read ' + target + ': ' + e.code);
  process.exit(2);
}
const ok = await q(sql, 'whole migration as one multi-statement query');
if (!ok) process.exit(1);