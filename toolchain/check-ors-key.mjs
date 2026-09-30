// Is the OpenRouteService key working yet?
//
//   node toolchain/check-ors-key.mjs
//
// The key is a Supabase function secret, so it is not in this repository and
// this script reads it from a file outside it. The `route` function already
// falls through to the keyless OSRM server when the key is refused, so this is
// not a build blocker -- it is a one-line check to run after you flip the
// switch in the HeiGIT dashboard, and it answers whether the switch worked
// without a rebuild.
//
// Both the new service-prefixed URL and the deprecated one are tried, because
// a 403 from either is the same account-level refusal and only a change in the
// answer tells you anything.
//
// 401 and 403 mean different things and the difference decides what to do:
//   401  a bad key. Nothing about the account will fix it.
//   403  the account is refused. Email confirmation and API access both matter.

import { readFileSync } from 'node:fs';

const KEY_FILE = 'C:/Users/antoi/AppData/Local/Temp/opencode/ors-key.txt';

let key;
try {
  key = readFileSync(KEY_FILE, 'utf8').trim();
} catch {
  console.log('  no key at ' + KEY_FILE);
  console.log('  that is deliberate: the key is a server-side secret and is not in the repo.');
  console.log('  to check it, put the key in that file and run this again.');
  process.exit(2);
}
if (!key) {
  console.log('  the key file is empty');
  process.exit(2);
}

const BODY = JSON.stringify({ coordinates: [[-0.187, 5.6037], [-0.1666, 5.6052]] });
const NEW = 'https://api.heigit.org/openrouteservice/v2/directions/driving?profile=driving-car';
const OLD = 'https://api.openrouteservice.org/v2/directions/driving?profile=driving-car';

async function tryUrl(label, url) {
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { Authorization: key, 'Content-Type': 'application/json' },
      body: BODY,
      signal: AbortSignal.timeout(20000),
    });
    const text = await res.text();
    console.log('  [' + res.status + ']  ' + label);
    if (res.ok) {
      const body = JSON.parse(text);
      const km = (body.routes?.[0]?.summary?.distance ?? 0) / 1000;
      console.log('        WORKS -- routed ' + km.toFixed(2) + ' km');
      return true;
    }
    let said = text.replace(/\s+/g, ' ').trim();
    if (said.length > 90) said = said.slice(0, 90);
    console.log('        refused: ' + said);
    if (res.status === 401) {
      console.log('        401 is a BAD KEY. The `route` function will never use it.');
    } else if (res.status === 403) {
      console.log('        403 is an ACCOUNT refusal, not a bad key. In HeiGIT check that');
      console.log('        the email is confirmed and API access is switched on.');
    }
    return false;
  } catch (e) {
    console.log('  [err] ' + label + '  ' + e.message);
    return false;
  }
}

console.log('=== OpenRouteService key check ===');
const works = await tryUrl('new service-prefixed URL (what the notice asks for)', NEW);
await tryUrl('deprecated URL', OLD);

console.log('');
if (works) {
  console.log('THE KEY WORKS. The `route` function will use it on the next request, with no');
  console.log('app rebuild and no redeploy -- it reads the secret at invocation time.');
} else {
  console.log('STILL REFUSED. Nothing to do: `route` is running on the keyless OSRM server,');
  console.log('which needs no account. Navigation works today.');
}
process.exit(works ? 0 : 1);
