// Removes every throwaway driver the driver-accept verification created, and the
// rides attached to them.
//
//   node toolchain/cleanup-accept-checks.mjs
//
// The rider's own rides are left alone; only rows whose driver is one of these
// tagged accounts are touched. Worth running because each verification leaves a
// live `accept-check driver` behind on purpose -- the rider's card cannot resolve
// a driver that has been deleted -- and a pile of them makes `contact` harder to
// reason about and the offers table harder to read.

import { readEnvOrFail } from './read-env.mjs';

const admin = readEnvOrFail('toolchain/supabase-admin.env', [
  'SUPABASE_PROJECT_REF',
  'SUPABASE_ADMIN_TOKEN',
]);

const sql = async (query) => {
  const res = await fetch(
    'https://api.supabase.com/v1/projects/' + admin.SUPABASE_PROJECT_REF +
      '/database/query',
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

const NAME = 'accept-check driver';

// Cancelled rather than deleted: a trip the rider actually rode is history, and
// the verification rides were never ridden. Removing the rows outright would take
// the fare history with them.
const rides = await sql(
  `update trips set state = 'cancelled', cancelled_at = now()
    where driver_id in (select id from profiles where full_name = '${NAME}')
      and state not in ('completed', 'cancelled')
    returning id`,
);
const had = (
  await sql(`select count(*)::int as n from profiles where full_name = '${NAME}'`)
)[0].n;

const offers = await sql(
  `delete from offers where driver_id in (select id from profiles where full_name = '${NAME}') returning id`,
);
const locations = await sql(
  // No `returning id`: `driver_locations` is keyed on `driver_id`, so there is no
  // `id` column to return. Counting the rows first is the honest way to report it.
  `with gone as (
       delete from driver_locations
        where driver_id in (select id from profiles where full_name = '${NAME}')
        returning driver_id
     ) select count(*)::int as n from gone`,
);
const locationsRemoved = locations[0]?.n ?? 0;
// Vehicles before profiles: `profiles.vehicle_id` points at one, and the delete
// is refused rather than nulling the column if the order is wrong.
await sql(
  `delete from vehicles where owner_id in (select id from profiles where full_name = '${NAME}')`,
);
const profiles = await sql(
  `delete from profiles where full_name = '${NAME}' returning id`,
);
// Auth last. A confirmed auth user with no profile is invisible to anybody
// auditing afterwards.
const auth = await sql(
  `delete from auth.users where email like 'accept-check-%@example.test' returning id`,
);

console.log(
  `cleaned ${had} throwaway driver(s): ${rides.length} ride cancelled, ` +
    `${offers.length} offer, ${locationsRemoved} location, ${profiles.length} profile, ` +
    `${auth.length} auth user`,
);

const open = await sql(
  `select count(*)::int as n from trips where state not in ('completed','cancelled')`,
);
console.log(`open rides remaining: ${open[0].n}`);