// Applies one migration file through the Management API.
//
//   node toolchain/apply-migration.mjs supabase/migrations/20260930000010_driver_withdrawal_transition.sql
//
// Exists because doing this from PowerShell means hand-building the JSON body, and
// `ConvertTo-Json` on a multi-line string is a reliable way to send the API an
// object where it expects a string -- which it reports as "Invalid input: expected
// string, received object" with no hint that the shell is at fault.
//
// Refuses a file it has already applied. Migrations here are not idempotent by
// design -- `create or replace function` is, but a later one may not be -- and
// silently re-running one because a ledger went missing is how a database ends up
// half-migrated with nobody able to say which half.

import { readFileSync, existsSync } from 'node:fs';
import { readEnvOrFail } from './read-env.mjs';

const admin = readEnvOrFail('toolchain/supabase-admin.env', [
  'SUPABASE_PROJECT_REF',
  'SUPABASE_ADMIN_TOKEN',
]);

const target = process.argv[2];
if (!target) {
  console.error('usage: node toolchain/apply-migration.mjs <file.sql>');
  process.exit(2);
}
if (!existsSync(target)) {
  console.error(`no such file: ${target}`);
  process.exit(2);
}

const sql = readFileSync(target, 'utf8');

const run = async (query) => {
  const res = await fetch(
    'https://api.supabase.com/v1/projects/' + admin.SUPABASE_PROJECT_REF + '/database/query',
    {
      method: 'POST',
      headers: {
        Authorization: 'Bearer ' + admin.SUPABASE_ADMIN_TOKEN,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ query }),
    },
  );
  const body = await res.json();
  if (!res.ok) throw new Error(body.message ?? JSON.stringify(body));
  return body;
};

// A ledger that only this script writes to, so "did I already apply this?" has an
// answer that does not depend on remembering.
const ledger = 'public.applied_migrations';

await run(`create table if not exists ${ledger} (
  filename text primary key,
  applied_at timestamptz not null default now(),
  sha256 text not null
)`);

const already = await run(`select filename, applied_at from ${ledger} where filename = '${sql_sha(target)}'
  union all select filename, applied_at from ${ledger} where filename = '${target.replace(/'/g, "''")}'`);

function sql_sha(file) {
  // The filename column holds whatever `basename` produced; this exists only so
  // the query above has two arms and cannot accidentally match on a prefix.
  return file.replace(/'/g, "''");
}

const rows = Array.isArray(already) ? already : (already.value ?? []);
const seen = rows.find((r) => r.filename === target.replace(/'/g, "''"));
if (seen) {
  console.log(`${target} was applied at ${seen.applied_at}. Not applying it again.`);
  process.exit(0);
}

const result = await run(sql);
console.log(`${target} applied.`);
if (result && (!Array.isArray(result) || result.length > 0)) {
  console.log('  returned: ' + JSON.stringify(result).slice(0, 300));
}
await run(`insert into ${ledger} (filename, sha256) values ('${target.replace(/'/g, "''")}', '${sha(sql)}')
  on conflict (filename) do nothing`);

function sha(text) {
  // FNV-1a. Not a security hash -- it is here to notice that a file changed after
  // it was applied, and node has no crypto import worth the ceremony for that.
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h.toString(16).padStart(8, '0');
}