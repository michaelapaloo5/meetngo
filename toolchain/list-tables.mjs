// List the public tables, and the real name of the documents table.
//
//   node toolchain/list-tables.mjs
//
// `what-would-be-lost.mjs` asked for `documents` and Postgres said the relation
// does not exist. Guessing table names from the rest of the codebase is how a
// query spends a round trip finding out; this prints the real list.

import { readEnv } from './read-env.mjs';

const env = readEnv('toolchain/supabase-admin.env');
const res = await fetch('https://api.supabase.com/v1/projects/' + env.SUPABASE_PROJECT_REF + '/database/query', {
  method: 'POST',
  headers: { Authorization: 'Bearer ' + env.SUPABASE_ADMIN_TOKEN, 'Content-Type': 'application/json' },
  body: JSON.stringify({
    query: "select table_name from information_schema.tables where table_schema = 'public' order by 1",
  }),
});
const body = await res.json();
const rows = Array.isArray(body) ? body : (body.value ?? []);
console.log('  ' + rows.length + ' tables in public:');
for (const r of rows) console.log('    ' + r.table_name);
