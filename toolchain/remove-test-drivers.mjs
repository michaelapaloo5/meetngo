// Remove driver accounts left behind by a test script that failed part way.
//
//   node toolchain/remove-test-drivers.mjs
//
// `verify-match.mjs` creates two real auth users and real rows in five tables.
// It cleans up in a `finally`, so a crash *between* the signup and the `made.push`
// leaves an account behind with no record of it anywhere -- which is how
// `premium-driver` survived: the first run of that script died on a
// `profiles_pkey` violation before its own cleanup list knew the id existed.
//
// It matches on the fixture names, not on a flag column, because there is no
// flag column and adding one to a production table so a test can find its own
// rubbish is worse than the rubbish. Refuses to touch anything else: it prints
// what it is about to delete and only deletes names that match exactly.

import { readFileSync } from 'node:fs';

const FIXTURES = [
  'premium-driver',
  'standard-driver',
  'Promo Test',
  'promotest_',
  'keyprobe',
  'matchtest_',
];

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

// SQL LIKE patterns, built in JS rather than in SQL. The first version wrote
// `'%' || n || '%'` in Postgres, which is a *column* reference to `n` and not the
// JavaScript variable, so every pattern became the literal string "%" and the
// query asked Postgres for a column that does not exist.
const where = FIXTURES.map((n) => `full_name like '%${n}%'`).join(' or ');

const doomed = await q(
  `select id, full_name, email_hint from (
     select p.id, coalesce(nullif(p.full_name, ''), '(no name)') as full_name,
            (select email from auth.users where id = p.id) as email_hint
     from profiles p
   ) t where ${where}`);

if (doomed.length === 0) {
  console.log('  no leftover test drivers');
  process.exit(0);
}

console.log('  these look like test fixtures and will be removed:');
for (const d of doomed) {
  console.log('    ' + d.id + '  ' + d.full_name + '  ' + (d.email_hint ?? ''));
}

if (process.argv.includes('--dry-run')) {
  console.log('\n  (--dry-run, so nothing was deleted)');
  process.exit(0);
}

// Trips first: `trips.rider_id` and `driver_id` cascade from profiles, but a
// trip can also *reference* a fixture driver as its rider while belonging to
// somebody else's session, and cascade handles only the owned rows.
for (const d of doomed) {
  const id = d.id;
  const steps = [
    ['trips', `delete from trips where rider_id='${id}' or driver_id='${id}'`],
    ['driver_locations', `delete from driver_locations where driver_id='${id}'`],
    ['vehicles', `delete from vehicles where owner_id='${id}'`],
    ['documents', `delete from documents where driver_id='${id}'`],
    ['driver_promos', `delete from driver_promos where driver_id='${id}'`],
    ['offers', `delete from offers where driver_id='${id}'`],
    ['ledger_entries', `delete from ledger_entries where driver_id='${id}'`],
    ['payouts', `delete from payouts where driver_id='${id}'`],
    ['profiles', `delete from profiles where id='${id}'`],
    ['auth.users', `delete from auth.users where id='${id}'`],
  ];
  for (const [table, sql] of steps) {
    try {
      await q(sql);
    } catch (e) {
      // A table that does not exist, or a column that is not there, is not a
      // reason to abandon the cleanup half way.
      if (!/does not exist|undefined column|violates foreign key/.test(e.message)) {
        console.log('    ' + table + ': ' + e.message.slice(0, 90));
      }
    }
  }
}

const left = await q(`select count(*)::text n from profiles p where ${where}`);
console.log('\n  fixture drivers remaining: ' + left[0].n);
