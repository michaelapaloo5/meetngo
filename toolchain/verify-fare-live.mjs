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
const rider = (await q('select u.email from auth.users u join profiles p on p.id = u.id where p.role = \'rider\' and u.email like \'device-check-rider-%\' order by u.created_at desc limit 1'))[0];
const tok = (await (await fetch(`https://${REF}.supabase.co/auth/v1/token?grant_type=password`, {
  method:'POST', headers:{'Content-Type':'application/json', apikey: env.SUPABASE_ANON_KEY},
  body: JSON.stringify({ email: rider.email, password: 'DeviceCheck-123!' }),
})).json()).access_token;
console.log('rider:', rider.email);

// A short hop: 2.0 km. Standard floors at 23.00.
const short = { pickup:{lat:5.5639,lng:-0.1950}, dropoff:{lat:5.5719,lng:-0.1950} };
const long  = { pickup:{lat:5.5639,lng:-0.1950}, dropoff:{lat:5.6639,lng:-0.1950} };
for (const [label, body, km] of [['short 2.0km', short, 2.0], ['long 11.1km', long, 11.1]]) {
  for (const cat of ['lite','standard','premium']) {
    const r = await fetch(`https://${REF}.supabase.co/functions/v1/request-ride`, {
      method:'POST', headers:{'Content-Type':'application/json', apikey: env.SUPABASE_ANON_KEY, Authorization:'Bearer '+tok},
      body: JSON.stringify({ ...body, category: cat }),
    });
    const b = await r.json();
    const fare = b?.trip?.fareGhs ?? b?.fareGhs ?? (b?.trip ? JSON.stringify(b.trip.fare_ghs ?? b.trip.fareGhs ?? 'n/a') : JSON.stringify(b).slice(0,60));
    console.log(`  ${label.padEnd(12)} ${cat.padEnd(9)} status ${r.status}  fare ${fare === undefined ? JSON.stringify(b).slice(0,90) : fare}`);
  }
}
