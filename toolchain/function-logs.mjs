// The boot error for a function that deployed but will not start.
//
//   node toolchain/function-logs.mjs leave-trip
//
// A function that deploys and then answers `503 BOOT_ERROR` is the worst outcome
// of the two, because the deploy call succeeded and reported a version number.
// The reason is in the function logs and nowhere else, and there is no CLI on this
// machine to read them with.

import { readEnvOrFail } from './read-env.mjs';

const env = readEnvOrFail('toolchain/supabase-admin.env', [
  'SUPABASE_PROJECT_REF',
  'SUPABASE_ADMIN_TOKEN',
]);
const ref = env.SUPABASE_PROJECT_REF;
const slug = process.argv[2];
if (!slug) {
  console.error('  usage: node toolchain/function-logs.mjs <function-slug>');
  process.exit(1);
}
const headers = { Authorization: 'Bearer ' + env.SUPABASE_ADMIN_TOKEN };

// The SQL-shaped endpoint is gone. `logs.all` answers 410 with
// `{"message":"The logs.all endpoint has been removed. Use GET
// /v1/projects/{ref}/analytics/endpoints/logs instead."}` and names its own
// replacement, which takes a `sql` parameter over the `edge_logs` table -- the
// example in the OpenAPI schema is `select event_message from edge_logs`, and
// querying a `function_logs` table answers zero rows rather than an error, which
// reads as "nothing is wrong" on the day the function is failing on every call.
const params = new URLSearchParams({
  sql:
    `select timestamp, event_message, level, metadata from edge_logs ` +
    `where metadata->>'function_slug' = '${slug}' order by timestamp desc limit 12`,
});
const url = 'https://api.supabase.com/v1/projects/' + ref + '/analytics/endpoints/logs?' + params.toString();
const res = await fetch(url, { headers });
const text = await res.text();
if (!res.ok) {
  console.log(`\n  HTTP ${res.status}  ${text.slice(0, 400)}\n`);
  process.exit(1);
}
let rows = null;
try {
  const parsed = JSON.parse(text);
  rows = Array.isArray(parsed) ? parsed : (parsed.result ?? parsed.value ?? parsed.logs ?? null);
} catch {
  console.log(`\n  not json: ${text.slice(0, 400)}`);
  process.exit(1);
}
if (!Array.isArray(rows) || rows.length === 0) {
  console.log(`\n  no rows for ${slug}. (Response: ${JSON.stringify(rows).slice(0, 200)})\n`);
  process.exit(1);
}
console.log(`\n=== ${slug}: ${rows.length} log row(s) ===\n`);
for (const r of rows) {
  const when = String(r.timestamp ?? r.created_at ?? '').slice(0, 19);
  const msg = String(r.event_message ?? r.message ?? JSON.stringify(r)).slice(0, 600);
  console.log(`  ${when}  ${msg}`);
}
console.log('');

