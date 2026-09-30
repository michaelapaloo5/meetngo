// Which PostgreSQL role actually performs a PostgREST write, and what it is
// allowed to write.
//
//   node toolchain/who-actually-writes.mjs
//
// This exists because the obvious reading of the grants is wrong, and wrong in a
// way that hides a real problem.
//
// What `information_schema.role_table_grants` says about `profiles`:
//
//   anon            DELETE, REFERENCES, SELECT, TRIGGER, TRUNCATE
//   authenticated   DELETE, REFERENCES, SELECT, TRIGGER, TRUNCATE
//   postgres        ... INSERT, ... UPDATE
//   service_role    ... INSERT, ... UPDATE
//
// `authenticated` has no UPDATE on the table. `has_table_privilege` agrees. A
// driver, it seems, cannot write their own profile -- yet a live PATCH through
// PostgREST with the anon key writes the row and succeeds. So something in that
// story is wrong, and guessing which thing is how a security question gets
// answered wrongly.
//
// The answer is column-level grants, which neither of those two views reports:
//
//   `has_table_privilege(role, 'profiles', 'UPDATE')` asks whether the role holds
//   UPDATE on *every* column. A role holding `UPDATE (phone)` alone answers false.
//   `role_table_grants` lists table-level grants only.
//
// So this measures instead of reasoning, in three parts: role attributes, every
// privilege path to UPDATE, and then a live session that actually attempts each
// column. The third part is the only one that can be trusted, and it is the one
// that changes what has to happen before launch.
//
// The columns that matter are the employee-only ones. If a driver session can
// write `kyc_status`, then `kyc_status = 'approved'` is a self-approval, and the
// whole approval workflow -- employees pressing Approve or Decline, with no
// database access -- is advisory rather than enforced.

import { readEnvOrFail } from './read-env.mjs';

const adminEnv = readEnvOrFail('toolchain/supabase-admin.env', [
  'SUPABASE_PROJECT_REF',
  'SUPABASE_ADMIN_TOKEN',
]);
const buildEnv = readEnvOrFail('toolchain/apk-build.env', ['SB_URL', 'SB_ANON_KEY']);
const ref = adminEnv.SUPABASE_PROJECT_REF;
const url = buildEnv.SB_URL.replace(/\/+$/, '');
const ANON = buildEnv.SB_ANON_KEY;

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

// ------------------------------------------------------------- 1. role shape
console.log('=== 1. role attributes ===\n');
const roles = await q(
  `select rolname, rolinherit, rolcanlogin, rolbypassrls
     from pg_roles
    where rolname in ('anon','authenticated','authenticator','service_role','postgres')
    order by rolname`,
);
console.log('  ' + pad('role', 15) + pad('inherit', 9) + pad('login', 8) + 'bypassrls');
for (const r of roles) {
  console.log(
    '  ' + pad(r.rolname, 15) + pad(r.rolinherit, 9) + pad(r.rolcanlogin, 8) + r.rolbypassrls,
  );
}
console.log(
  '\n  `authenticator` has rolinherit = false, which is why it answers false to\n' +
    '  has_table_privilege despite being a member of service_role. Membership alone\n' +
    '  is not access when the member role does not inherit.',
);

// ------------------------------------------------------- 2. privilege paths
console.log('\n=== 2a. table-level UPDATE grants on profiles ===\n');
const paths = await q(
  `select grantee from information_schema.role_table_grants
    where table_schema = 'public' and table_name = 'profiles'
      and privilege_type = 'UPDATE' order by grantee`,
);
if (paths.length === 0) console.log('  (none)');
for (const p of paths) console.log('  ' + p.grantee);

const pub = await q(`select has_table_privilege('public','public.profiles','UPDATE')::text as v`);
console.log('\n  PUBLIC has UPDATE: ' + pub[0].v);

const defacls = await q(
  `select r.rolname as granted_to
     from pg_default_acl d
     join pg_roles r on r.oid = d.defaclrole
     join pg_namespace n on n.oid = d.defaclnamespace
    where d.defaclobjtype = 'r' and n.nspname = 'public' order by 1`,
);
console.log('\n=== 2b. default ACLs for new public tables ===\n');
if (defacls.length === 0) console.log('  (none)');
for (const d of defacls) console.log('  new tables also grant to ' + d.granted_to);

const total = (
  await q(`select count(*)::int as n from information_schema.columns
            where table_schema = 'public' and table_name = 'profiles'`)
)[0].n;

console.log('\n=== 2c. column-level grants on profiles ===\n');
const cols = await q(
  `select grantee, privilege_type, count(*)::int as columns
     from information_schema.role_column_grants
    where table_schema = 'public' and table_name = 'profiles'
      and grantee in ('anon','authenticated','service_role')
    group by grantee, privilege_type
    order by grantee, privilege_type`,
);
console.log(`  profiles has ${total} columns.`);
for (const c of cols) {
  console.log(
    `  ${pad(c.grantee, 15)}${pad(c.privilege_type, 11)}${c.columns}/${total} columns` +
      (c.columns === total ? '   (all of them)' : ''),
  );
}

