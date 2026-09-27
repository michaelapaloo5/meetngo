import { assert, assertEquals } from 'https://deno.land/std@0.224.0/testing/asserts.ts';

// Static assertions over the two port builders this task ships:
// `complete-trip/clients.ts` and `demo-pay/index.ts`.
//
// Both files are unreachable from a fake-`Deps` test. `handler.ts` takes ports,
// so every behavioural test in `complete_trip_handler.test.ts` and
// `demo_pay_handler.test.ts` is blind to which table each port reads, which
// columns it writes, and whether the row count is observable at all. That
// blindness is not hypothetical: `cancel_clients_wiring.test.ts` records two
// mutations of `cancel-trip/clients.ts` that both survived the port-level suite,
// and the `demo-pay` draft's `userClient` -- a second, anon-keyed client built
// per request -- would not have been visible to a single one of them either.
//
// This is `clients_wiring.test.ts`'s mechanism, for the reason it gives: the
// obvious fix is to import supabase-js here and drive the ports with a stub
// fetch, which was rejected because it makes the Deno test job depend on a cold
// remote fetch and this tree has no lockfile. Asserting the text costs no
// network, no environment and no supabase-js. The cost is the one that file
// names: these assertions are brittle to reformatting and cannot see a semantic
// change that keeps the same tokens. They are a floor, and what they guarantee
// is that a dropped `.select()`, a dropped filter, a dropped column, a dropped
// `is_demo` and a dropped state filter cannot land silently.

const strip = (path: string) =>
  Deno.readTextFile(new URL(path, import.meta.url))
    // Comments are stripped before anything is matched. They have to be: a
    // comment that names `.select()` is a sentence about a select, not a select,
    // and an assertion that cannot tell the difference fails on a reworded
    // comment and passes on a real change.
    .then((raw) => raw.replace(/^\s*\/\/.*$/gm, ''));

const [completeSource, demoSource, completeIndex, demoIndex, rowsSource, handlerSource] =
  await Promise.all([
    strip('../complete-trip/clients.ts'),
    strip('../demo-pay/index.ts'),
    strip('../complete-trip/index.ts'),
    // Read twice on purpose: the port builder above is asserted on the client
    // construction, and the wiring on the request's own text, and the two live in
    // the same file.
    strip('../demo-pay/index.ts'),
    strip('../_shared/rows.ts'),
    strip('../complete-trip/handler.ts'),
  ]);

const has = (body: string, pattern: RegExp): boolean =>
  pattern.test(body.replace(/\s+/g, ' '));

// A quote class inlined in each pattern rather than interpolated, so a pattern
// cannot be assembled out of a half-escaped string. A `'` inside a
// double-quoted JS string is the identity case; inside a regex literal it would
// end the literal, so every pattern is a double-quoted `new RegExp` and every
// backslash in it is doubled.
const eq = (column: string, value: string) =>
  new RegExp(`\\.eq\\(\\s*['"\`]\\s*${column}\\s*['"\`]\\s*,\\s*${value}\\s*\\)`);

const from = (table: string) =>
  new RegExp(`from\\(\\s*['"\`]\\s*${table}\\s*['"\`]\\s*\\)`);

const assigns = (key: string, value: string) =>
  new RegExp(`${key}\\s*:\\s*${value}`);

/** The body of one `name: (...) => { ... }` member, brace-matched, so an
 * assertion covers the member and not the whole file. The match starts at the
 * member's own `=>` rather than at its name, because `writeLedger` destructures
 * nothing here but `ledgerRow` does, and a brace-match from a name that
 * destructures would balance against that parameter list and stop. */
const member = (source: string, name: string): string => {
  const nameAt = source.search(new RegExp(`^\\s{4}${name}:`, 'm'));
  assert(nameAt >= 0, `no member named ${name}`);
  return arrowBody(source.slice(nameAt), name);
};

/** The brace-matched body of a `const name = (...) => { ... }`, from the arrow.
 * Used for the module-level helpers the port builders delegate to. */
const arrowBody = (source: string, name: string): string => {
  const arrowAt = source.indexOf('=>');
  assert(arrowAt >= 0, `member ${name} has no arrow`);
  const open = source.indexOf('{', arrowAt);
  let depth = 0;
  for (let i = open; i < source.length; i++) {
    if (source[i] === '{') {
      depth++;
    } else if (source[i] === '}') {
      depth--;
      if (depth === 0) return source.slice(0, i + 1);
    }
  }
  throw new Error(`member ${name} is not brace-balanced`);
};

const limit1 = new RegExp('\\.limit\\(\\s*1\\s*\\)');
const newestFirst = new RegExp(
  "order\\(\\s*['\"`]\\s*created_at\\s*['\"`]\\s*,\\s*\\{\\s*ascending\\s*:\\s*false",
);
const selects = new RegExp('\\.select\\(');

