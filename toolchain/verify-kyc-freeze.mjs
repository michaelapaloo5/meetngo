// Proves the KYC identity freeze, and proves it did not break the three things
// that legitimately write to `profiles`.
//
//   node toolchain/verify-kyc-freeze.mjs
//
// A guard like this has two failure modes and the dangerous one is the second:
// it blocks the thing it should, and then quietly blocks the phone gate, the
// onboarding scan, or the employee approving a driver. Every assertion here is
// paired with the legitimate write it must not interfere with.
//
// The freeze itself was found by measurement, not by reading the schema.
// `who-actually-writes.mjs` signs in as a real driver and writes each column in
// turn; before the freeze, `ghana_card_number` came back ALLOWED while
// `kyc_status` came back refused. So:
//
//   1. a PENDING driver can still fill in the card        (onboarding)
//   2. a PENDING driver can still take the selfie        (liveness)
//   3. an APPROVED driver cannot rewrite the card        (the fix)
//   4. an APPROVED driver cannot rewrite the selfie      (the fix)
//   5. an APPROVED driver CAN still save a phone number   (the gate)
//   6. an APPROVED driver CAN still change their avatar  (not evidence)
//   7. a REJECTED driver can reopen and resubmit          (the loop must close)
//   8. service_role can still write everything            (staff approve)
//
// Assertions are made on the data, never on the status code: PostgREST answers
// 204 for a write that matched zero rows, which is what a successful refusal
// looks like on the wire.

import { readEnvOrFail } from './read-env.mjs';

const adminEnv = readEnvOrFail('toolchain/supabase-admin.env', [
  'SUPABASE_PROJECT_REF',
  'SUPABASE_ADMIN_TOKEN',
]);
const buildEnv = readEnvOrFail('toolchain/apk-build.env', ['SB_URL', 'SB_ANON_KEY']);
const ref = adminEnv.SUPABASE_PROJECT_REF;
const url = buildEnv.SB_URL.replace(/\/+$/, '');
const ANON = buildEnv.SB_ANON_KEY;
const pad = (s, n) => String(s).padEnd(n);

const admin = async (sql) => {
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

// A driver who is exactly in the state under test.
const makeDriver = async (kycStatus) => {
  const email = 'kyc-freeze-' + Date.now() + '-' + Math.random().toString(36).slice(2, 7) + '@example.test';
  const res = await fetch(url + '/auth/v1/signup', {
    method: 'POST',
    headers: { apikey: ANON, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      email,
      password: 'Probe-9' + Math.random().toString(36).slice(2, 10),
      data: { full_name: 'KYC Freeze Probe' },
    }),
  });
  const body = await res.json();
  if (!body.access_token) throw new Error('could not create a probe: ' + JSON.stringify(body).slice(0, 200));

  // Put the row into the state under test. service_role, because the client is
  // not allowed to set an approval -- which is assertion 8 in a different guise.
  await admin(
    `update profiles set role = 'driver', kyc_status = '${kycStatus}',
            ghana_card_number = 'GHA-0000000-1', ghana_card_dob = '1990-01-01',
            ghana_card_expiry = '2030-01-01', selfie_url = 'selfie-before.png',
            phone = ''
      where id = '${body.user.id}'`,
  );
  return { id: body.user.id, token: body.access_token };
};