console.log('\n=== 2d. every column `authenticated` may UPDATE ===\n');
const authUpd = await q(
  `select column_name from information_schema.role_column_grants
    where table_schema = 'public' and table_name = 'profiles'
      and grantee = 'authenticated' and privilege_type = 'UPDATE' order by 1`,
);
if (authUpd.length === 0) console.log('  (none)');
for (const c of authUpd) console.log('  ' + c.column_name);
console.log(
  '\n  Read this list against the columns the app must not let a driver touch.' +
    '\n  `kyc_status` on it means self-approval is one HTTP request away.',
);

// --------------------------------------------------- 3. what a session can do
console.log('\n=== 3. a real driver session, writing each column ===\n');

const session = await fetch(url + '/auth/v1/signup', {
  method: 'POST',
  headers: { apikey: ANON, 'Content-Type': 'application/json' },
  body: JSON.stringify({
    email: 'who-writes-probe-' + Date.now() + '@example.test',
    password: 'Probe-9' + Math.random().toString(36).slice(2, 10),
    data: { full_name: 'Who Writes Probe' },
  }),
});
const sessionBody = await session.json();
if (!sessionBody.access_token) {
  console.log('  could not create a probe session: ' + JSON.stringify(sessionBody).slice(0, 200));
  process.exit(1);
}
const token = sessionBody.access_token;
const mine = sessionBody.user.id;
console.log('  probe user ' + mine.slice(0, 8) + ' created\n');

const patch = async (filter, body, useJwt = true) => {
  const headers = { apikey: ANON, 'Content-Type': 'application/json' };
  if (useJwt) headers.Authorization = 'Bearer ' + token;
  const res = await fetch(`${url}/rest/v1/profiles?id=eq.${filter}`, {
    method: 'PATCH',
    headers: { ...headers, Prefer: 'return=representation' },
    body: JSON.stringify(body),
  });
  return { status: res.status, text: await res.text() };
};

// The gate's write, first: it has to work or the feature is dead on arrival.
const gateWrite = await patch(mine, { phone: '0241234567' });
const gateOk = gateWrite.status < 300 && gateWrite.text.includes('"id"');
console.log(`  own phone            ${(gateOk ? 'ALLOWED' : 'refused ')}   ${gateWrite.status}   the gate depends on this`);

// And with no JWT at all, to show the anon key alone gets nothing.
const noJwt = await patch(mine, { phone: '0550000000' }, false);
console.log(`  own phone, no JWT    ${noJwt.status < 300 ? 'ALLOWED' : 'refused '}   ${noJwt.status}   the apikey alone must be useless`);

console.log('');

const EMPLOYEE_ONLY = [
  'ghana_card_number',
  'ghana_card_dob',
  'ghana_card_expiry',
  'kyc_status',
  'approved_at',
  'approved_by',
  'liveness_passed_at',
  'rating',
];
const results = [];
for (const column of EMPLOYEE_ONLY) {
  const value = column === 'rating' ? 1 : 'probe-value';
  const r = await patch(mine, { [column]: value });
  const allowed = r.status < 300 && r.text.includes('"id"');
  results.push({ column, allowed, status: r.status });
  console.log(
    `  ${pad(column, 22)}${allowed ? 'ALLOWED' : 'refused '}` +
      `${allowed ? '   *** THIS MUST NOT BE ALLOWED ***' : ''}`,
  );
}

// Put the probe row's phone back before it is deleted, so nothing is left odd.
await patch(mine, { phone: '0241234567' });

const writable = results.filter((r) => r.allowed).map((r) => r.column);

console.log('\n=== verdict ===\n');
console.log('  a driver can save their own phone:  ' + (gateOk ? 'YES' : 'NO -- the gate is dead'));
console.log('  the anon key alone can write:       ' + (noJwt.status < 300 ? 'YES (bad)' : 'no (correct)'));
console.log('  employee-only columns a driver can write:');
if (writable.length === 0) {
  console.log('    none. The approval workflow is enforced by the database.');
} else {
  for (const c of writable) console.log('    ' + c);
  console.log(
    '\n  Each of those is writable by a signed-in driver on their own row, because\n' +
      '  the `update own profile` policy scopes by row and not by column. `kyc_status`\n' +
      '  there means a driver can approve themselves, which removes the employees from\n' +
      '  the loop the approval screen was built to keep them in.',
  );
}

await q(`delete from profiles where id = '${mine}'`);
console.log('\n  Probe user removed.');
process.exit(writable.length > 0 || !gateOk ? 1 : 0);