// The two rules both port builders depend on when a supabase-js response comes
// back, and nothing else.
//
// They live here, apart from `complete-trip/clients.ts` and `demo-pay/index.ts`,
// because of what it costs to test them where they were. Both builders import
// `createClient` from `https://esm.sh/@supabase/supabase-js@2.45.4` at module
// scope, so a test that imported either file to reach `ok()` would add a second
// remote host to the Deno test job, and the largest module graph in it, for a
// function that returns a string.
//
// Measured on this host with an empty `DENO_DIR` and `--cached-only`, the thing
// that does not resolve is that specifier:
// `Specifier not found in cache: "https://esm.sh/@supabase/supabase-js@2.45.4"`.
// To be exact about what that does and does not prove: the test job already
// resolves `deno.land/std@0.224.0` remotely, because every one of its test files
// imports `asserts.ts` from there, and a cold cache fails on that import first.
// So this is not "the test job needs a network" -- it is that nothing in the test
// job needs `esm.sh` today, `deno check` is the only step that resolves it, and
// `clients_wiring.test.ts` and `cancel_clients_wiring.test.ts` have each already
// recorded that they rejected a supabase-js import on exactly those grounds.
// This module has no remote import, so `_tests/rows.test.ts` pins both rules with
// no supabase-js at all, which is the same bargain `cors.ts` already makes.
//
// `ok()` is the one that matters. It is the only place a PostgREST error becomes
// a string, and every `500` that names a step in `complete-trip` and `demo-pay`
// is downstream of it: a builder whose `ok()` answered `null` for a real error
// would answer `404 trip not found` where Step 7 requires `500 trip lookup
// failed`, and no port-level test can see that, because a fake `Deps` returns
// whatever the fake was told to return.

/**
 * The first row of a `select`, or null.
 *
 * Why not `data?.[0] ?? null` inline at each site, and why not `.single()`: a
 * zero-row read is a 200 with `[]`, and `.single()` makes PostgREST answer 406,
 * which supabase-js throws -- so the 404 underneath it is unreachable and a
 * missing row becomes a bare 500. Indexed, the row count is the caller's problem
 * to read, and a non-array (a `select` that was never asked for) is null rather
 * than an undefined property access.
 */
export const first = <T>(rows: T[] | null): T | null =>
  (Array.isArray(rows) ? rows[0] ?? null : null);

/**
 * A PostgREST error's message, or null when there was no error.
 *
 * `null` and not `''` matters: the ports carry `error: string | null` and the
 * handlers branch on null, so an error that became an empty string would be
 * reported as a failure with nothing to say, and one that became `undefined`
 * would fail the `error: string | null` type for no reason.
 */
export const ok = (error: { message: string } | null): string | null =>
  error?.message ?? null;