// The write as the app makes it.
const write = async (id, token, body) => {
  const res = await fetch(`${url}/rest/v1/profiles?id=eq.${id}`, {
    method: 'PATCH',
    headers: {
      apikey: ANON,
      Authorization: 'Bearer ' + token,
      'Content-Type': 'application/json',
      Prefer: 'return=representation',
    },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  return { ok: res.status < 300 && text.includes('"id"'), status: res.status, text };
};

const read = async (id) =>
  (await admin(`select coalesce(nullif(phone,''),'(none)') as phone,
                       ghana_card_number, ghana_card_dob, selfie_url, kyc_status
                  from profiles where id = '${id}'`))[0];

const results = [];
const check = (label, actual, expected, why) => {
  const ok = actual === expected;
  results.push({ label, ok, actual, expected, why });
  const mark = ok ? 'PASS' : 'FAIL';
  const got = typeof actual === 'boolean' ? (actual ? 'written' : 'refused') : String(actual);
  const want = typeof expected === 'boolean' ? (expected ? 'written' : 'refused') : String(expected);
  console.log(`  ${mark}  ${pad(label, 46)} ${pad(got, 12)} wanted ${pad(want, 12)} ${why}`);
};

// ---------------------------------------------------------------------------
console.log('=== a pending driver is still the authority on their own card ===\n');

const pending = await makeDriver('pending');

// 1. onboarding writes the card.
let r = await write(pending.id, pending.token, { ghana_card_number: 'GHA-1111111-2' });
check('pending driver fills in the card number', r.ok, true, 'onboarding would be dead otherwise');

// 2. and the selfie, which is the liveness artefact.
r = await write(pending.id, pending.token, { selfie_url: 'selfie-new.png' });
check('pending driver replaces the selfie', r.ok, true, 'the scan step would be dead');

let row = await read(pending.id);
check('  and the new card number is what is on file', row.ghana_card_number, 'GHA-1111111-2', '');
check('  and the new selfie is what is on file', row.selfie_url, 'selfie-new.png', '');

// ---------------------------------------------------------------------------
console.log('\n=== once approved, the evidence is settled ===\n');

// An employee approves. service_role, because that is the approval path and
// assertion 8 checks it still works.
await admin(`update profiles set kyc_status = 'approved' where id = '${pending.id}'`);

// 3. the card.
r = await write(pending.id, pending.token, { ghana_card_number: 'GHA-9999999-9' });
check('approved driver rewrites the card number', r.ok, false, 'this is the whole fix');

// 4. the selfie.
r = await write(pending.id, pending.token, { selfie_url: 'someone-else.png' });
check('approved driver swaps the selfie', r.ok, false, 'the liveness artefact is evidence');

// The dob too, because one column being covered does not mean the row is.
r = await write(pending.id, pending.token, { ghana_card_dob: '1970-06-06' });
check('approved driver rewrites the card date of birth', r.ok, false, 'the other columns too');

row = await read(pending.id);
check('  the card number is unchanged', row.ghana_card_number, 'GHA-1111111-2', '');
check('  the date of birth is unchanged', row.ghana_card_dob, '1990-01-01', '');
check('  the selfie is unchanged', row.selfie_url, 'selfie-new.png', '');

// 5. THE GATE. If the freeze caught `phone`, every approved driver without a
//    number would be stuck on the gate screen with no way past it.
r = await write(pending.id, pending.token, { phone: '0241234567' });
check('approved driver saves a phone number', r.ok, true, 'the phone gate depends on this');
row = await read(pending.id);
check('  and it is stored normalised', row.phone, '0241234567', '');

// 6. the avatar is not evidence, so it stays writable.
r = await write(pending.id, pending.token, { photo_url: 'new-avatar.png' });
check('approved driver changes their avatar', r.ok, true, 'an avatar is not evidence');

// ---------------------------------------------------------------------------
console.log('\n=== a rejected driver can reopen and resubmit ===\n');

const rejected = await makeDriver('rejected');

// 7. the freeze applies to rejected too: a decision was made.
r = await write(rejected.id, rejected.token, { ghana_card_number: 'GHA-2222222-3' });
check('rejected driver rewrites the card', r.ok, false, 'the decision stands');

// But they may set themselves back to pending -- the existing guard has always
// allowed exactly that -- and then the fields open again. Without this the
// resubmission loop is closed by accident and a rejected driver can never fix a
// typo, which is a worse outcome than the one being fixed.
r = await write(rejected.id, rejected.token, { kyc_status: 'pending' });
check('rejected driver sets themselves back to pending', r.ok, true, 'the loop must close');
r = await write(rejected.id, rejected.token, { ghana_card_number: 'GHA-2222222-3' });
check('  and can then correct the card', r.ok, true, 'otherwise a typo is permanent');
row = await read(rejected.id);
check('  and the corrected card is on file', row.ghana_card_number, 'GHA-2222222-3', '');

// ---------------------------------------------------------------------------
console.log('\n=== staff approval still works ===\n');

// 8. service_role is the only path an employee has, and the freeze must not
//    touch it -- or nobody could approve or reject anybody.
//    `approved_by` is a uuid and this probe has no staff account, so it is set
//    to null rather than a name. What is being tested is that the *columns* are
//    writable from service_role, not who recorded the decision.
await admin(
  `update profiles set kyc_status = 'approved', ghana_card_number = 'GHA-3333333-4',
          approved_at = now()
    where id = '${rejected.id}'`,
);
const after = await read(rejected.id);
check('service_role approves a driver', after.kyc_status, 'approved', 'the approval button itself');
check('service_role corrects the card at approval', after.ghana_card_number, 'GHA-3333333-4',
  'an employee fixing a typo is legitimate');

// And once service_role has approved, the freeze is back for the client.
r = await write(rejected.id, rejected.token, { ghana_card_number: 'GHA-4444444-5' });
check('and the client is frozen again after that', r.ok, false, '');

// ---------------------------------------------------------------------------
console.log('\n=== the error a driver actually sees ===\n');

const blocked = await write(pending.id, pending.token, { ghana_card_number: 'GHA-5555555-6' });
let message = '(no message)';
try {
  const parsed = JSON.parse(blocked.text);
  message = parsed.message ?? parsed.hint ?? parsed.error ?? '(none)';
} catch {
  message = blocked.text.slice(0, 200);
}
console.log('  ' + message);
// The message names the state and says who can undo it, because "locked" with
// no way forward is the message that produces an angry support call.
const mentionsLock = /lock/i.test(message);
const mentionsStaff = /staff|reopen|ask/i.test(message);
results.push({ label: 'the message says it is locked', ok: mentionsLock });
results.push({ label: 'the message says who can undo it', ok: mentionsStaff });
console.log(`  ${mentionsLock ? 'PASS' : 'FAIL'}  it says the fields are locked`);
console.log(`  ${mentionsStaff ? 'PASS' : 'FAIL'}  it says who can reopen the review`);

// ---------------------------------------------------------------------------
await admin(`delete from profiles where id in ('${pending.id}','${rejected.id}')`);

const failed = results.filter((r) => !r.ok);
console.log(`\n=== ${results.length - failed.length} of ${results.length} passed ===`);
if (failed.length > 0) {
  console.log('\nfailures:');
  for (const f of failed) console.log(`  ${f.label}: got ${f.actual}, wanted ${f.expected}`);
  process.exit(1);
}
console.log('\nProbe drivers removed. No real driver was touched.');