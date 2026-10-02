import { readFileSync } from 'node:fs';
const env = {};
for (const f of ['toolchain/supabase-admin.env','toolchain/apk-build.env']) {
  let t; try { t = readFileSync(f,'utf8'); } catch { continue; }
  for (const line of t.split('\n')) {
    const m = /^\s*([A-Z_0-9]+)=(.*)$/.exec(line);
    if (m && m[2]) env[m[1]] ??= m[2].replace(/^["']|["']$/g,'');
  }
}
const REF = env.SUPABASE_PROJECT_REF;
const MGMT = 'https://api.supabase.com/v1/projects/' + REF + '/database/query';
const h = { Authorization: 'Bearer ' + env.SUPABASE_ADMIN_TOKEN, 'Content-Type': 'application/json' };
const q = async (s) => { const r = await fetch(MGMT,{method:'POST',headers:h,body:JSON.stringify({query:s})}); const b = await r.json(); if(!r.ok) throw new Error(b.message); return Array.isArray(b)?b:(b.value??b); };

const t = (await q(`select id, state, rider_id, driver_id, vehicle_id from trips where pickup->>'label' = 'device-check Osu' order by created_at desc limit 1`))[0];
const rider = (await q(`select u.email from auth.users u where u.id = '${t.rider_id}'`))[0];
const PASSWORD = 'DeviceCheck-123!';
console.log('trip', t.id.slice(0,8), t.state, '| rider', rider.email);

const su = await fetch(`https://${REF}.supabase.co/auth/v1/token?grant_type=password`, {
  method:'POST', headers:{ 'Content-Type':'application/json', apikey: env.SUPABASE_ANON_KEY },
  body: JSON.stringify({ email: rider.email, password: PASSWORD }),
});
const sess = await su.json();
if (!sess.access_token) { console.log('rider sign-in failed:', JSON.stringify(sess).slice(0,200)); process.exit(1); }
console.log('signed in as the rider on this trip:', sess.user.id === t.rider_id);
console.log('');
console.log('--- rider asks the contact function about their driver ---');
const r = await fetch(`https://${REF}.supabase.co/functions/v1/contact`, {
  method:'POST',
  headers:{ 'Content-Type':'application/json', apikey: env.SUPABASE_ANON_KEY, Authorization:'Bearer '+sess.access_token },
  body: JSON.stringify({ tripId: t.id }),
});
const b = await r.json();
console.log('status', r.status);
console.log(JSON.stringify(b, null, 2));
console.log('');
const ok = [
  ['role is driver', b.role === 'driver'],
  ['name present', typeof b.name === 'string' && b.name.length > 0],
  ['phone present', typeof b.phone === 'string' && b.phone.length > 0],
  ['callable true', b.callable === true],
  ['driver object present', !!b.driver],
  ['plate present', !!(b.driver?.vehicle?.plate)],
  ['car make/model present', !!(b.driver?.vehicle?.make)],
  ['rating is a number or null', b.driver?.rating === null || typeof b.driver?.rating === 'number'],
];
let pass = 0;
for (const [label, got] of ok) { console.log((got ? 'PASS  ' : 'FAIL  ') + label); if (got) pass++; }
console.log('\n' + pass + '/' + ok.length);
