// Can a driver really write their phone number, and can the rider read it?
//
//   node toolchain/verify-phone.mjs
//
// The phone field is only worth collecting if two things are true, and neither is
// visible from the app: a signed-in client can write `profiles.phone`, and the
// other party of a trip can read it. The second is the interesting one, because
// `init.sql` deliberately has no public driver-directory read policy -- an
// earlier note records that a `role = 'driver'` SELECT policy would expose every
// driver's KYC data to the anon key that ships in the APK.
//
// So the phone cannot be readable by "a rider reads a driver". It has to arrive
// through the trip, which is a row the two parties already share. This checks
// both: that the write works, and that `profiles.phone` is *not* readable by a
// signed-in client reading somebody else's row -- because if it is, the KYC data
// beside it is too, and that is a real leak rather than a theoretical one.

import { readFileSync } from 'node:fs';

const env = {};
for (const file of ['toolchain/supabase-admin.env', 'toolchain/apk-build.env']) {
  let text;
  try { text = readFileSync(file, 'utf8'); } catch { continue; }
  for (const line of text.split('\n')) {
    const m = /^\s*(?:export\s+)?([A-Z_0-9]+)=(.*)$/.exec(line);
    if (m && m[2]) env[m[1]] ??= m[2].replace(/^["']|["']$/g, '');
  }
}
const REF = env.SUPABASE_PROJECT_REF;
const ANON = env.SUPABASE_ANON_KEY;
const MGMT = 'https://api.supabase.com/v1/projects/' + REF + '/database/query';
const adminHeaders = { Authorization: 'Bearer ' + env.SUPABASE_ADMIN_TOKEN, 'Content-Type': 'application/json' };

const q = async (sql) => {
  const res = await fetch(MGMT, { method: 'POST', headers: adminHeaders, body: JSON.stringify({ query: sql }) });
  const body = await res.json();
  if (!res.ok) throw new Error(body.message ?? JSON.stringify(body));
  return Array.isArray(body) ? body : (body.value ?? body);
};
const one = async (sql) => (await q(sql))[0]?.id;

const say = (l, v) => console.log('  ' + l.padEnd(50) + (v === undefined ? '(none)' : v));
let ok = true;
const check = (label, got, want) => {
  const pass = String(got) === String(want);
  if (!pass) ok = false;
  console.log('  ' + (pass ? 'PASS' : 'FAIL') + '  ' + label.padEnd(46) + got + (pass ? '' : '   expected ' + want));
};

const made = [];
try {
  // Two throwaway users: one driver, one rider, so the "can the other party read
  // it" question has a real answer rather than a theoretical one.
  const users = [];
  for (const who of ['driver', 'rider']) {
    const email = `phonecheck_${who}_${Math.random().toString(36).slice(2, 8)}@example.com`;
    const su = await (await fetch(`https://${REF}.supabase.co/auth/v1/signup`, {
      method: 'POST',
      headers: { apikey: ANON, 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password: 'Testdrive123!', data: { role: who } }),
    })).json();
    const uid = su.user?.id;
    if (!uid) throw new Error('signup failed for ' + who + ': ' + JSON.stringify(su));
    // Signup already creates the profile, via `handle_new_user`.
    made.push({ who, uid, token: su.access_token });
    users.push({ who, uid, token: su.access_token });
  }
  const driver = users.find((u) => u.who === 'driver');
  const rider = users.find((u) => u.who === 'rider');
  for (const u of users) say('signed up ' + u.who, u.uid.slice(0, 8) + '...');

  console.log('\n=== 1. can the driver write their phone? ===');
  // Written as the app writes it: the normalised local form, in a row that
  // already has a name, which is the shape `submitGhanaCard` produces.
  const write = await fetch(`https://${REF}.supabase.co/rest/v1/profiles?id=eq.${driver.uid}`, {
    method: 'PATCH',
    headers: {
      apikey: ANON,
      Authorization: `Bearer ${driver.token}`,
      'Content-Type': 'application/json',
      Prefer: 'return=representation',
    },
    body: JSON.stringify({ full_name: 'Phone Check Driver', phone: '0241234567' }),
  });
  say('PATCH own profile -> HTTP', write.status);
  check('a driver can write their own phone', write.status, 200);

  const stored = await q(`select phone from profiles where id='${driver.uid}'`);
  check('the phone is what was written', stored[0]?.phone, '0241234567');

  console.log('\n=== 2. can the guard be used to write somebody else\'s phone? ===');
  const crossWrite = await fetch(`https://${REF}.supabase.co/rest/v1/profiles?id=eq.${rider.uid}`, {
    method: 'PATCH',
    headers: {
      apikey: ANON,
      Authorization: `Bearer ${driver.token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ phone: '0200000000' }),
  });
  // The status is NOT the test. PostgREST returns 204 when an update matched
  // zero rows, which is what row-level security produces here: the "update own
  // profile" policy's USING clause is `id = auth.uid()`, so the other user's row
  // is filtered out of the set the statement may touch and nothing is written.
  // A 2xx therefore does not mean it worked, and asserting on the status alone
  // would have reported a working leak. What matters is the data.
  say('PATCH another profile -> HTTP', crossWrite.status);
  console.log('    (204 is RLS matching zero rows, not a successful write)');
  const riderPhone = await q(`select phone from profiles where id='${rider.uid}'`);
  check('the other profile was NOT changed', riderPhone[0]?.phone, '');

  console.log('\n=== 3. can one user read another user\'s profile at all? ===');
  // This is the finding that matters for the call feature. There is deliberately
  // no public directory read policy, so a rider cannot read a driver's row --
  // and therefore cannot read the driver's phone. Which means the phone has to
  // reach the rider through the trip, not through the profile.
  const crossRead = await fetch(`https://${REF}.supabase.co/rest/v1/profiles?id=eq.${driver.uid}&select=phone`, {
    headers: { apikey: ANON, Authorization: `Bearer ${rider.token}` },
  });
  const rows = await crossRead.json();
  const readable = Array.isArray(rows) ? rows.length : 0;
  const isolated = readable === 0;
  console.log('  ' + (isolated ? 'ISOLATED' : 'READABLE')
    + '  the rider reading the driver\'s phone -> ' + readable + ' row(s), HTTP ' + crossRead.status);
  if (!isolated) {
    console.log('      the driver\'s phone is readable by any signed-in user, and so is the');
    console.log('      Ghana Card number in the same row. That is a real leak, not a theory.');
  }

  console.log('\n=== 4. is the phone readable through the trip, where the two parties share a row? ===');
  // The shape the call feature has to use. `trips` has an RLS policy scoped to
  // the two parties, so a phone copied onto the trip is readable by the rider and
  // by nobody else. There is no such column today, which is the work item.
  const tripCols = await q(
    "select column_name from information_schema.columns where table_name='trips' and column_name like '%phone%'");
  check('trips has no phone column yet', tripCols.length, 0);
  console.log('      -> the call feature needs a phone on the trip, or an edge function');
  console.log('         that hands the number over once, for a trip the caller is a party to.');
} catch (e) {
  ok = false;
  console.log('  ERROR: ' + e.message);
} finally {
  for (const m of made) {
    for (const sql of [
      `delete from trips where rider_id='${m.uid}' or driver_id='${m.uid}'`,
      `delete from profiles where id='${m.uid}'`,
      `delete from auth.users where id='${m.uid}'`,
    ]) { try { await q(sql); } catch { /* already gone */ } }
  }
  if (made.length) {
    const left = await q(`select (select count(*) from profiles where id in (${made.map((m) => `'${m.uid}'`).join(',')}))::text p`);
    console.log('\n  cleanup: ' + left[0].p + ' test profiles left');
  }
}
console.log('\n' + (ok ? 'ALL CHECKS PASSED' : 'SOMETHING FAILED'));
process.exit(ok ? 0 : 1);
