// Has any trip actually been settled twice?
//
//   node toolchain/verify-no-double-settlement.mjs
//
// `complete-trip` paid twice on a repeat call until the `alreadySettled` guard
// went in -- see the comment in `supabase/functions/complete-trip/handler.ts`.
//
// The guard stops it happening again. It does not undo anything the old code
// wrote, and "no real ride was affected" is a claim about the database that has
// to be read rather than assumed. So this reads it, and it is worth rerunning
// after any change to settlement.
//
// Reports the ledger and payout totals as well as the offenders, because "0
// offenders" out of an empty table is not the same statement as "0 offenders".

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

// A settled trip writes exactly one `fare` and one `commission` ledger entry and
// exactly one payout. Anything above that was written twice.
//
// `kind = 'void'` is excluded deliberately: a trip that was charged and then
// voided carries a void entry by design, and counting it as a second fare would
// report a correctly-refunded trip as a double payment.
const totals = (
  await sql(`
    select
      (select count(*) from ledger_entries where kind = 'fare')::int       as fare_rows,
      (select count(*) from ledger_entries where kind = 'commission')::int as commission_rows,
      (select count(*) from ledger_entries where kind = 'void')::int       as void_rows,
      (select count(*) from payouts)::int                                  as payout_rows,
      (select coalesce(sum(amount_ghs), 0) from payouts)::numeric          as payout_total,
      (select count(*) from trips where state = 'completed')::int          as completed_trips`)
)[0];

const offenders = await sql(`
  select t.id,
         t.state,
         t.fare_ghs,
         t.completed_at,
         (select count(*) from ledger_entries l
           where l.trip_id = t.id and l.kind = 'fare')::int as fare_rows,
         (select count(*) from payouts p where p.trip_id = t.id)::int as payout_rows,
         (select string_agg(p.amount_ghs::text, ' + ')
            from payouts p where p.trip_id = t.id) as payouts
    from trips t
   where (select count(*) from payouts p where p.trip_id = t.id) > 1
      or (select count(*) from ledger_entries l
            where l.trip_id = t.id and l.kind = 'fare') > 1
   order by t.completed_at desc nulls last
   limit 20`);

console.log('ledger and payouts as they stand:');
console.log(`  fare entries        ${totals.fare_rows}`);
console.log(`  commission entries  ${totals.commission_rows}`);
console.log(`  void entries        ${totals.void_rows}`);
console.log(`  payouts             ${totals.payout_rows}  totalling GH¢${totals.payout_total}`);
console.log(`  completed trips     ${totals.completed_trips}\n`);

console.log(`trips settled more than once: ${offenders.length}`);
for (const o of offenders) {
  console.log(
    `  ${o.id}  ${o.state}  fare ${o.fare_ghs}  ` +
      `fare rows ${o.fare_rows}  payouts ${o.payout_rows} [${o.payouts ?? ''}]`,
  );
}

if (offenders.length > 0) {
  console.log(
    '\nThese are real: the ledger counted their fares more than once, so a ' +
      'driver balance built from payouts is overstated by the repeated entries.',
  );
  process.exit(1);
}
console.log('\nNone. Every completed trip carries one fare and one payout.');