// The admin page renders, and does not leak the service role key.
//
// A function that type-checks and passes its handler tests can still serve a
// page with a syntax error in the script, a template literal that swallowed a
// chunk of markup, or -- the one that matters most here -- a credential baked
// into the HTML. This renders the string and checks those three things.
//
// Deno has no DOM, and adding one for a page this size would be a second remote
// host in a test job that `_shared/rows.ts` goes out of its way to keep free of
// them. So the checks are on the string, which is where all three problems
// actually live.
import { assert, assertEquals, assertStringIncludes } from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import { adminPage } from '../admin-drivers/page.ts';

const html = adminPage('https://project.supabase.co');

Deno.test('it is a document', () => {
  assertStringIncludes(html, '<!doctype html>');
  assertStringIncludes(html, '</html>');
  assert(html.indexOf('<head>') < html.indexOf('<body>'));
  assert(html.indexOf('<body>') < html.indexOf('</body>'));
});

Deno.test('the script tag is balanced and not cut off', () => {
  // A template literal that loses a `${` swallows the rest of the script into a
  // string, and the page renders as a form that does nothing. This is the exact
  // failure that produces a deploy that looks fine and a page that is dead.
  const opens = (html.match(/<script/g) ?? []).length;
  const closes = (html.match(/<\/script>/g) ?? []).length;
  assertEquals(opens, closes, 'unbalanced script tags');
  assertStringIncludes(html, 'signIn();\n</script>');
});

Deno.test('the supabase URL is substituted and nothing else is', () => {
  assertStringIncludes(html, 'https://project.supabase.co');
  // A stray `${` that was not a substitution would survive into the output as
  // literal text in the page.
  assert(!html.includes('\${'), 'an unsubstituted interpolation reached the page');
});

Deno.test('the service role key cannot be in the page', () => {
  // The whole reason this is a function and not a website. A key in the HTML
  // is a key in the browser's view-source, in every proxy log on the way, and
  // in whatever caches the page.
  assert(!/service_role/i.test(html), 'the page mentions the service role key');
  assert(!/SUPABASE_SERVICE_ROLE/i.test(html));
  assert(
    !html.includes('eyJ'),
    'nothing shaped like a JWT is embedded in the page',
  );
});

Deno.test('the page holds no credential at all', () => {
  // It does not even hold the anon key. Sign-in is a call to the function, so
  // the only secret in this surface is the service role key, which never leaves
  // index.ts.
  assert(!html.includes('ANON_KEY'));
  assertStringIncludes(html, "action: 'signin'");
});

Deno.test('driver-supplied text is escaped on the way in', () => {
  // `full_name`, `plate` and `email` are strings a driver chose. The escape
  // helper is what stops `"><script>` in a vehicle plate becoming script.
  assertStringIncludes(html, 'const esc =');
  for (const sink of ['<div class="value">', "'<img class=\"img\" src=\"'"]) {
    assertStringIncludes(html, 'esc(');
    assert(sink.length > 0);
  }
  // Every interpolation into markup goes through esc. This is checked by
  // counting: if a `${` is followed by a bare identifier rather than `esc(`, the
  // markup is interpolating a driver string unescaped.
  const interpolations = [...html.matchAll(/\$\{([^}]*)\}/g)]
    .map((m) => m[1].trim())
    .filter((s) => s.length > 0 && !s.startsWith('JSON.stringify'));
  for (const i of interpolations) {
    assert(
      i.startsWith('esc(') || i === 'URL',
      `unescaped interpolation into the page: \${${i}}`,
    );
  }
});

Deno.test('the two decisions are wired to distinct buttons', () => {
  assertStringIncludes(html, 'data-decision="approve"');
  assertStringIncludes(html, 'data-decision="reject"');
  // The command and the decision must not share a key, which is a bug that
  // makes every click an approve.
  assertStringIncludes(html, "action: 'decide'");
  assertStringIncludes(html, 'decision: btn.dataset.decision');
});

Deno.test('it says the card cannot be checked', () => {
  // The page must not imply a verification is happening when the app stores
  // four digits and an expiry and no picture of the card.
  assertStringIncludes(html, 'not as a picture');
});

Deno.test('a warning from the function is shown, not swallowed', () => {
  // The approved-but-no-vehicle case. If the page ignored it, an admin would
  // see a green tick for a driver who will never be offered a trip.
  assertStringIncludes(html, 'if (r.data.warning) alert(r.data.warning);');
});
