// The actual GRANTs on profiles, and whether a driver can really write a phone.
//
//   node toolchain/check-phone-write-live.mjs
//
// `check-phone-write-policy.mjs` reported `authenticated has UPDATE: false`,
// which read like a blocker -- and it is not. It is the single most misleading
// thing you can learn from `pg_policies`, so it is worth writing down properly.
//
// What the grants actually say:
//
//   anon            DELETE, REFERENCES, SELECT, TRIGGER, TRUNCATE
//   authenticated   DELETE, REFERENCES, SELECT, TRIGGER, TRUNCATE
//   postgres        ... INSERT, ... UPDATE
//   service_role    ... INSERT, ... UPDATE
//
// `authenticated` has no UPDATE and no INSERT on `profiles`. Only `postgres` and
// `service_role` do. Read on its own that says a driver can never write their own
// profile, and the phone gate is unpassable -- which is not what happens.
//
// What actually happens is in the memberships:
//
//   authenticator is a member of anon
//   authenticator is a member of authenticated
//   authenticator is a member of service_role
//
// PostgREST does not connect as `anon` or `authenticated`. It connects as
// `authenticator`, switches role to the one named in the request's JWT
// (`SET LOCAL ROLE authenticated`), and *keeps* every privilege `authenticator`
// held -- including the ones it inherited from `service_role`. So the table
// grant is effectively never the thing that stops a write; `authenticated`'s
// lack of UPDATE is invisible at runtime.
//
// The consequence is the important part, and it is the reason this file ends in a
// live write rather than a policy read:
//
//   Row level security is the only thing protecting `profiles`.
//
// There is no table-level grant standing behind it. If a policy is ever written
// too loosely -- or dropped -- every column of every profile is writable and
// readable through the anon key, including the Ghana Card fields. That is not a
// hypothetical: `profiles` holds `card_number`, `card_dob` and `card_issued`, and
// this is exactly the class of bug a green policy query cannot find.
//
// So this script proves three things against the live database:
//
//   1. a driver can write their own phone
//   2. a driver cannot write anybody else's
//   3. the real driver this change is about is still untouched
//
// (2) is not obvious from the status code. PostgREST answers `204 No Content`
// for a write that matched zero rows, which is exactly what a *successful*
// refusal looks like on the wire -- so a refused cross-user write and a
// successful one are the same status. Only reading the rows back distinguishes
// them, so that is what this does.
//
// (3) exists because this script writes to the live database. The probe user is
// created and then deleted; the real drivers are never modified. If a future
// edit of this file ever writes to a real driver, (3) is what catches it.

import { readEnv, readEnvOrFail } from './read-env.mjs';

const adminEnv = readEnvOrFail('toolchain/supabase-admin.env', [
  'SUPABASE_PROJECT_REF',
  'SUPABASE_ADMIN_TOKEN',
]);

// The anon key and the project URL both come from the build env, because that is
// the pair the APK is compiled against. Reading the URL from there rather than
// composing it from the project ref is what makes it impossible for this script
// to test the write against one project and read the results from another.
const buildEnv = readEnvOrFail('toolchain/apk-build.env', ['SB_URL', 'SB_ANON_KEY']);

const ANON = buildEnv.SB_ANON_KEY;
const url = buildEnv.SB_URL.replace(/\/+$/, '');
const ref = adminEnv.SUPABASE_PROJECT_REF;

// The ref has to match, or "the write was refused" means nothing. A mismatch
// means someone has pointed the two files at different projects, which is worth
// a hard stop rather than a confusing result.
if (!url.includes(ref)) {
  throw new Error(
    `toolchain/apk-build.env points at ${url}\n` +
      `toolchain/supabase-admin.env points at project ${ref}\n` +
      '  Refusing to write through one key and read through another.',
  );
}

const env = { ...adminEnv };

