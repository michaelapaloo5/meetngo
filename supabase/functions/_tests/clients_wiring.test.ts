import { assert } from 'https://deno.land/std@0.224.0/testing/asserts.ts';

// Static assertions over `clients.ts`'s own text.
//
// This file is the only one in the function that constructs a client, and it is
// not reachable from a fake-`OfferDeps` test: `handler.ts` takes ports, so every
// behavioural test in the suite is blind to which client each port uses. That
// blindness is not hypothetical. Four mutations of this file were tried against
// the suite as it stood and all four survived, including moving `accept_offer`
// onto the service client -- which turns the single-winner RPC into a no-op
// (`accept_offer` refuses every caller whose `auth.uid()` is not the offer's
// driver, and a service request has a NULL `auth.uid()`, probe 2) while the
// whole suite stays green.
//
// The obvious fix is to import supabase-js here and drive the ports with a stub
// fetch. That was rejected: it makes the Deno test job depend on a cold remote
// fetch, and this tree has no lockfile, so it trades a known coverage gap for a
// CI failure mode. Asserting the file's text costs no network, no environment
// and no supabase-js, and it fails on eight mutations of `clients.ts`: the four
// that a behavioural suite could not see at all, and four more that guard the
// decline write's filters and the absence of a trip read.
//
// The cost is honest and worth naming: these assertions match source text, so
// they are brittle to reformatting and they cannot see a semantic change that
// keeps the same tokens. They are a floor, not a substitute for driving the
// client. What they do guarantee is that a client swap, a dropped filter or a
// dropped `.select()` cannot land silently, which is the failure mode that has
// no other guard here.

const CLIENTS = new URL('../offers/clients.ts', import.meta.url);
const raw = await Deno.readTextFile(CLIENTS);

// Comments are stripped before anything is matched. They have to be: a comment
// that names `Authorization` is a sentence about a header, not a header, and an
// assertion that cannot tell the difference will fail on a reworded comment and
// pass on a real change. A `//` inside a string would be mangled by this, and
// there is none in this file.
const source = raw.replace(/^\s*\/\/.*$/gm, '');

// Every pattern below tolerates whitespace and newlines between tokens, because
// the call chains in this file are wrapped across lines and `user.from(` does
// not appear literally in any of them.
const has = (body: string, pattern: RegExp): boolean => pattern.test(body.replace(/\s+/g, ' '));

// A quote class for matching a string literal without depending on which quote
// the file happens to use. A single-quote-only pattern is a test that goes dead
// the moment the file is reformatted to double quotes, which is a silent loss of
// coverage rather than a failure -- and that is exactly how the `trips` pattern
// was caught surviving `service.from("trips")`.
const Q = "['\"`]";

// The body of one `name: async (...) => { ... }` member of the returned object,
// brace-matched so an assertion covers the member and not the whole file.
const member = (name: string): string => {
  const start = source.search(new RegExp(`^\\s{4}${name}:`, 'm'));
  assert(start >= 0, `clients.ts has no member named ${name}`);
  let depth = 0;
  let seen = false;
  for (let i = start; i < source.length; i++) {
    if (source[i] === '{') {
      depth++;
      seen = true;
    } else if (source[i] === '}') {
      depth--;
      if (seen && depth === 0) return source.slice(start, i + 1);
    }
  }
  throw new Error(`clients.ts member ${name} is not brace-balanced`);
};

// `buildClients` on its own, so an assertion about the two clients cannot be
// satisfied or broken by a later function's text.
const buildClients = (): string => {
  const start = source.indexOf('export function buildClients');
  assert(start >= 0, 'clients.ts has no buildClients');
  const end = source.indexOf('\nexport ', start + 1);
  return end > start ? source.slice(start, end) : source.slice(start);
};

