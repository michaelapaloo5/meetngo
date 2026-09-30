// The body of guard_profile_update(): which columns it protects, and why the
// Ghana Card ones are not among them.
//
//   node toolchain/show-guard-body.mjs
//
// `what-guards-kyc.mjs` found the answer to "why is kyc_status refused": a
// BEFORE UPDATE trigger named `profiles_update_guard`, calling
// `guard_profile_update()`. So the design is trigger-based column protection, not
// grants -- and the measurement showed three Ghana Card columns slipping past it.
//
// This prints the body so the gap is read rather than guessed at, and lists
// every column the trigger mentions next to every column `authenticated` can
// UPDATE. The intersection is the surface a driver can still change.

import { readEnvOrFail } from './read-env.mjs';

const adminEnv = readEnvOrFail('toolchain/supabase-admin.env', [
  'SUPABASE_PROJECT_REF',
  'SUPABASE_ADMIN_TOKEN',
]);
const ref = adminEnv.SUPABASE_PROJECT_REF;

const q = async (sql) => {
  const res = await fetch('https://api.supabase.com/v1/projects/' + ref + '/database/query', {
    method: 'POST',
    headers: {
      Authorization: 'Bearer ' + adminEnv.SUPABASE_ADMIN_TOKEN,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ query: sql }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(body.message ?? JSON.stringify(body));
  return Array.isArray(body) ? body : (body.value ?? []);
};

const body = await q(`select prosrc from pg_proc where proname = 'guard_profile_update'`);
console.log('=== guard_profile_update() ===\n');
console.log(
  (body[0]?.prosrc ?? '(not found)')
    .split('\n')
    .map((l) => '  ' + l)
    .join('\n'),
);

console.log('\n=== the two lists, side by side ===\n');

const updatable = await q(
  `select column_name from information_schema.role_column_grants
    where table_schema = 'public' and table_name = 'profiles'
      and grantee = 'authenticated' and privilege_type = 'UPDATE' order by 1`,
);
const src = body[0]?.prosrc ?? '';
const mentions = (c) => src.includes(c);

// "Guarded" is inferred from the trigger text, which is a heuristic and is
// labelled as one. The authoritative answer is the live probe in
// `who-actually-writes.mjs`, and this table exists only to point at it.
console.log('  ' + 'column'.padEnd(24) + 'in the trigger text?');
const unguarded = [];
for (const c of updatable) {
  const inText = mentions(c.column_name);
  if (!inText) unguarded.push(c.column_name);
  console.log('  ' + pad(c.column_name, 24) + (inText ? 'yes' : 'no  <-- not mentioned'));
}
function pad(s, n) {
  return String(s).padEnd(n);
}

console.log('\n=== columns the trigger text does not mention ===\n');
console.log('  ' + (unguarded.length === 0 ? '(none)' : unguarded.join('\n  ')));
console.log(
  '\n  These are writable by a signed-in driver on their own row, because the\n' +
    '  `update own profile` policy scopes by row and carries no with_check, and\n' +
    '  the trigger does not mention them. Confirmed live, not inferred, in\n' +
    '  who-actually-writes.mjs.',
);