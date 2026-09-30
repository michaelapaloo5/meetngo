// What does signing up already create?
//
//   node toolchain/probe-signup.mjs
//
// `verify-match.mjs` tried to insert a `profiles` row for a user it had just
// signed up, and got `duplicate key value violates unique constraint
// "profiles_pkey"`. So something creates that row on signup -- most likely a
// trigger on `auth.users`. This prints it, because the test fixture has to
// either use it or not fight it, and guessing is how the previous run of that
// script died.

import { readFileSync } from 'node:fs';

const env = {};
for (const line of readFileSync('toolchain/supabase-admin.env', 'utf8').split('\n')) {
  const m = /^\s*([A-Z_0-9]+)=(.*)$/.exec(line);
  if (m) env[m[1]] = m[2];
}
const q = async (sql) => {
  const res = await fetch('https://api.supabase.com/v1/projects/' + env.SUPABASE_PROJECT_REF + '/database/query', {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + env.SUPABASE_ADMIN_TOKEN, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(body.message ?? JSON.stringify(body));
  return Array.isArray(body) ? body : (body.value ?? body);
};

console.log('=== triggers on auth.users ===');
for (const t of await q("select tgname, pg_get_triggerdef(oid) as def from pg_trigger where tgrelid='auth.users'::regclass and not tgisinternal")) {
  console.log('  ' + t.tgname);
  console.log('    ' + t.def);
}

console.log('\n=== what one such function does ===');
const names = await q("select p.proname from pg_trigger t join pg_proc p on p.oid = t.tgfoid where t.tgrelid='auth.users'::regclass and not t.tgisinternal");
for (const n of names) {
  const body = await q(`select prosrc from pg_proc where proname = '${n.proname}'`);
  console.log('  --- ' + n.proname);
  console.log('    ' + String(body[0]?.prosrc ?? '').split('\n').map((l) => '    ' + l.trim()).join('\n').trim());
}

console.log('\n=== the columns a signup-created profile gets ===');
const cols = await q("select column_name, column_default from information_schema.columns where table_name = 'profiles' order by ordinal_position");
for (const c of cols) console.log('  ' + c.column_name.padEnd(24) + (c.column_default ?? ''));
