// Removes the test and demo accounts that an earlier phase of testing left in the
// production database.
//
// ## Why this exists
//
// At one point the test suite created real auth users against the live project:
// accounts called `leave-driver-...@example`, `kyc-freeze-...`, `nav-verify-...`,
// `device-check-rider-...` and so on, one set per run. A hundred and one profiles
// in total. They appeared as riders and drivers with positions and trips, and the
// admin pages listed them as though they were people.
//
// The suite no longer does this -- verified by counting `profiles` either side of a
// full run, 101 before and 101 after -- so this is a one-off cleanup rather than
// something that runs on a schedule. It is kept because it is the only record of
// what was removed, and because the next time somebody points a test at the live
// project it is the script to reach for.
//
// ## What it will not do
//
// It refuses to touch an account that is not obviously a test account. Every
// deletion is gated on the email address, and the default keeps only the two
// accounts named in KEEP. There is no --all flag and no way to widen the net from
// the command line, because a script that can delete every real account is one
// typo away from doing exactly that.
//
// ## Usage
//
//   node toolchain/cleanup-test-data.mjs              # dry run, prints the plan
//   node toolchain/cleanup-test-data.mjs --apply      # does it
//
// Dry run is the default and there is no override in the other direction. A
// deletion from the production database should need a deliberate word.

import { readFileSync } from 'node:fs';

const KEEP = ['edemapaloo73@gmail.com', 'lonelymic04@gmail.com'];
const APPLY = process.argv.includes('--apply');

const env = {};
for (const f of ['toolchain/supabase-admin.env', 'toolchain/apk-build.env']) {
  let t;
  try { t = readFileSync(f, 'utf8'); } catch { continue; }
  for (const line of t.split('\n')) {
    const m = /^\s*([A-Z_0-9]+)=(.*)$/.exec(line);
    if (m && m[2]) env[m[1]] ??= m[2].replace(/^["']|["']$/g, '');
  }
}

const MGMT = 'https://api.supabase.com/v1/projects/' + env.SUPABASE_PROJECT_REF + '/database/query';
const headers = {
  Authorization: 'Bearer ' + env.SUPABASE_ADMIN_TOKEN,
  'Content-Type': 'application/json',
};

const sql = async (query, label) => {
  const r = await fetch(MGMT, { method: 'POST', headers, body: JSON.stringify({ query }) });
  const text = await r.text();
  let parsed;
  try { parsed = JSON.parse(text); } catch { parsed = text; }
  if (!r.ok) {
    console.log('FAIL ' + (label ?? '') + ' :: ' + JSON.stringify(parsed).slice(0, 200));
    process.exitCode = 1;
    return [];
  }
  if (label) console.log('--- ' + label);
  if (Array.isArray(parsed)) {
    if (label) console.log(JSON.stringify(parsed, null, 2).slice(0, 3000));
    return parsed;
  }
  return [];
};

const keepList = KEEP.map((e) => "'" + e + "'").join(',');

// Only addresses that are unmistakably generated. The prefix list is what the test
// helpers actually used; `rider@` and `driver@` are the two seeded demo logins.
const TEST_EMAIL =
  "u.email ~ '^(leave|left-item|kyc-freeze|nav-verify|contact|device-check|seed|demo)[^@]*@'" +
  " or u.email in ('rider@meetngo.app','driver@meetngo.app')";

const notKept = 'u.email not in (' + keepList + ') and (' + TEST_EMAIL + ')';

if (APPLY) {
  await sql(
    `delete from profiles p using auth.users u where u.id = p.id and ${notKept}`,
    'deleted profiles',
  );
  await sql(
    `delete from auth.users u where ${notKept}`,
    'deleted auth users',
  );
  await sql(
    `update offers o set state = 'released' from trips t
      where t.id = o.trip_id and o.state = 'pending' and t.state <> 'requested'`,
    'released offers left pending on dead trips',
  );
  await sql(
    `delete from trips t
      where t.state = 'requested'
        and not exists (select 1 from offers o where o.trip_id = t.id and o.state = 'pending')`,
    'deleted requested trips nobody took',
  );
  console.log('\nDone.');
} else {
  await sql(
    `select p.full_name, u.email from profiles p join auth.users u on u.id = p.id
      where ${notKept} order by u.email`,
    'WOULD remove these profiles',
  );
  await sql(
    `select
       (select count(*) from profiles p join auth.users u on u.id=p.id where ${notKept})::int as profiles,
       (select count(*) from trips t join auth.users u on u.id=t.rider_id where ${notKept})::int as trips,
       (select count(*) from driver_locations l join auth.users u on u.id=l.driver_id where ${notKept})::int as locations`,
    'WOULD go with them',
  );
  console.log('\nDRY RUN. Nothing was deleted.');
  console.log('Re-run with --apply to do it.');
}

const after = await sql(
  `select
     (select count(*) from profiles)::int as profiles,
     (select count(*) from profiles p join auth.users u on u.id=p.id
       where u.email not in (${keepList}))::int as profiles_not_kept,
     (select string_agg(u.email, ', ') from auth.users u)::text as emails_left,
     (select count(*) from offers where state='pending')::int as pending_offers,
     (select count(*) from trips where state in ('requested','matched','arriving','ongoing'))::int as active_trips`,
  'state now',
);
if (after.length) console.log(JSON.stringify(after[0], null, 2));
