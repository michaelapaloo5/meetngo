import { assert } from 'https://deno.land/std@0.224.0/testing/asserts.ts';

// Static assertions over `cancel-trip/clients.ts`'s own text.
//
// This file is the only one in the function that constructs a client, and it is
// unreachable from a fake-`CancelDeps` test: `handler.ts` takes ports, so every
// behavioural test in `cancel_handler.test.ts` is blind to which client each port
// uses and to which columns a port writes. That blindness is not hypothetical.
// Two mutations of this file were tried against the suite as it stood and both
// survived: dropping the `.select('*')` from the cancel write, which is what
// makes a zero-row match distinguishable from a write, and dropping
// `cancelled_at` from that write. Both are invisible to a port-level test by
// construction -- the port returns whatever the fake is told to return.
//
// This is `clients_wiring.test.ts`'s mechanism, and for its stated reason: the
// obvious fix is to import supabase-js here and drive the ports with a stub
// fetch, which was rejected because it makes the Deno test job depend on a cold
// remote fetch and this tree has no lockfile. Asserting the text costs no
// network, no environment and no supabase-js. The cost is the same one that file
// names: these assertions are brittle to reformatting and cannot see a semantic
// change that keeps the same tokens. They are a floor, and what they guarantee is
// that a dropped `.select()`, a dropped filter and a dropped column cannot land
// silently.

const CLIENTS = new URL('../cancel-trip/clients.ts', import.meta.url);
const raw = await Deno.readTextFile(CLIENTS);

// Comments are stripped before anything is matched. They have to be: a comment
// that names `.select()` is a sentence about a select, not a select, and an
// assertion that cannot tell the difference fails on a reworded comment and
// passes on a real change.
const source = raw.replace(/^\s*\/\/.*$/gm, '');

const has = (body: string, pattern: RegExp): boolean =>
  pattern.test(body.replace(/\s+/g, ' '));

// A quote class inlined in each pattern rather than interpolated, so a pattern
// cannot be assembled out of a half-escaped string. A `'` inside a double-quoted
// JS string is the identity case; inside a regex literal it would end the
// literal, so every pattern below is a double-quoted `new RegExp` and every
// backslash in it is doubled.
const eq = (column: string, value: string) =>
  new RegExp(`\\.eq\\(\\s*['"\`]\\s*${column}\\s*['"\`]\\s*,\\s*${value}\\s*\\)`);

const from = (table: string) =>
  new RegExp(`from\\(\\s*['"\`]\\s*${table}\\s*['"\`]\\s*\\)`);

const assigns = (key: string, value: string) =>
  new RegExp(`${key}\\s*:\\s*${value}`);

// The body of one `name: (...) => { ... }` member of the returned object,
// brace-matched so an assertion covers the member and not the whole file.
//
// The match starts at the member's own `=> {` rather than at its name, because
// `recordCompensation` destructures its argument -- `async ({ driverId, ... })`
// -- and a brace-match from the name would return that parameter list and stop.
const member = (name: string): string => {
  const nameAt = source.search(new RegExp(`^\\s{4}${name}:`, 'm'));
  assert(nameAt >= 0, `cancel-trip/clients.ts has no member named ${name}`);
  // The brace to balance is the one after the member's own `=>`, not the first
  // `{` on the line: `recordCompensation` destructures its argument
  // (`async ({ driverId, ... }) => {`) and a brace-match from the name would
  // balance against that parameter list and stop there.
  const arrowAt = source.indexOf('=>', nameAt);
  assert(arrowAt > nameAt, `cancel-trip/clients.ts member ${name} has no arrow`);
  const open = source.indexOf('{', arrowAt);
  let depth = 0;
  for (let i = open; i < source.length; i++) {
    if (source[i] === '{') {
      depth++;
    } else if (source[i] === '}') {
      depth--;
      if (depth === 0) return source.slice(nameAt, i + 1);
    }
  }
  throw new Error(`cancel-trip/clients.ts member ${name} is not brace-balanced`);
};

Deno.test('the only client is the service key, and nothing is forwarded onto it', () => {
  // supabase-js only sets `Authorization` when the request has none
  // (`@supabase/supabase-js@2.45.4/dist/module/lib/fetch.js`), so a service key
  // paired with a forwarded bearer leaves the bearer as the effective credential
  // rather than the key. Measured by driving the shipped client with a stub
  // fetch. This is the same construction `offers/clients.ts` unpicked from Task 6.
  assert(
    has(source, new RegExp(`Deno\\s*\\.\\s*env\\s*\\.\\s*get\\(\\s*['"\`]\\s*SUPABASE_SERVICE_ROLE_KEY`)),
    'clients.ts must build its client on SUPABASE_SERVICE_ROLE_KEY',
  );
  assert(
    !has(source, new RegExp('Authorization')),
    'clients.ts must not mention Authorization: a forwarded bearer is the Task 6 defect',
  );
  assert(
    !has(source, new RegExp('global\\s*:\\s*\\{\\s*headers')),
    'clients.ts must not pass a global header block for the same reason',
  );
  assert(
    !has(source, new RegExp('SUPABASE_ANON_KEY')),
    'cancel-trip has no user-scoped port, so it has no reason to build an anon-keyed client',
  );
});

