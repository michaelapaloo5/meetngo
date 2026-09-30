// Print the real columns of a table.
//
//   node toolchain/print-columns.mjs driver_locations vehicles profiles
//
// Every other script in this directory invents a column and discovers it is
// wrong at run time, which costs a round trip and a re-read of the error. The
// schema is the one thing that cannot be guessed at, so this prints it.
//
//   node toolchain/print-columns.mjs trips

import { readEnv } from './read-env.mjs';

const env = readEnv('toolchain/supabase-admin.env');

const tables = process.argv.slice(2);
if (tables.length === 0) {
  console.log('usage: node toolchain/print-columns.mjs <table> [table...]');
  process.exit(1);
}

const q = async (sql) => {
  const res = await fetch('https://api.supabase.com/v1/projects/' + env.SUPABASE_PROJECT_REF + '/database/query', {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + env.SUPABASE_ADMIN_TOKEN, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(body.message ?? JSON.stringify(body));
  return Array.isArray(body) ? body : (body.value ?? body);
};

for (const table of tables) {
  console.log('\n=== ' + table + ' ===');
  const cols = await q(
    `select column_name, data_type, is_nullable, column_default
     from information_schema.columns
     where table_name = '${table}'
     order by ordinal_position`);
  if (cols.length === 0) {
    console.log('  (no such table)');
    continue;
  }
  for (const c of cols) {
    console.log('  ' + String(c.column_name).padEnd(24)
      + String(c.data_type).padEnd(28)
      + 'null=' + String(c.is_nullable).padEnd(5)
      + (c.column_default ?? ''));
  }
  const checks = await q(
    `select conname, pg_get_constraintdef(oid) as def from pg_constraint
     where conrelid = '${table}'::regclass and contype = 'c'`);
  if (checks.length) {
    console.log('  -- checks --');
    for (const c of checks) console.log('  ' + c.conname + ': ' + c.def);
  }
}