// --- both builders --------------------------------------------------------

for (
  const [name, source] of [['complete-trip/clients.ts', completeSource], ['demo-pay/index.ts', demoSource]] as const
) {
  Deno.test(`${name} builds one service-role client and forwards no bearer onto it`, () => {
    // supabase-js only sets `Authorization` when the request has none
    // (`@supabase/supabase-js@2.45.4/dist/module/lib/fetch.js`), so a service
    // key paired with a forwarded bearer leaves the bearer as the effective
    // credential rather than the key. `Authorization` itself is read in both
    // files -- it is the request's own header, and the token comes off it -- so
    // what is forbidden is a *forwarded* one.
    assert(
      has(source, /createClient\(\s*supabaseUrl\s*,\s*serviceKey\s*\)/),
      `${name} must build its client from the service key it is handed`,
    );
    // One `createClient` per file. The `demo-pay` draft built a second,
    // anon-keyed client per request and called the argumentless `getUser()` on
    // it; an Edge Function has no client-carried session, so that call answered
    // `Auth session missing!` and the function 401'd on every call.
    assert(
      source.match(/createClient\(/g)?.length === 1,
      `${name} must build exactly one client`,
    );
    assert(
      !has(source, /headers\s*:\s*\{\s*Authorization/),
      `${name} must not forward a bearer onto its client: that is the Task 6 defect`,
    );
    assert(
      !has(source, /global\s*:\s*\{\s*headers/),
      `${name} must not pass a global header block for the same reason`,
    );
    // The `demo-pay` draft read the anon key off the environment to build that
    // second client.
    assert(
      !has(source, /SUPABASE_ANON_KEY/),
      `${name} must not read the anon key: the identity comes from the stripped token`,
    );
    assert(
      has(source, /getUser\(\s*token\s*\)/),
      `${name} must call getUser(token)`,
    );
    assert(
      !has(source, /getUser\(\s*\)/),
      `${name} must not call the argumentless getUser()`,
    );
  });

  Deno.test(`${name} reads a trip with limit(1) and never with single()`, () => {
    const body = member(source, 'findTrip');
    assert(has(body, from('trips')), 'findTrip must read the trips table');
    assert(limit1.test(body.replace(/\s+/g, ' ')), 'findTrip must use limit(1)');
    // A missing row makes PostgREST answer 406, which supabase-js throws, so the
    // 404 underneath it was unreachable and a missing trip became a bare 500.
    assert(
      !has(body, /\.single\(\)/),
      'findTrip must not use single(); a zero-row read is a 200 with []',
    );
    assert(has(body, eq('id', 'tripId')), "findTrip must filter on the trip's id");
  });
}

// --- complete-trip --------------------------------------------------------

Deno.test('the payment read is the newest row with no state filter on it', () => {
  const body = member(completeSource, 'findOpenPayment');
  assert(has(body, from('payments')), 'findOpenPayment must read payments');
  assert(has(body, eq('trip_id', 'tripId')), "it must filter on the trip's id");
  assert(has(body, newestFirst), 'it must take the newest row, or "newest" is whatever comes back');
  assert(has(body, limit1), 'it must use limit(1)');
  // The load-bearing one. `complete-trip` marks the payment `succeeded` before
  // it writes the ledger, so a retry after a failed ledger write finds a
  // succeeded row. Filtering on `state = 'pending'` would find nothing, the
  // handler would read the absent payment as pending, and the fare and the
  // payout would be written a second time.
  assert(
    !has(body, /['"`]\s*state\s*['"`]/),
    'findOpenPayment must not filter on state; the name says open, the port is the newest row',
  );
});

Deno.test('both payment writes are readable, or a lost race is a 200', () => {
  for (const [name, target] of [['markPaymentSucceeded', 'succeeded'], ['markPaymentVoided', 'voided']]) {
    const body = member(completeSource, name);
    assert(has(body, from('payments')), `${name} must write payments`);
    assert(has(body, eq('id', 'paymentId')), `${name} must filter on the payment's id`);
    assert(
      has(body, assigns('state', `['"\`]\\s*${target}\\s*['"\`]`)),
      `${name} must set state to '${target}', which payment_state carries (init.sql:8)`,
    );
    // Measured: an update with no `select` answers `data = null` and
    // `error = null` whether it wrote a row or matched none, so the row-count
    // refusal the handler makes would never fire.
    assert(selects.test(body.replace(/\s+/g, ' ')), `${name} must carry a .select()`);
  }
});

Deno.test('the ledger insert writes both entries, signed, as demo money', () => {
  const body = member(completeSource, 'writeLedger');
  assert(has(body, from('ledger_entries')), 'writeLedger must insert into ledger_entries');
  assert(has(body, /\.insert\(/), 'writeLedger must be an insert');
  // Both entries in one statement: two inserts would let the fare land without
  // the commission, which is the half-written ledger the identity prevents.
  assert(
    has(body, /entries\s*\.\s*map\(/),
    'writeLedger must map over every entry the handler passed, not write one of them',
  );

  // The columns are in the row builder the port delegates to, which is why this
  // is asserted separately rather than skipped: a port-level test cannot see
  // either one.
  const row = arrowBody(
    completeSource.slice(completeSource.search('const ledgerRow')),
    'ledgerRow',
  );
  assert(
    has(row, assigns('driver_id', 'driverId')),
    'ledger_entries.driver_id is not null (init.sql:123)',
  );
  assert(has(row, assigns('trip_id', 'tripId')), 'the money must be attributed to the trip');
  assert(
    has(row, assigns('kind', 'entry\\.kind')),
    'the handler chooses the kind, and the CHECK allows only five of them (init.sql:126)',
  );
  assert(
    has(row, assigns('amount_ghs', 'entry\\.amountGhs')),
    'the sign and the amount come from the handler, which is where the identity lives',
  );
  assert(has(row, assigns('note', 'entry\\.note')));
  // `alter table ledger_entries add constraint ledger_demo_only check (is_demo)`
  // (init.sql:178) refuses the row outright, so this is not a convention.
  assert(
    has(row, assigns('is_demo', 'true')),
    'the ledger row must set is_demo or the CHECK constraint refuses it',
  );
});

Deno.test('the payout insert is the settled payout, as demo money', () => {
  const body = member(completeSource, 'writePayout');
  assert(has(body, from('payouts')), 'writePayout must insert into payouts');
  assert(has(body, assigns('driver_id', 'driverId')), 'payouts.driver_id is not null (init.sql:114)');
  assert(has(body, assigns('trip_id', 'tripId')), 'the payout must name its trip');
  assert(
    has(body, assigns('amount_ghs', 'amountGhs')),
    'writePayout must write the amount it was handed, not a literal',
  );
  // `alter table payouts add constraint payouts_demo_only check (is_demo)`
  // (init.sql:177) refuses the row without it.
  assert(has(body, assigns('is_demo', 'true')), 'the payout must set is_demo');
});

Deno.test('the rating insert is a service-role insert that names the duplicate', () => {
  const body = member(completeSource, 'writeRating');
  assert(has(body, from('ratings')), 'writeRating must insert into ratings');
  assert(has(body, assigns('trip_id', 'input\\.tripId')));
  assert(has(body, assigns('rater_id', 'input\\.raterId')));
  assert(has(body, assigns('ratee_id', 'input\\.rateeId')));
  // `from_role` is what `unique (trip_id, from_role)` keys on
  // (init.sql:141), and the driver half of the two-way rating is Task 14's, so
  // the value is the handler's, never a field of the request body.
  assert(
    has(body, assigns('from_role', 'input\\.fromRole')),
    'from_role must come from the port, not from the body',
  );
  assert(has(body, assigns('stars', 'input\\.stars')));
  assert(has(body, assigns('comment', 'input\\.comment')));
  // Matched on PostgREST's `code` and not on the message text, which carries a
  // generated constraint name. Without it every duplicate is a plain failure and
  // a re-rating reads as a fault.
  assert(
    has(body, /duplicate\s*:\s*error\s*\?\s*\.code\s*===\s*UNIQUE_VIOLATION/),
    'the duplicate must be read off the error code, which is what makes it a 409 rather than a 500',
  );
  assert(
    has(completeSource, /UNIQUE_VIOLATION\s*=\s*'23505'/),
    "23505 is PostgreSQL's unique_violation, which is what init.sql:141 raises",
  );
});

// --- demo-pay -------------------------------------------------------------

Deno.test("demo-pay's open-payment read is scoped to this trip, this payer and pending", () => {
  const body = member(demoSource, 'findOpenPayment');
  assert(has(body, from('payments')));
  assert(has(body, eq('trip_id', 'tripId')));
  // A driver's own charge and a rider's live in the same table, and this
  // function may only ever see the rider's.
  assert(has(body, eq('payer_id', 'payerId')));
  assert(
    has(body, eq('state', "['\"`]\\s*pending\\s*['\"`]")),
    'the reuse only finds an open charge if the row is pending',
  );
  assert(has(body, newestFirst));
  assert(has(body, limit1));
});

Deno.test('the demo charge is a pending, is_demo row that is read back', () => {
  const body = member(demoSource, 'createPayment');
  assert(has(body, from('payments')));
  assert(has(body, /\.insert\(/));
  assert(has(body, assigns('trip_id', 'input\\.tripId')));
  assert(has(body, assigns('payer_id', 'input\\.payerId')));
  assert(has(body, assigns('amount_ghs', 'input\\.amountGhs')));
  assert(has(body, assigns('method', 'input\\.method')));
  assert(
    has(body, assigns('state', "['\"`]\\s*pending\\s*['\"`]")),
    "a demo charge starts pending; complete-trip is what moves it to 'succeeded'",
  );
  // `alter table payments add constraint payments_demo_only check (is_demo)`
  // (init.sql:176) refuses the row without it.
  assert(
    has(body, assigns('is_demo', 'true')),
    'every charge this build makes is demo money, and the CHECK refuses the row without it',
  );
  // The 200 body echoes the written row.
  assert(selects.test(body.replace(/\s+/g, ' ')), 'createPayment must carry a .select()');
  assert(
    !has(body, /\.single\(\)/),
    'createPayment must not use single(); a zero-row answer is the 500 the handler returns',
  );
});

Deno.test('the index files authenticate through the port and refuse a bare token', () => {
  for (const [name, source] of [['complete-trip/index.ts', completeIndex], ['demo-pay/index.ts', demoIndex]] as const) {
    // PostgREST resolves the role from the scheme word, so a bare token
    // authenticates nowhere and the lenient `replace(/^Bearer\\s+/i, '')` that
    // `cancel-trip` and `request-ride` use would pass a request that fails later
    // at a PostgREST port.
    assert(
      has(source, /\^Bearer\\s\+\(\\S\+\)\\s\*\$\/i/),
      `${name} must require the Bearer scheme rather than stripping it leniently`,
    );
    assert(
      has(source, /deps\.authenticate\(/),
      `${name} must authenticate through the port, not a client of its own`,
    );
  }
});

// --- the two shared response rules ---------------------------------------

Deno.test('both builders import the shared rules and re-declare neither of them', () => {
  // `ok()` is the only place a PostgREST error becomes a string, and a builder
  // that re-inlined a copy of it would be invisible to `_tests/rows.test.ts`,
  // which pins the shared one. These two assertions are what make the pin in that
  // file a statement about the builders and not only about a module nothing uses.
  for (const [name, source] of [
    ['complete-trip/clients.ts', completeSource],
    ['demo-pay/index.ts', demoSource],
  ] as const) {
    assert(
      has(source, /import\s*\{\s*first\s*,\s*ok\s*\}\s*from\s*'\.\.\/_shared\/rows\.ts'/),
      `${name} must import first and ok from _shared/rows.ts`,
    );
    assert(
      !has(source, /const\s+ok\s*=/),
      `${name} must not declare its own ok(); a second copy is the defect this move removed`,
    );
    assert(
      !has(source, /const\s+first\s*=/),
      `${name} must not declare its own first()`,
    );
  }
  // And the shared module is the two rules and nothing else, so a third thing
  // cannot quietly arrive in it with an import of its own that nothing pins.
  assert(
    has(rowsSource, /export const ok = \(error: \{ message: string \} \| null\): string \| null =>/),
    '_shared/rows.ts must declare ok() with the error-or-null signature the ports use',
  );
  assert(
    has(rowsSource, /error\?\.message \?\? null/),
    '_shared/rows.ts must read the message off the error, and answer null when there is none',
  );
});

// --- the decision decides the kinds --------------------------------------

Deno.test('both ledger writes take their kinds from the decision, not a literal', () => {
  // A mutation here survives every behavioural test in this task, and the reason
  // is worth writing down rather than discovering again: `handleComplete` calls
  // `settleAgainstTripState` itself, so a fake `Deps` cannot change the decision,
  // and for every *reachable* decision the charge path's kinds are exactly
  // `['fare', 'commission']`. Making the handler write that pair by hand instead
  // of reading `decision.ledgerKinds` therefore changes nothing observable today.
  // Measured: that mutation passes all 36 handler tests and all 220 in the suite.
  //
  // So it is pinned structurally, the same way the reused row's `state` is: by
  // asserting the coupling rather than hoping a reachable state diverges. The
  // mutation that *is* behavioural -- `ledgerKinds: ['fare']` on a completed trip
  // -- is pinned by the money identity in `complete_trip_handler.test.ts`, and it
  // dies there because the entries are counted.
  const calls = handlerSource.match(/ledgerEntriesFor\(\s*decision\.ledgerKinds\s*,\s*settlement\s*\)/g) ?? [];
  assertEquals(
    calls.length,
    2,
    'both the void path and the charge path must take their kinds from decision.ledgerKinds',
  );
  assert(
    !/ledgerEntriesFor\(\s*\[/.test(handlerSource),
    'no call may pass a literal kind list; the decision decides what is written',
  );
});
