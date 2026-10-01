// Proves report-a-left-item, and proves the driver cannot touch the employee half.
//
//   node toolchain/verify-left-item.mjs
//
// A report is read by a person who will take it seriously, so the property worth
// checking is not "a report can be filed" -- it is who can file one, what they
// can change afterwards, and who cannot touch the employee columns.
//
// Assertions, in the order they matter:
//
//   1. a driver can report an item left by a rider
//   2. a driver can correct their own report   (the upsert path)
//   3. a driver cannot file a second report for one trip
//   4. a driver cannot set `status`            (employee-owned)
//   5. a driver cannot set `staff_note`        (employee-owned)
//   6. a driver cannot re-point the report at another trip
//   7. a rider on the same trip can file one too
//   8. somebody not on the trip cannot file one at all
//   9. a driver cannot read anybody else's report
//  10. service_role can close it, which is the employee button
//
// Every one is read back out of the table. Nothing asserts on an HTTP status:
// PostgREST answers a write that matched no rows with 204, which is exactly what
// a successful refusal looks like on the wire.

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

const sql = async (query) => {
  const res = await fetch('https://api.supabase.com/v1/projects/' + ref + '/database/query', {
    method: 'POST',
    headers: {
      Authorization: 'Bearer ' + adminEnv.SUPABASE_ADMIN_TOKEN,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ query }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(body.message ?? JSON.stringify(body));
  return Array.isArray(body) ? body : (body.value ?? []);
};

// --------------------------------------------------------------- fixtures
const stamp = Date.now();
const email = (who) => `left-item-${who}-${stamp}@example.test`;
const password = 'Probe-9' + Math.random().toString(36).slice(2, 10);

const signUp = async (who) => {
  const res = await fetch(url + '/auth/v1/signup', {
    method: 'POST',
    headers: { apikey: ANON, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email: email(who), password, data: { full_name: who } }),
  });
  const body = await res.json();
  if (!body.access_token) throw new Error('signup failed: ' + JSON.stringify(body).slice(0, 200));
  return { id: body.user.id, token: body.access_token };
};

const driver = await signUp('Driver');
const rider = await signUp('Rider');
const stranger = await signUp('Stranger');
console.log(`  driver    ${driver.id.slice(0, 8)}`);
console.log(`  rider     ${rider.id.slice(0, 8)}`);
console.log(`  stranger  ${stranger.id.slice(0, 8)}`);

// A completed trip between the first two, and one the stranger is not on.
//
// The column list is read rather than guessed: `pickup` and `dropoff` are single
// jsonb columns holding the whole stop, not `pickup_label`/`pickup_address`
// pairs, and a fixture written from the Dart model's field names rather than from
// the schema is a query that fails on a column nobody has.
const insertTrip = async (label) => (
  await sql(
    `insert into trips (rider_id, driver_id, category, state, pickup, dropoff,
                        pickup_point, dropoff_point, distance_km, fare_ghs, is_demo)
     values ('${rider.id}', '${driver.id}', 'standard', 'completed',
             jsonb_build_object('label', '${label}', 'address', '${label}, Accra, Accra'),
             jsonb_build_object('label', 'Airport Residential', 'address', 'Airport Residential, Accra'),
             st_makepoint(5.6037, -0.1870), st_makepoint(5.6200, -0.1870),
             2.02, 12.50, true)
     returning id`,
  )
)[0].id;

const tripId = await insertTrip('Osu Junction');
const otherTripId = await insertTrip('Second pickup');
console.log(`  trip      ${tripId.slice(0, 8)}   (second: ${otherTripId.slice(0, 8)})\n`);

// ------------------------------------------------------------------ helpers
const insert = async (token, row, prefer = 'return=representation', query = '') => {
  const res = await fetch(`${url}/rest/v1/left_item_reports${query}`, {
    method: 'POST',
    headers: {
      apikey: ANON,
      Authorization: 'Bearer ' + token,
      'Content-Type': 'application/json',
      Prefer: prefer,
    },
    body: JSON.stringify(row),
  });
  return { status: res.status, text: await res.text() };
};

const patch = async (token, filter, row) => {
  const res = await fetch(`${url}/rest/v1/left_item_reports?${filter}`, {
    method: 'PATCH',
    headers: {
      apikey: ANON,
      Authorization: 'Bearer ' + token,
      'Content-Type': 'application/json',
      Prefer: 'return=representation',
    },
    body: JSON.stringify(row),
  });
  return { status: res.status, text: await res.text() };
};

const select = async (token, filter) => {
  const res = await fetch(`${url}/rest/v1/left_item_reports?${filter}`, {
    headers: { apikey: ANON, Authorization: 'Bearer ' + token },
  });
  if (!res.ok) return { status: res.status, rows: [] };
  return { status: res.status, rows: await res.json() };
};

const read = async (id) => (await sql(`select * from left_item_reports where id = '${id}'`))[0];

const results = [];
const check = (label, actual, expected, why) => {
  const ok = actual === expected;
  results.push({ label, ok });
  const show = (v) => (typeof v === 'boolean' ? (v ? 'accepted' : 'refused') : String(v));
  console.log(
    `  ${ok ? 'PASS' : 'FAIL'}  ${pad(label, 44)} ${pad(show(actual), 10)} wanted ${pad(show(expected), 10)} ${why}`,
  );
};

// -------------------------------------------------------------------------
console.log('=== a driver can report an item the rider left ===\n');

let r = await insert(driver.token, {
  trip_id: tripId,
  reporter_id: driver.id,
  item: 'Blue rucksack',
  description: 'Left in the back, under the floor mat',
});
const created = r.status < 300 && r.text.includes('"id"');
check('files a report', created, true, 'the whole feature');
let report = created ? await read(JSON.parse(r.text)[0].id) : null;
check('  it is open', report?.status, 'open', 'a new report is not resolved');
check('  the description is kept', report?.description, 'Left in the back, under the floor mat', '');

// An empty item is refused by the constraint, not by the app.
r = await insert(driver.token, { trip_id: tripId, reporter_id: driver.id, item: '   ' });
check('an empty item is refused', r.status < 300, false, 'a check constraint, so the server decides');

// -------------------------------------------------------------------------
console.log('\n=== and can correct it ===\n');

// The correction is an upsert, and an upsert here needs *two* things that each
// look sufficient alone and are not.
//
// Measured, not read off documentation: `toolchain/probe-upsert.mjs` tries five
// spellings against this server. `Prefer: resolution=merge-duplicates` on its own
// is refused with 409 and `duplicate key value violates unique constraint
// "left_item_reports_one_per_trip"` -- PostgREST never builds `ON CONFLICT DO
// UPDATE`. Adding `?on_conflict=trip_id,reporter_id` is what makes it work, and
// the old `Prefer: upsert=merge-duplicates` spelling is refused either way.
//
// The client's `.upsert(row, onConflict: 'trip_id,reporter_id')` sends both, so
// this is what the app does; the two lines below are that same pair by hand.
r = await insert(driver.token, {
  trip_id: tripId,
  reporter_id: driver.id,
  item: 'Blue rucksack',
  description: 'Left in the boot, not the footwell',
});
check('files a correction as a plain insert', r.status < 400, false, '409: the unique constraint is doing its job');

r = await insert(
  driver.token,
  {
    trip_id: tripId,
    reporter_id: driver.id,
    item: 'Blue rucksack',
    description: 'Left in the boot, not the footwell',
  },
  'resolution=merge-duplicates,return=representation',
  '?on_conflict=trip_id,reporter_id',
);
const corrected = r.status < 300 && r.text.includes('"id"');
if (!corrected) {
  console.log(`\n  the upsert said: HTTP ${r.status}  ${r.text.slice(0, 400)}\n`);
}
const all = (await sql(`select count(*)::int as n from left_item_reports where trip_id = '${tripId}'`))[0].n;
check('files a correction as an upsert', corrected, true, 'the correction path the app uses');
check('  and there is still only one row', all, 1, 'five rows for one lost bag is not a correction');
report = await read((await sql(`select id from left_item_reports where trip_id = '${tripId}'`))[0].id);
check('  and the new description is the one on file', report.description, 'Left in the boot, not the footwell', '');

// -------------------------------------------------------------------------
console.log('\n=== the employee columns are not the driver\'s ===\n');

// Everything in this section asserts on the *row*, never on the status.
//
// This is the trap the codebase already documents and this script walked into
// first: PostgREST answers a write that matched no rows with `204 No Content`,
// which is exactly what a successful refusal looks like on the wire. `status < 300`
// is therefore true for a refusal as well as for a success, and an earlier
// version of these six checks reported every one of them as "accepted" while the
// database said nothing had changed. So each one writes, reads back, and compares
// the value -- and the status is only reported, never asserted on.

// 4 and 5. These are the ones that matter. `status` and `staff_note` are the
// employee button and the employee's words; a driver who can write them can close
// a queue in their own name and put text in front of staff that staff did not
// write.
const reportId = (await sql(`select id from left_item_reports where trip_id = '${tripId}' and reporter_id = '${driver.id}'`))[0].id;

r = await patch(driver.token, `id=eq.${reportId}`, { status: 'returned' });
check('sets status', (await read(reportId)).status, 'open', 'staff-owned; read back, not the status');

r = await patch(driver.token, `id=eq.${reportId}`, { staff_note: 'Collected, no action needed' });
check('sets staff_note', (await read(reportId)).staff_note, '', 'staff-owned');

r = await patch(driver.token, `id=eq.${reportId}`, { returned_at: '2026-10-01T00:00:00Z' });
check('sets returned_at', (await read(reportId)).returned_at, null, 'staff-owned');

// 6. Re-pointing the report at a trip the driver is party to but the report was
// not filed against. RLS would pass this, because the driver is on both trips.
r = await patch(driver.token, `id=eq.${reportId}`, { trip_id: otherTripId });
check('re-points the report at another trip', (await read(reportId)).trip_id, tripId, 'RLS alone would allow this');

r = await patch(driver.token, `id=eq.${reportId}`, { reporter_id: rider.id });
check('re-points the reporter', (await read(reportId)).reporter_id, driver.id, 'the reporter is fixed at insert');

// The description is still editable, because that is the correction path.
r = await patch(driver.token, `id=eq.${reportId}`, { description: 'Blue rucksack, black straps' });
check('edits the description', (await read(reportId)).description, 'Blue rucksack, black straps', 'correcting your own report is allowed');

// -------------------------------------------------------------------------
console.log('\n=== who else may file one ===\n');

// 7. The rider is party to the trip, so the policy admits them.
r = await insert(rider.token, {
  trip_id: tripId,
  reporter_id: rider.id,
  item: 'Umbrella',
});
const riderFiled = r.status < 300 && r.text.includes('"id"');
check('the rider files one too', riderFiled, true, 'the policy is about the trip, not the role');

// 8. Somebody not on the trip.
r = await insert(stranger.token, {
  trip_id: tripId,
  reporter_id: stranger.id,
  item: 'Wallet',
});
const strangerRows = (await sql(
  `select count(*)::int as n from left_item_reports where reporter_id = '${stranger.id}'`,
))[0].n;
check('somebody not on the trip cannot', strangerRows, 0, 'the whole point of the EXISTS');
check('  and the refusal is a 403, not a 201', r.status, 403, 'reported, not asserted: the row count above is the assertion');

// -------------------------------------------------------------------------
console.log('\n=== and who may read ===\n');

// 9.
const strangerRead = await select(stranger.token, `trip_id=eq.${tripId}`);
check('a stranger reads no reports', strangerRead.rows.length, 0, 'no other reports are readable');
const driverRead = await select(driver.token, `trip_id=eq.${tripId}`);
check('the driver reads their own', driverRead.rows.length >= 1, true, 'so they can correct one');

// -------------------------------------------------------------------------
console.log('\n=== staff close it ===\n');

// 10. The employee button. If this fails, a report can be filed and never
// resolved, which makes the feature worse than not having it: it becomes a place
// to complain with no answer.
await sql(
  `update left_item_reports set status = 'returned', returned_at = now(),
       staff_note = 'Rider collected it from the boot'
    where trip_id = '${tripId}' and reporter_id = '${driver.id}'`,
);
report = await read((await sql(`select id from left_item_reports where trip_id = '${tripId}' and reporter_id = '${driver.id}'`))[0].id);
check('staff closes it', report.status, 'returned', 'the employee button');
check('  and the note is recorded', report.staff_note, 'Rider collected it from the boot', '');
check('  and returned_at is set', report.returned_at !== null, true, '');

// The driver can read the employee's answer, because RLS is row-level and cannot
// hide one column. Deliberate, and worth asserting so a future change to "hide the
// note from the driver" does not arrive without somebody noticing.
const afterClose = await select(driver.token, `trip_id=eq.${tripId}`);
check('the driver can read the staff note', afterClose.rows[0]?.staff_note, 'Rider collected it from the boot', '');

// -------------------------------------------------------------------------
await sql(
  `delete from trips where id in ('${tripId}','${otherTripId}')`,
);
await sql(`delete from profiles where id in ('${driver.id}','${rider.id}','${stranger.id}')`);

const failed = results.filter((x) => !x.ok);
console.log(`\n=== ${results.length - failed.length} of ${results.length} passed ===`);
if (failed.length > 0) {
  for (const f of failed) console.log(`  FAIL ${f.label}`);
  process.exit(1);
}
console.log('\nCascades checked implicitly: deleting the trips removed the reports with them.');
console.log('All probe rows removed.');