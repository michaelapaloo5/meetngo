import { assert, assertEquals, assertMatch } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { readFileSync } from 'node:fs';

import { pickupOtp } from '../request-ride/otp.ts';

const CODE = /^[1-9][0-9]{3}$/;

Deno.test('pickupOtp is always four digits with no leading zero', () => {
  for (let i = 0; i < 5000; i++) {
    const code = pickupOtp();
    assertMatch(code, CODE, `got ${code}`);
    assertEquals(code.length, 4);
  }
});

Deno.test('pickupOtp never returns 0000, which 1000 + n % 9000 would allow', () => {
  // The naive form maps the first 1000 values of the 2^32 range onto 1000 as
  // well as the 9000 real codes, so 1000 would be roughly twice as likely as
  // any other code. This test cannot prove the sampling is uniform -- that needs
  // a distribution over many more draws than are worth making here -- but it
  // does pin the range the two off-by-one errors would break.
  const seen = new Set<string>();
  for (let i = 0; i < 20000; i++) seen.add(pickupOtp());
  for (const code of seen) {
    assert(Number(code) >= 1000 && Number(code) <= 9999, `out of range: ${code}`);
  }
  assert(seen.size > 100, `only ${seen.size} distinct codes in 20000 draws`);
});

Deno.test('the trip insert carries pickup_otp', () => {
  // The insert lives in `index.ts`, which calls `serve()` at module scope and is
  // therefore unimportable -- the same seam that made the whole of
  // `cancel-trip/index.ts` unreachable until it was split. A static assertion is
  // the precedent this project has already set three times
  // (`clients_wiring.test.ts`, `cancel_clients_wiring.test.ts`,
  // `settlement_clients_wiring.test.ts`): it cannot see a semantic change that
  // keeps the same token, and it is the only thing standing between "no writer"
  // and a driver who can never start a trip.
  const source = readFileSync(
    new URL('../request-ride/index.ts', import.meta.url),
    'utf8',
  );
  const insert = source.slice(source.indexOf('.insert({'), source.indexOf('})', source.indexOf('.insert({')));
  assert(insert.length > 0, 'no insert object found in request-ride/index.ts');
  assert(insert.includes('pickup_otp: pickupOtp()'), 'the trip insert does not mint a pickup code');
});
