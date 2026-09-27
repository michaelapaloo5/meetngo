import { assertEquals } from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import { first, ok } from '../_shared/rows.ts';

// The two rules both port builders turn a supabase-js response with, pinned
// behaviourally rather than as text.
//
// This file is the answer to a review finding that `complete-trip/clients.ts`'s
// `ok()` -- `const ok = (_e) => null` -- survived the whole 35-test handler suite
// *and* the 12-test static suite, and that with it a failed `trips` read answers
// `404 trip not found` where Step 7 requires `500 trip lookup failed`. No test
// that drives fake `Deps` can see that, because a fake returns what it was told
// to return.
//
// It is a separate module from the builders for the reason `_shared/rows.ts`
// gives, and that reason is measured rather than assumed: a test importing
// `complete-trip/clients.ts` resolves
// `https://esm.sh/@supabase/supabase-js@2.45.4`, which with an empty `DENO_DIR`
// and `--cached-only` answers
// `Specifier not found in cache: "https://esm.sh/@supabase/supabase-js@2.45.4"`.
// Nothing else in the test job needs that host -- `deno check` is the only step
// that resolves it, and two existing static suites have already recorded that
// they rejected a supabase-js import on those grounds. This file resolves nothing
// but the std asserts every other test file already imports, so it runs under
// the same command CI uses.

Deno.test("ok carries a PostgREST error's message", () => {
  assertEquals(ok({ message: 'duplicate key value violates unique constraint' }),
    'duplicate key value violates unique constraint');
  // The case the 500s are made of: a column that does not exist, a locked table,
  // a dropped connection. Each of these has to arrive as a message the handler
  // can put in a body, or the handler answers a 500 that says nothing.
  assertEquals(ok({ message: 'permission denied for table trips' }), 'permission denied for table trips');
  assertEquals(ok({ message: '' }), '');
});

Deno.test('ok answers null when there was no error, and not undefined', () => {
  assertEquals(ok(null), null);
  // Not `''` and not `undefined`: the ports declare `error: string | null` and
  // the handlers branch on null, so an error that became an empty string would
  // be reported as a failure with nothing to say.
  assertEquals(ok(null) === '', false);
  assertEquals(ok(null) === undefined, false);
});

Deno.test('ok is not a constant null, which is the mutation this file exists for', () => {
  // Stated as a property rather than as a restatement of the test above, so the
  // intent survives a rewrite of either test: the only way to make a builder
  // answer `404 trip not found` for a failed read is for this to stop reading
  // the error.
  assertEquals(typeof ok, 'function');
  assertEquals(ok({ message: 'boom' }) !== null, true);
  assertEquals(ok({ message: 'boom' }) !== 'boom', false);
});

Deno.test('first reads the first row and nothing else', () => {
  const row = { id: 'trip-1' };
  assertEquals(first([row]), row);
  assertEquals(first([row, { id: 'trip-2' }]), row);
});

Deno.test('first answers null for a zero-row read and for no rows at all', () => {
  // A zero-row `select` is a 200 with `[]`; the handlers turn that into the 404
  // and the 409 they are supposed to answer, and `undefined` would not.
  assertEquals(first([]), null);
  assertEquals(first(null), null);
  assertEquals(first([]) === undefined, false);
});

Deno.test('first refuses a response that is not a row list', () => {
  // A `select` that was never asked for yields `null`, and a `count` request
  // yields an object. Neither is a row list and neither may be indexed.
  assertEquals(first({ length: 1 } as unknown as unknown[]), null);
  assertEquals(first('trip-1' as unknown as unknown[]), null);
});