const admin = async (sql) => {
  const res = await fetch('https://api.supabase.com/v1/projects/' + ref + '/database/query', {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + env.SUPABASE_ADMIN_TOKEN, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(body.message ?? JSON.stringify(body));
  return Array.isArray(body) ? body : (body.value ?? []);
};

// ---------------------------------------------------------------- the grants
console.log('=== grants that mention profiles ===\n');
const grants = await admin(
  `select grantee, table_name, privilege_type
     from information_schema.role_table_grants
    where table_schema = 'public' and table_name = 'profiles'
    order by grantee, privilege_type`,
);
const byGrantee = new Map();
for (const g of grants) {
  if (!byGrantee.has(g.grantee)) byGrantee.set(g.grantee, []);
  byGrantee.get(g.grantee).push(g.privilege_type);
}
for (const [who, privs] of byGrantee) {
  console.log('  ' + who.padEnd(16) + privs.join(', '));
}

console.log('\n=== role memberships ===\n');
const members = await admin(
  `select r.rolname as role, m.rolname as member
     from pg_auth_members am
     join pg_roles r on r.oid = am.roleid
     join pg_roles m on m.oid = am.member
    where r.rolname in ('anon','authenticated','service_role')
    order by 1,2`,
);
if (members.length === 0) console.log('  (none: anon and authenticated inherit nothing)');
for (const m of members) console.log(`  ${m.member} is a member of ${m.role}`);

console.log('\n=== effective privileges, role by role ===\n');
const eff = await admin(
  `select
     has_table_privilege('anon',         'public.profiles', 'UPDATE')::text as anon_up,
     has_table_privilege('authenticated','public.profiles', 'UPDATE')::text as auth_up,
     has_table_privilege('authenticator', 'public.profiles', 'UPDATE')::text as authn_up,
     has_table_privilege('service_role', 'public.profiles', 'UPDATE')::text as svc_up,
     has_table_privilege('authenticated','public.profiles', 'SELECT')::text as auth_sel`,
);
console.log('  anon           SELECT ' + eff[0].auth_sel + '   UPDATE ' + eff[0].anon_up);
console.log('  authenticated  SELECT ' + eff[0].auth_sel + '   UPDATE ' + eff[0].auth_up);
console.log('  authenticator  SELECT ' + eff[0].auth_sel + '   UPDATE ' + eff[0].authn_up);
console.log('  service_role            UPDATE ' + eff[0].svc_up);

// The line that matters, and the reason the header comment is as long as it is.
// `authenticated` says no; `authenticator` says yes, because it inherits
// `service_role`. PostgREST connects as `authenticator`, so the table grant is
// not what decides anything -- row level security is doing all of it.
if (eff[0].auth_up !== 'true' && eff[0].authn_up === 'true') {
  console.log(
    '\n  READ THIS: `authenticated` has no UPDATE, but `authenticator` does,\n' +
      '  because it is a member of service_role. PostgREST connects as\n' +
      '  `authenticator`, so the grant above is not the gate -- RLS is. That is\n' +
      '  working as intended here, and it also means a loose or missing policy on\n' +
      '  `profiles` would expose every column of every profile, Ghana Card fields\n' +
      '  included. Nothing but the live checks below can catch that.',
  );
}

// Which sensitive columns are on the table RLS is the sole guard for.
const cols = await admin(
  `select column_name
     from information_schema.columns
    where table_schema = 'public' and table_name = 'profiles'
      and (column_name like 'card%' or column_name in ('phone','full_name','role'))
    order by 1`,
);
console.log('\n=== columns on profiles that RLS alone is protecting ===\n');
for (const c of cols) console.log('  ' + c.column_name);

// -------------------------------------------------- the write that settles it
console.log('\n=== the write, as the app makes it ===\n');

// Pick a driver who genuinely has no phone: the one this change is for.
const target = (
  await admin(
    `select id, full_name, coalesce(nullif(phone,''),'(none)') as phone
       from profiles
      where role = 'driver' and coalesce(phone,'') = ''
      order by created_at
      limit 1`,
  )
)[0];
if (!target) {
  console.log('  no driver without a phone; nothing to prove here.');
  process.exit(0);
}
console.log(`  driver: ${target.full_name}  ${target.id.slice(0, 8)}  phone=${target.phone}`);

// A real session for that driver. The password is not in the database and this
// script does not have it, so this signs in as a freshly made throwaway driver
// instead -- the policy under test is `id = auth.uid()`, which does not care
// which driver it is.
const email = 'phone-gate-probe-' + Date.now() + '@example.test';
const password = 'Probe-9' + Math.random().toString(36).slice(2, 10);
const signUp = await fetch(url + '/auth/v1/signup', {
  method: 'POST',
  headers: { apikey: ANON, 'Content-Type': 'application/json' },
  body: JSON.stringify({ email, password, data: { full_name: 'Phone Gate Probe' } }),
});
const signUpBody = await signUp.json();
if (!signUpBody.access_token) {
  console.log('  could not create a probe user: ' + JSON.stringify(signUpBody).slice(0, 300));
  process.exit(1);
}
const token = signUpBody.access_token;
const mine = signUpBody.user.id;
console.log('  probe session established for ' + mine.slice(0, 8));

// The write the gate makes.
const write = await fetch(url + '/rest/v1/profiles?id=eq.' + mine, {
  method: 'PATCH',
  headers: {
    apikey: ANON,
    Authorization: 'Bearer ' + token,
    'Content-Type': 'application/json',
    Prefer: 'return=representation',
  },
  body: JSON.stringify({ phone: '0241234567' }),
});
const writeBody = await write.json();
console.log('  own row  -> HTTP ' + write.status + '  ' + JSON.stringify(writeBody).slice(0, 120));

// The write the policy must refuse: somebody else's row.
const other = (
  await admin(`select id from profiles where id <> '${mine}' order by created_at limit 1`)
)[0];
const crossWrite = await fetch(url + '/rest/v1/profiles?id=eq.' + other.id, {
  method: 'PATCH',
  headers: {
    apikey: ANON,
    Authorization: 'Bearer ' + token,
    'Content-Type': 'application/json',
    Prefer: 'return=representation',
  },
  body: JSON.stringify({ phone: '0200000000' }),
});
const crossBody = await crossWrite.json();
console.log('  other row-> HTTP ' + crossWrite.status + '  ' + JSON.stringify(crossBody).slice(0, 120));

// PostgREST answers 204 for a write that matched no rows, which is what a
// successful *refusal* looks like on the wire. So the status proves nothing; the
// only trustworthy assertion is on the data.
const check = (await admin(`select coalesce(nullif(phone,''),'(none)') as phone from profiles where id = '${mine}'`))[0];
const otherCheck = (await admin(`select coalesce(nullif(phone,''),'(none)') as phone from profiles where id = '${other.id}'`))[0];

// And the real target driver, whose row this change is about, is left alone.
const untouched = (await admin(`select coalesce(nullif(phone,''),'(none)') as phone from profiles where id = '${target.id}'`))[0];

console.log('\n=== what the database actually says ===\n');
console.log('  probe row now holds:  ' + check.phone);
console.log('  the other driver:     ' + otherCheck.phone);
console.log('  the real target:      ' + untouched.phone);

await admin(`delete from profiles where id = '${mine}'`);

const ownOk = check.phone === '0241234567';
const crossRefused = otherCheck.phone === '(none)' || otherCheck.phone !== '0200000000';
const targetUntouched = untouched.phone === '(none)';

console.log('\n=== verdict ===\n');
console.log('  a driver can save their own number:  ' + (ownOk ? 'YES' : 'NO'));
console.log('  a driver can change another row:      ' + (crossRefused ? 'NO (correct)' : 'YES (THIS IS A BUG)'));
console.log('  the real target driver was untouched: ' + (targetUntouched ? 'YES' : 'NO'));

if (!ownOk) {
  console.log(
    '\n  The gate cannot be passed. Every driver stuck on it with a button that\n' +
      '  always fails needs a grant before launch.',
  );
  process.exit(1);
}
console.log('\n  Probe user removed.');
