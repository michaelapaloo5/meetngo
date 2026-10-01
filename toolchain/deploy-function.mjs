// Deploy an Edge Function: create the shell, then upload the bundle.
//
//   node toolchain/deploy-function.mjs leave-trip
//   node toolchain/deploy-function.mjs --list
//
// ## Why this is two calls and not one
//
// The Management API has two routes and neither does what its name suggests:
//
//   POST /v1/projects/{ref}/functions         V1CreateFunctionBody
//                                            { slug, name, body }   <- body is an
//                                            ESZIP *string*
//   POST /v1/projects/{ref}/functions/deploy  FunctionDeployBody
//                                            { file[], metadata }  <- multipart, and
//                                            metadata has `name` but no `slug`
//
// So the multipart route cannot name a function. Pointed at a slug that does not
// exist it creates one named after its own UUID -- which is what happened first
// time round, leaving a function called
// `6357e501-8013-4458-9579-9f592410ca3b` whose display name was `leave-trip`.
//
// Hence: create with an explicit `slug` first, then upload the real bundle.
//
// ## Why the part names keep the repository path
//
// A deployed function's `entrypoint_path` reads
// `file:///tmp/.../source/supabase/functions/route/index.ts` -- the platform puts
// each part at `source/<the part's filename>` and the filename it was given. So
// the parts have to be named `supabase/functions/<slug>/index.ts` and
// `entrypoint_path` has to be that same string. Naming the parts `index.ts` gives
// `Entrypoint path does not exist - .../source/index.ts`, because `index.ts` lands
// at `source/index.ts` and the lookup wants `source/supabase/functions/...`.
//
// ## Why it type-checks first
//
// Deno type-checks on deploy, so a function with a type error deploys cleanly and
// then answers 500 on every request -- which looks like a network fault and not like
// a build error. `deno check` moves the failure to before the deploy.

import { readFileSync, readdirSync, statSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, relative } from 'node:path';
import { readEnvOrFail } from './read-env.mjs';

const env = readEnvOrFail('toolchain/supabase-admin.env', [
  'SUPABASE_PROJECT_REF',
  'SUPABASE_ADMIN_TOKEN',
]);
const ref = env.SUPABASE_PROJECT_REF;
const base = 'https://api.supabase.com/v1/projects/' + ref + '/functions';
const headers = { Authorization: 'Bearer ' + env.SUPABASE_ADMIN_TOKEN };
const functionsDir = 'supabase/functions';

const listFunctions = async () => {
  const res = await fetch(base, { headers });
  const body = await res.json();
  return Array.isArray(body) ? body : (body.value ?? []);
};

// --------------------------------------------------------------------- --list
if (process.argv[2] === '--list') {
  const rows = await listFunctions();
  console.log(`\n  ${rows.length} function(s) on ${ref}:\n`);
  for (const f of rows.sort((a, b) => a.slug.localeCompare(b.slug))) {
    const odd = /^[A-Za-z][A-Za-z0-9_-]*$/.test(f.slug ?? '') ? '' : '   <- not a slug';
    console.log(
      `  ${f.slug.padEnd(38)} ${String(f.status ?? '?').padEnd(9)} v${f.version ?? '?'}` +
        `  jwt=${f.verify_jwt}${odd}`,
    );
  }
  console.log('');
  process.exit(0);
}

const slug = process.argv[2];
if (!slug) {
  console.error('  usage: node toolchain/deploy-function.mjs <function-slug> | --list');
  process.exit(1);
}
if (!/^[A-Za-z][A-Za-z0-9_-]*$/.test(slug)) {
  console.error(`  ${slug} is not a valid function slug.`);
  process.exit(1);
}

const dir = join(functionsDir, slug);
try {
  if (!statSync(dir).isDirectory()) throw new Error('not a directory');
} catch {
  console.error(`  ${functionsDir}/${slug} does not exist.`);
  process.exit(1);
}

const files = [];
const walk = (path) => {
  for (const entry of readdirSync(path, { withFileTypes: true })) {
    const full = join(path, entry.name);
    if (entry.isDirectory()) {
      walk(full);
    } else if (entry.name.endsWith('.ts')) {
      files.push(full);
    }
  }
};
walk(dir);
if (files.length === 0) {
  console.error(`  no .ts files under ${functionsDir}/${slug}.`);
  process.exit(1);
}

// ------------------------------------------------------- check before shipping
console.log(`\n  type-checking ${files.length} file(s)...`);
try {
  execFileSync('deno', ['check', ...files], { stdio: 'pipe' });
  console.log('  ok');
} catch (e) {
  console.error('\n  deno check failed; not deploying.\n');
  console.error(
    `${e.stdout ?? ''}${e.stderr ?? ''}`
      .split('\n')
      .slice(0, 30)
      .map((l) => '  ' + l)
      .join('\n'),
  );
  process.exit(1);
}

// ---------------------------------------------------------------- 2. bundle
//
// ## This step does not work through the Management API, and that is the finding
//
// `POST /functions/deploy` takes `{ file[], metadata }` and **has no way to name
// the function**. Pointed at a slug that does not exist it creates a *new* function
// named after its own UUID:
//
//   create leave-trip   -> id 3e4e0c5e-...   (holding the placeholder bundle)
//   POST /deploy        -> id d02007de-...   (a second function, UUID-named)
//
// Two functions where there should be one, and the one actually serving
// `/functions/v1/leave-trip` is the placeholder, which answers
// `503 BOOT_ERROR` on every call.
//
// `POST /functions` does accept a slug, but its `body` is an ESZIP *binary
// bundle* (`GET /functions/route/body` returns one beginning `ESZIP2.3`), and
// building a valid ESZIP here is a project in itself.
//
// So this script stops rather than leaving a half-deployed function behind. The
// function's code, its 21 unit tests, its migration and its live database rules
// are all in the repository and ready; deploying it needs the Supabase CLI:
//
//   npm i -g supabase
//   supabase link --project-ref <ref>
//   supabase functions deploy leave-trip
//
// which is also what `toolchain/function-logs.mjs` would need, since this project
// reports `Table "edge_logs" does not exist` and has no readable logs endpoint.
console.log('\n  cannot upload a bundle through the Management API; see the comment.');
console.log('  Nothing was deployed. To deploy: supabase functions deploy ' + slug);
process.exit(1);