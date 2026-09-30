// What would be lost if the driver profiles were deleted?
//
//   node toolchain/what-would-be-lost.mjs
//
// The question is worth asking before any DELETE, because the answer decides it.
// Deleting a driver profile cascades: documents, vehicle, trips, ledger entries,
// payouts and the ratings other people wrote about them. Forcing a missing phone
// number costs a driver one field.
//
// This prints the real counts so the choice is made against the data rather than
// against a hunch.

import { readEnv } from './read-env.mjs';

const env = readEnv('toolchain/supabase-admin.env');
const q = async (sql) => {
  const res = await fetch('https://api.supabase.com/v1/projects/' + env.SUPABASE_PROJECT_REF + '/database/query', {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + env.SUPABASE_ADMIN_TOKEN, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(body.message ?? JSON.stringify(body));
  return Array.isArray(body) ? body : (body.value ?? body);
};

const drivers = await q(
  `select p.id, coalesce(nullif(p.full_name,''),'(no name)') as name,
          coalesce(nullif(p.phone,''),'(none)') as phone, p.kyc_status::text as kyc,
          (select count(*) from driver_documents d where d.driver_id = p.id)::int as docs,
          (select count(*) from vehicles v where v.owner_id = p.id)::int as vehicles,
          (select count(*) from trips t where t.driver_id = p.id)::int as trips_driven,
          (select count(*) from ledger_entries l where l.driver_id = p.id)::int as ledger_rows,
          (select count(*) from payouts pay where pay.driver_id = p.id)::int as payouts,
          (select coalesce(sum(pay.amount_ghs),0) from payouts pay where pay.driver_id = p.id)::text as paid_total,
          (select count(*) from ratings r where r.ratee_id = p.id)::int as ratings_received
   from profiles p where p.role = 'driver' order by p.created_at`);

console.log('=== every driver profile, and what deleting it would take with it ===\n');
console.log('  ' + 'name'.padEnd(22) + 'phone'.padEnd(16) + 'kyc'.padEnd(11)
  + 'docs veh trips ledger payout  paid     rated');
console.log('  ' + '-'.repeat(96));
let totalValue = 0;
for (const d of drivers) {
  totalValue += Number(d.paid_total);
  console.log('  ' + String(d.name).slice(0, 21).padEnd(22)
    + String(d.phone).slice(0, 15).padEnd(16)
    + String(d.kyc).padEnd(11)
    + String(d.docs).padStart(4)
    + String(d.vehicles).padStart(4)
    + String(d.trips_driven).padStart(5)
    + String(d.ledger_rows).padStart(7)
    + String(d.payouts).padStart(7)
    + ' ' + Number(d.paid_total).toFixed(2).padStart(7)
    + String(d.ratings_received).padStart(7));
}
console.log('\n  ' + drivers.length + ' driver profile(s); money already paid out: GHS ' + totalValue.toFixed(2));

const missing = drivers.filter((d) => d.phone === '(none)');
console.log('\n=== what a forced phone number would actually change ===');
console.log('  ' + missing.length + ' of ' + drivers.length + ' have no phone number.');

const orphans = await q(
  `select
     (select count(*) from driver_documents)::text as documents,
     (select count(*) from vehicles)::text as vehicles,
     (select count(*) from trips where driver_id is not null)::text as trips,
     (select count(*) from ledger_entries)::text as ledger,
     (select count(*) from payouts)::text as payouts`);
console.log('\n=== the rows that cascade from a delete ===');
console.log('  documents: ' + orphans[0].documents);
console.log('  vehicles:  ' + orphans[0].vehicles);
console.log('  trips:     ' + orphans[0].trips + '  (a trip row is the record of what a rider was charged)');
console.log('  ledger:    ' + orphans[0].ledger + '  (the only per-trip record a driver has of what they are owed)');
console.log('  payouts:   ' + orphans[0].payouts);
console.log('\n  Every one of those is gone for good: `trips.rider_id` cascades from');
console.log('  profiles, so deleting a driver who has also ridden would take their');
console.log('  passenger trips with them.');
