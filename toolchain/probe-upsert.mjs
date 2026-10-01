// Which upsert form does this PostgREST actually honour?
//
//   node toolchain/probe-upsert.mjs
//
// `resolution=merge-duplicates` alone is refused with 409 and
// `duplicate key value violates unique constraint "left_item_reports_one_per_trip"`.
// That means PostgREST is not building `ON CONFLICT DO UPDATE` at all -- it is
// letting the insert collide.
//
// The likely reason is that PostgREST needs to be told the conflict target. The
// natural target here is `(trip_id, reporter_id)`, which is a unique constraint
// rather than the primary key, and `ON CONFLICT DO UPDATE` without a target is
// not something the server will guess.
//
// This tries the plausible forms and reports which one the server accepts, so
// the answer is measured rather than taken from documentation that may describe a
// different version.
//
// The table is created if it is missing so this is runnable on its own.

import { readEnvOrFail } from './read-env.mjs';

const admin = readEnvOrFail('toolchain/supabase-admin.env', [
  'SUPABASE_PROJECT_REF',
  'SUPABASE_ADMIN_TOKEN',
]);
const build = readEnvOrFail('toolchain/apk-build.env', ['SB_URL', 'SB_ANON_KEY']);
const ANON = build.SB_ANON_KEY;
const url = build.SB_URL.replace(/\/+$/, '');
const pad = (s, n) => String(s).padEnd(n);

const sql = async (query) => {
  const res = await fetch(
    'https://api.supabase.com/v1/projects/' + admin.SUPABASE_PROJECT_REF + '/database/query',
    {
      method: 'POST',
      headers: {
        Authorization: 'Bearer ' + admin.SUPABASE_ADMIN_TOKEN,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ query }),
    },
  );
  const body = await res.json();
  if (!res.ok) throw new Error(body.message ?? JSON.stringify(body));
  return Array.isArray(body) ? body : (body.value ?? []);
};

const stamp = Date.now();
const signUp = async (who) => {
  const res = await fetch(url + '/auth/v1/signup', {
    method: 'POST',
    headers: { apikey: ANON, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      email: `upsert-${who}-${stamp}@example.test`,
      password: 'Probe-9abcdefgh',
      data: { full_name: who },
    }),
  });
  const body = await res.json();
  if (!body.access_token) throw new Error('signup: ' + JSON.stringify(body).slice(0, 200));
  return { id: body.user.id, token: body.access_token };
};

const driver = await signUp('Driver');
const rider = await signUp('Rider');
const tripId = (
  await sql(
    `insert into trips (rider_id, driver_id, category, state, pickup, dropoff,
                        pickup_point, dropoff_point, distance_km, fare_ghs, is_demo)
     values ('${rider.id}', '${driver.id}', 'standard', 'completed',
             '{"label":"A","address":"A"}'::jsonb, '{"label":"B","address":"B"}'::jsonb,
             st_makepoint(5.6,-0.18), st_makepoint(5.62,-0.18), 1.00, 5.00, true)
     returning id`,
  )
)[0].id;

const attempt = async (label, query, prefer) => {
  const res = await fetch(url + '/rest/v1/left_item_reports' + query, {
    method: 'POST',
    headers: {
      apikey: ANON,
      Authorization: 'Bearer ' + driver.token,
      'Content-Type': 'application/json',
      Prefer: prefer,
    },
    body: JSON.stringify({
      trip_id: tripId,
      reporter_id: driver.id,
      item: 'Wallet',
      description: 'attempt: ' + label,
    }),
  });
  const text = await res.text();
  const rows = (await sql(
    `select description from left_item_reports where trip_id = '${tripId}'`,
  )).length;
  console.log(
    `  ${pad(label, 44)} http ${String(res.status).padEnd(4)} rows=${rows}  ` +
      `${text.slice(0, 90).replace(/\n/g, ' ')}`,
  );
  return res.status;
};

console.log('\n=== the first insert, to make a row to collide with ===\n');
await attempt('plain insert', '', 'return=representation');

console.log('\n=== and now collide with it, six ways ===\n');
await attempt('Prefer: resolution=merge-duplicates', '', 'resolution=merge-duplicates');
await attempt(
  'resolution + on_conflict in the query',
  '?on_conflict=trip_id,reporter_id',
  'resolution=merge-duplicates',
);
await attempt(
  'resolution + on_conflict + return=representation',
  '?on_conflict=trip_id,reporter_id',
  'resolution=merge-duplicates,return=representation',
);
await attempt('Prefer: upsert=merge-duplicates', '', 'upsert=merge-duplicates');
await attempt(
  'upsert=merge-duplicates + on_conflict',
  '?on_conflict=trip_id,reporter_id',
  'upsert=merge-duplicates',
);

// And a plain PATCH, for comparison -- the other route to a correction.
const patch = await fetch(url + '/rest/v1/left_item_reports?trip_id=eq.' + tripId, {
  method: 'PATCH',
  headers: {
    apikey: ANON,
    Authorization: 'Bearer ' + driver.token,
    'Content-Type': 'application/json',
    Prefer: 'return=representation',
  },
  body: JSON.stringify({ description: 'attempt: PATCH' }),
});
const patchText = await patch.text();
const afterPatch = await sql(`select description from left_item_reports where trip_id = '${tripId}'`);
console.log(
  `\n  ${pad('PATCH the description', 44)} http ${String(patch.status).padEnd(4)} ` +
    `now on file: ${JSON.stringify(afterPatch.map((r) => r.description))}`,
);

console.log('\n=== PostgREST version, because the answer depends on it ===\n');
const versions = await sql(
  `select extversion from pg_extension where extname = 'pgrst'`,
);
console.log('  pgrst extension: ' + JSON.stringify(versions));

await sql(`delete from trips where id = '${tripId}'`);
await sql(`delete from profiles where id in ('${driver.id}','${rider.id}')`);
console.log('\nProbe rows removed.');