Deno.test('acceptOffer reaches the user client, and only the user client', () => {
  const body = member('acceptOffer');
  assert(
    has(body, /user\s*\.\s*rpc\s*\(/),
    'acceptOffer must call accept_offer on the user client, or auth.uid() is not the driver and every accept returns false',
  );
  // The whole file, not just the member: a `service.rpc` anywhere is the defect.
  assert(
    !has(source, /service\s*\.\s*rpc\s*\(/),
    'clients.ts calls rpc on the service client; accept_offer can never be reached with a service-role key, because it refuses any caller whose auth.uid() is not the offer\'s driver_id (migration:324) and offers.driver_id is not null (migration:80) -- measured as accepted = false with both ids null (probe 2)',
  );
});

Deno.test('the ownership read reaches the user client', () => {
  const body = member('readOffer');
  assert(has(body, /user\s*\.\s*from\s*\(/), 'readOffer must read the offer on the caller\'s own bearer');
  assert(
    !has(body, /service\s*\.\s*from\s*\(/),
    'readOffer must not use the service client: the read is what makes driver reads own offers (migration:530) evidence about this driver',
  );
});

Deno.test('the decline write is the service client, with all three filters and a .select()', () => {
  const body = member('writeDecline');
  assert(
    has(body, /service\s*\.\s*from\s*\(/),
    'the decline write must use the service client: offers has no UPDATE policy, so as authenticated it matches zero rows (probes 6 and 7)',
  );
  // These patterns are built from template strings, and that is a hazard rather
  // than a style: a template string processes escapes the way a string literal
  // does, so every backslash below has to be doubled. `\\.eq\\(` is the
  // two-character sequence `\.` in the resulting RegExp source; written as `\.eq\(` it
  // would be an identity escape, the backslash would vanish, and the parentheses
  // would become a capture group that does not match the text it was written
  // for -- a pattern that silently tests nothing. Round 1 shipped exactly that
  // bug with `"eq\('id'\""` built from a plain string, and it failed as a test
  // that could not see the thing it named. Do not "tidy" the doubling.
  const filters: [RegExp, string][] = [
    [new RegExp(`\\.eq\\(\\s*${Q}id${Q}\\s*,\\s*offerId\\s*\\)`), ".eq('id', offerId)"],
    [new RegExp(`\\.eq\\(\\s*${Q}driver_id${Q}\\s*,\\s*driverId\\s*\\)`), ".eq('driver_id', driverId)"],
    [new RegExp(`\\.eq\\(\\s*${Q}state${Q}\\s*,\\s*${Q}pending${Q}\\s*\\)`), ".eq('state', 'pending')"],
  ];
  for (const [pattern, label] of filters) {
    assert(
      pattern.test(body),
      `the decline write is missing ${label}; the three filters are what stop it matching another driver's or an already-terminal offer (probe 8)`,
    );
  }
  assert(
    /\.select\(/.test(body),
    'the decline write needs .select() to make the affected row count readable: measured, without it the write returns data = null and count = null with error = null whatever happened, which is a silent no-op reported as a decline',
  );
});

Deno.test('the user client is the anon key with the caller\'s bearer, and the service client carries no header', () => {
  const build = buildClients();
  const anonAt = build.indexOf('SUPABASE_ANON_KEY');
  const serviceAt = build.indexOf('SUPABASE_SERVICE_ROLE_KEY');
  assert(anonAt >= 0 && serviceAt >= 0, 'buildClients must read both keys');
  // The forwarded Authorization must sit on the anon-key client, and only there.
  // Everything up to the service key is the user client's construction.
  const userHalf = build.slice(0, serviceAt);
  assert(
    /headers\s*:\s*\{\s*Authorization/.test(userHalf),
    'the caller\'s Authorization header must be forwarded onto the anon-key (user) client, or PostgREST resolves no role and accept_offer refuses everything',
  );
  assert(
    !has(build.slice(serviceAt), /Authorization/),
    'no Authorization may be forwarded onto the service-role client: supabase-js only sets Authorization when the request has none, so a forwarded bearer would become the effective credential and silently turn the service client into a user client (the construction Task 6 had to be unpicked from)',
  );
});

Deno.test('there is no privileged read of a trip', () => {
  // The trip-state read existed to feed a classifier verdict the handler does
  // not act on, and it had to be the service client to see the row at all --
  // `driver reads assigned trips` is `using (driver_id = auth.uid())` and a
  // trip's driver_id is NULL until accept_offer matches it (probe 11). It is
  // gone, and the trip is not something this function has any use for.
  // Quote-agnostic. This pattern was single-quote-only and a reviewer verified
  // that reintroducing the privileged read as `service.from("trips")` passed it
  // -- so the one assertion guarding the removal F1 made was a quote style from
  // dead, on the exact read whose return N1's stale comment would invite.
  assert(
    !new RegExp(`from\\(\\s*${Q}trips${Q}\\s*\\)`).test(source),
    "clients.ts reads the trips table; the offer row carries no trip state this function acts on, and a privileged read of a trip is a read of the rider's pickup, dropoff and fare that nothing here needs",
  );
});
