// What stops a driver writing their own `kyc_status`, and what does not stop
// them rewriting their Ghana Card details.
//
//   node toolchain/what-guards-kyc.mjs
//
// Measured result from `who-actually-writes.mjs`:
//
//   kyc_status          refused   <- something is guarding this
//   approved_at         refused
//   approved_by         refused
//   liveness_passed_at  refused
//   ghana_card_number   ALLOWED   <- nothing is guarding this
//   ghana_card_dob      ALLOWED
//   ghana_card_expiry   ALLOWED
//
// `kyc_status` having a column-level UPDATE grant and still being refused on the
// wire means the guard is not the grant -- it is a trigger, and finding it tells
// us both what the intended design is and how to bring the Ghana Card columns
// under the same protection.

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

const pad = (s, n) => String(s).padEnd(n);

console.log('=== triggers on profiles ===\n');
const triggers = await q(
  `select t.tgname, p.proname as function, t.tgenabled,
          pg_get_triggerdef(t.oid) as def
     from pg_trigger t
     join pg_proc p on p.oid = t.tgfoid
    where t.tgrelid = 'public.profiles'::regclass and not t.tgisinternal
    order by t.tgname`,
);
if (triggers.length === 0) console.log('  (none)');
for (const t of triggers) {
  console.log('  ' + pad(t.tgname, 34) + 'enabled=' + t.tgenabled + '  via ' + t.function);
  console.log('    ' + t.def);
}

console.log('\n=== rules on profiles ===\n');
const rules = await q(
  `select rulename, definition from pg_rules
    where schemaname = 'public' and tablename = 'profiles'`,
);
if (rules.length === 0) console.log('  (none)');
for (const r of rules) console.log('  ' + r.rulename + ': ' + (r.definition ?? '').slice(0, 200));

console.log('\n=== policies on profiles, with both halves ===\n');
const policies = await q(
  `select policyname, cmd, roles::text as roles, qual, with_check
     from pg_policies where schemaname = 'public' and tablename = 'profiles'
    order by cmd, policyname`,
);
for (const p of policies) {
  console.log(`  ${p.policyname}  [${p.cmd}]  roles=${p.roles}`);
  // The `with_check` half is the one that decides what a row may look like
  // *after* the write. A policy with a `using` and no `with_check` accepts any
  // resulting row, which on an UPDATE means the driver can change any column.
  console.log('    using:     ' + (p.qual ?? '(none)'));
  console.log('    with_check: ' + (p.with_check ?? '(none)  <-- no restriction on the new row'));
}

console.log('\n=== functions that mention profiles or kyc_status ===\n');
const fns = await q(
  `select n.nspname as schema, p.proname, pg_get_function_identity_arguments(p.oid) as args
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and (p.prosrc like '%kyc_status%' or p.prosrc like '%profiles%')
    order by p.proname`,
);
if (fns.length === 0) console.log('  (none)');
for (const f of fns) console.log(`  ${f.schema}.${f.proname}(${f.args})`);

console.log('\n=== how the app writes the Ghana Card fields ===\n');
console.log('  Read from the repository rather than from the schema, because the');
console.log('  question is not "can it" but "does the app do it".');