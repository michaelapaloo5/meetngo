// What does the Management API expect for a function body, and clean up after a
// deploy that got the slug wrong.
//
//   node toolchain/probe-function-body.mjs
//
// The first deploy attempt sent the slug in `metadata.name`, and the platform
// named the function after its own UUID: it exists as
// `6357e501-8013-4458-9579-9f592410ca3b` rather than as `leave-trip`. The
// OpenAPI schema is the reason and it is not obvious:
//
//   POST /functions         -> V1CreateFunctionBody: { slug, name, body }
//   POST /functions/deploy  -> FunctionDeployBody:    { file[], metadata }
//
// So `name` is a *display* name on both routes, `slug` lives only on the create
// route, and `body` is a string rather than the multipart file list. That means a
// deploy is two calls: create the shell, then upload the bundle.
//
// This prints what an existing function's `body` actually looks like, so the
// bundle format is read off a working example rather than guessed at.

import { readEnvOrFail } from './read-env.mjs';

const env = readEnvOrFail('toolchain/supabase-admin.env', [
  'SUPABASE_PROJECT_REF',
  'SUPABASE_ADMIN_TOKEN',
]);
const base = 'https://api.supabase.com/v1/projects/' + env.SUPABASE_PROJECT_REF + '/functions';
const headers = { Authorization: 'Bearer ' + env.SUPABASE_ADMIN_TOKEN };

// ------------------------------------------------- tidy up the mis-created one
const listed = await (await fetch(base, { headers })).json();
const rows = Array.isArray(listed) ? listed : (listed.value ?? listed);
const strays = rows.filter((f) => !/^[A-Za-z][A-Za-z0-9_-]*$/.test(f.slug ?? ''));
if (strays.length > 0) {
  console.log('\n=== functions whose slug is not a slug ===\n');
  for (const f of strays) {
    const res = await fetch(`${base}/${f.slug}`, { method: 'DELETE', headers });
    console.log(`  ${f.slug}  ${f.name ?? ''}  -> deleted, HTTP ${res.status}`);
  }
} else {
  console.log('\n  every function has a real slug; nothing to clean up.');
}

// --------------------------------------------- what a body actually looks like
console.log('\n=== GET /functions/route/body ===\n');
const res = await fetch(`${base}/route/body`, { headers });
const text = await res.text();
if (!res.ok) {
  console.log(`  HTTP ${res.status}  ${text.slice(0, 300)}`);
} else {
  let parsed = null;
  try {
    parsed = JSON.parse(text);
  } catch {
    console.log('  not json; first 200 chars: ' + text.slice(0, 200));
  }
  if (parsed) {
    console.log('  json keys: ' + Object.keys(parsed).join(', '));
    for (const [key, value] of Object.entries(parsed)) {
      if (typeof value === 'string') {
        console.log(`    ${key}: ${value.length} chars, starts ${JSON.stringify(value.slice(0, 40))}`);
        // A zip starts with PK; base64 with a base64 alphabet.
        if (/^UEs/.test(value)) {
          console.log(`      ^ that is base64 of a zip (PK header)`);
        }
      } else {
        console.log(`    ${key}: ${JSON.stringify(value).slice(0, 120)}`);
      }
    }
  }
}

// And the function record itself, for the fields that matter when creating.
console.log('\n=== GET /functions/route ===\n');
const one = await (await fetch(`${base}/route`, { headers })).json();
const rec = Array.isArray(one) ? one[0] : (one.value?.[0] ?? one);
console.log(
  '  ' +
    ['slug', 'name', 'status', 'version', 'verify_jwt', 'entrypoint_path']
      .map((k) => `${k}=${JSON.stringify(rec[k])}`)
      .join('  '),
);