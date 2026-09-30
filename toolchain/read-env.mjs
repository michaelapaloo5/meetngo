// Reads a `KEY=value` env file. One implementation, because there were nine.
//
//   import { readEnv } from './read-env.mjs';
//   const env = readEnv('toolchain/supabase-admin.env');
//
// Every one of those nine scripts had this line:
//
//   for (const line of readFileSync(p, 'utf8').split('\n')) {
//     const m = /^\s*([A-Z_0-9]+)=(.*)$/.exec(line);
//     if (m) env[m[1]] = m[2];
//   }
//
// and every one of them was wrong in the same silent way, on a file with
// Windows line endings.
//
// Why the regex fails on a CRLF line:
//
//   "SB_URL=https://...supabase.co\r"
//
// `.` in JavaScript does not match `\r`, and `$` without the `m` flag does not
// match before a `\r` either. So `(.*)$` cannot consume the carriage return and
// cannot stop in front of it, the whole match fails, and the key is dropped
// **without a warning**. The script then reports on whatever keys it did manage
// to read, which is how `SB_URL` went missing while `SB_ANON_KEY` -- the last
// line of the file, and the only one with a bare LF -- parsed perfectly. The
// output looked plausible and was wrong.
//
// Splitting on `/\r?\n/` fixes it, and the explicit "did this file have CRLF"
// return value fixes the other half: a silently-mangled value is worse than no
// value, so callers can assert on it.

import { readFileSync } from 'node:fs';

/**
 * Parse a `KEY=value` file into an object.
 *
 * Later keys win, which is what a shell `source` does and what a person
 * appending an override expects.
 *
 * Values keep their quotes stripped only when the whole value is quoted, which
 * is what lets a token with `=` or a space in it survive. A `#` inside a value
 * is kept; a `#` starting a line, or following whitespace before the `=`, is a
 * comment. That is `shell(1)`'s rule rather than an invented one.
 *
 * @param {string} path   file to read, relative to the repository root
 * @returns {Record<string,string> & {__crlf?: boolean}} the keys, plus
 *   `__crlf: true` if the file used Windows line endings
 */
export function readEnv(path) {
  const raw = readFileSync(path, 'utf8');
  const out = {};
  if (raw.includes('\r\n')) out.__crlf = true;

  for (const line of raw.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (trimmed === '' || trimmed.startsWith('#')) continue;

    const eq = line.indexOf('=');
    if (eq <= 0) continue;

    const key = line.slice(0, eq).trim();
    // A key that is not a shell identifier cannot be read back as one, so
    // silently accepting `SB URL=...` would produce a key nobody can reference.
    if (!/^[A-Za-z_][A-Za-z_0-9]*$/.test(key)) continue;

    let value = line.slice(eq + 1).trim();
    // Only strip a matching pair of surrounding quotes, so a value that merely
    // contains a quote at one end is left alone.
    if (value.length >= 2) {
      const first = value[0];
      const last = value[value.length - 1];
      if ((first === '"' && last === '"') || (first === "'" && last === "'")) {
        value = value.slice(1, -1);
      }
    }
    out[key] = value;
  }
  return out;
}

/**
 * [readEnv] plus a loud failure when a required key is absent.
 *
 * Every script that talks to Supabase needs the project ref and a token. The
 * failure mode without this is a fetch to `undefined`, which surfaces as a DNS
 * error about a hostname nobody recognises -- a long way from the real cause.
 *
 * @param {string} path
 * @param {string[]} required
 */
export function readEnvOrFail(path, required) {
  const env = readEnv(path);
  const missing = required.filter((k) => !env[k]);
  if (missing.length > 0) {
    throw new Error(
      `${path} is missing ${missing.join(', ')}.\n` +
        `  keys it does have: ${Object.keys(env).filter((k) => k !== '__crlf').join(', ') || '(none)'}\n` +
        (env.__crlf
          ? '  note: this file has Windows line endings. readEnv handles them, but if you\n' +
            '  edit it by hand, keep it consistent with the other toolchain env files.'
          : ''),
    );
  }
  return env;
}