Deno.test('authenticate passes the token to getUser explicitly', () => {
  const body = member('authenticate');
  // The argumentless form is header-dependent, not broken: it resolves the user on
  // a client carrying a forwarded bearer and answers `Auth session missing!` on one
  // with none. `cancel-trip` forwards nothing, so it has to pass the token.
  assert(
    has(body, new RegExp('getUser\\(\\s*token\\s*\\)')),
    'authenticate must call getUser(token); the argumentless form issues zero requests on a headerless client',
  );
  assert(
    !has(body, new RegExp('getUser\\(\\s*\\)')),
    'authenticate must not call the argumentless getUser()',
  );
});

Deno.test('the trip read is a trips read with limit(1)', () => {
  const body = member('readTrip');
  assert(has(body, from('trips')), 'readTrip must read the trips table');
  assert(
    has(body, new RegExp('\\.limit\\(\\s*1\\s*\\)')),
    'readTrip must use limit(1) rather than single(): a zero-row read is a 200 with [] and the client turns that into data = null itself',
  );
  assert(has(body, eq('id', 'tripId')), "readTrip must filter on the trip's id");
});

Deno.test('the cancel write is single-winner, readable, and writes both columns', () => {
  const body = member('writeCancel');
  assert(
    has(body, eq('state', 'fromState')),
    'writeCancel must filter on the state it read, or two cancels both answer cancelled: true',
  );
  // The whole finding: an update with no `select` answers `data = null` and
  // `error = null` whether it wrote a row or matched none, which is the silent
  // no-op `offers/clients.ts` measures. It also answers a 200 whose body carries
  // no `cancelled_at`, so the handler would echo the pre-update null.
  assert(
    has(body, new RegExp('\\.select\\(')),
    "writeCancel must carry a .select(); without one a zero-row match cannot be told from a write",
  );
  assert(
    has(body, eq('id', 'tripId')),
    "writeCancel must filter on the trip's id",
  );
  assert(
    has(body, assigns('state', "['\"`]\\s*cancelled\\s*['\"`]")),
    "writeCancel must set state to 'cancelled'",
  );
  // Nothing else in the build writes this column. It exists on the table
  // (init.sql:69) and the verification harness populates it for a cancelled trip
  // (supabase/tests/verify_migration.sql:244), so a cancellation that leaves it
  // null makes the column permanently unpopulated.
  assert(
    has(body, assigns('cancelled_at', 'cancelledAt')),
    'writeCancel must write cancelled_at; no other code in the build does',
  );
});

Deno.test('the driver release puts the driver back online', () => {
  const body = member('releaseDriver');
  assert(
    has(body, assigns('availability', "['\"`]\\s*online\\s*['\"`]")),
    "releaseDriver must set availability back to 'online', or the driver is stuck on onTrip",
  );
  assert(
    has(body, from('profiles')),
    "releaseDriver must write the driver's profile row",
  );
  assert(
    has(body, eq('id', 'driverId')),
    "releaseDriver must filter on the driver's id",
  );
});

Deno.test('the offer release is scoped to the trip and to pending offers', () => {
  const body = member('releaseOffers');
  assert(
    has(body, from('offers')),
    'releaseOffers must write the offers table',
  );
  assert(
    has(body, eq('trip_id', 'tripId')),
    "releaseOffers must filter on the trip's id",
  );
  assert(
    has(body, eq('state', "['\"`]\\s*pending\\s*['\"`]")),
    "releaseOffers must only release the trip's pending offers",
  );
  assert(
    has(body, assigns('state', "['\"`]\\s*released\\s*['\"`]")),
    "releaseOffers must set state to 'released', which the offer_state enum carries (init.sql:7)",
  );
});

Deno.test('the compensation is demo money, a compensation, and the policy fee', () => {
  const body = member('recordCompensation');
  assert(
    has(body, from('ledger_entries')),
    'recordCompensation must insert into ledger_entries',
  );
  assert(
    has(body, new RegExp('\\.insert\\(')),
    'recordCompensation must be an insert',
  );
  assert(
    has(body, assigns('amount_ghs', 'amountGhs')),
    'recordCompensation must write the amount the policy function decided, not a literal',
  );
  assert(
    has(body, assigns('kind', "['\"`]\\s*compensation\\s*['\"`]")),
    "recordCompensation must write kind 'compensation'; the ledger_entries check constraint allows nothing else (init.sql:126)",
  );
  // `alter table ledger_entries add constraint ledger_demo_only check (is_demo)`
  // (init.sql:178) refuses the insert outright, so this is not a convention.
  assert(
    has(body, assigns('is_demo', 'true')),
    'recordCompensation must set is_demo, or the ledger_entries check constraint refuses the row',
  );
  assert(
    has(body, assigns('driver_id', 'driverId')),
    'recordCompensation must attribute the money to the driver',
  );
  assert(
    has(body, assigns('trip_id', 'tripId')),
    'recordCompensation must attribute the money to the trip',
  );
});
