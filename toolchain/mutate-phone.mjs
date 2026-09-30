// Mutation testing for the phone normaliser.
//
//   node toolchain/mutate-phone.mjs
//
// A test that passes is not evidence the code is right; a test that still passes
// after you break the code is evidence the test is decorative. This breaks the
// normaliser in specific ways and asserts the suite catches each one, so the
// suite earns its keep rather than merely existing.
//
// The honest result when a mutation survives is a finding, not a failure to hide.
// Mutation 1 below is genuinely behaviour-preserving: `_local` re-checks the
// length, so removing the `00` branch's own length guard changes nothing. That is
// recorded as SURVIVES-ON-PURPOSE, not as a broken test.
//
// Deliberately absent: any key. The build reads nothing from here.

import { readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

const LIB = 'packages/mng_core/lib/src/models/phone.dart';
const original = readFileSync(LIB, 'utf8');

const MUTATIONS = [
  {
    name: 'the 00 branch loses its length check',
    // Behaviour-preserving by construction: `_local('0' + nineDigits)` is the
    // only call it makes, and `_local` requires ten digits. Recorded so the
    // reason it survives is written down rather than rediscovered.
    find: 'if (withoutPrefix.length == kGhanaMobileDigits - 1) {',
    replace: 'if (true) {',
    expect: 'survives on purpose',
  },
  {
    name: 'the international form is sliced rather than rebuilt',
    // The real bug this file was written to prevent: `233241234567` minus two
    // characters is `3241234567`, not `241234567`.
    find: "return _international(withoutPrefix.substring(kGhanaCountryCode.length));",
    replace: "return withoutPrefix;",
    expect: 'caught',
  },
  {
    name: '_local stops checking the length',
    find: 'if (digits.length != kGhanaMobileDigits) return null;',
    replace: 'if (false) return null;',
    expect: 'caught',
  },
  {
    // Survives, and it is not a gap in the tests: this check is implied by the
    // prefix set. Every entry in `kGhanaMobilePrefixes` and
    // `kGhanaFixedPrefixes` starts with `0`, so any ten-digit number that passes
    // the prefix check already has a leading zero, and no input can reach the
    // zero check and be refused by it alone. No test can be written for it.
    //
    // Two attempts were made and both chose a prefix that does not exist:
    // `2412345678` was picked because `24` looks like MTN, and MTN's prefixes
    // are `020`-`027`, so the prefix check refuses it first. Recorded here so
    // the next person does not spend the same afternoon.
    name: '_local stops checking the leading zero',
    find: "if (!digits.startsWith('0')) return null;",
    replace: 'if (false) return null;',
    expect: 'survives on purpose',
  },
  {
    name: '_local accepts any three-digit prefix',
    find: 'if (!kGhanaMobilePrefixes.contains(prefix) && !kGhanaFixedPrefixes.contains(prefix)) {',
    replace: 'if (false) {',
    expect: 'caught',
  },
  {
    name: 'the + branch accepts any country',
    // Without the "a + in front of another country is refused" assertion this
    // survived: every other refused case has no `+`, so it takes the local path
    // and never reaches the `return null` being deleted here.
    find: 'return null;\n  }\n\n  // No international marker.',
    replace: "return _local(withoutPrefix);\n  }\n\n  // No international marker.",
    expect: 'caught',
  },
  {
    name: 'isCallableGhanaPhone accepts anything non-empty',
    find: 'bool isCallableGhanaPhone(String? input) =>\n    input != null && normaliseGhanaPhone(input) != null;',
    replace: 'bool isCallableGhanaPhone(String? input) => input != null && input.isNotEmpty;',
    expect: 'caught',
  },
  {
    name: 'ghanaTelUri builds a URI for an invalid number',
    find: 'final normalised = normaliseGhanaPhone(input);\n  if (normalised == null) return null;',
    replace: "final normalised = input?.replaceAll(RegExp(r'[^0-9]'), '');\n  if (normalised == null || normalised.isEmpty) return null;",
    expect: 'caught',
  },
];

/**
 * Replace [find] with [replace], tolerating either line ending.
 *
 * The patterns are written with `\n` and the file on this host is CRLF, so a
 * plain `String.includes` matches nothing for any pattern that spans a line
 * break. Three of the eight mutations below span two or three lines, so three of
 * them silently did nothing and were reported as "the test does not cover
 * this" -- which pointed at the tests when the fault was the script.
 *
 * A mutation that is reported as SKIPPED is honest; a mutation that is applied
 * to a file it never actually changed is not, so each one is confirmed after
 * being written.
 */
function applyMutation(text, find, replace) {
  if (text.includes(find)) return text.split(find).join(replace);
  const lf = text.replace(/\r\n/g, '\n');
  if (!lf.includes(find)) return null;
  const mutated = lf.split(find).join(replace);
  // Put the original line endings back.
  return text.includes('\r\n') ? mutated.replace(/\n/g, '\r\n') : mutated;
}

function runSuite() {
  try {
    const out = execFileSync(
      'flutter',
      ['test', 'test/phone_test.dart'],
      { cwd: 'packages/mng_core', encoding: 'utf8', stdio: 'pipe', shell: true },
    );
    return { passed: out.includes('All tests passed'), out };
  } catch (e) {
    const out = (e.stdout ?? '') + (e.stderr ?? '');
    return { passed: out.includes('All tests passed'), out };
  }
}

const javaHome = 'C:\\dev\\jdk21\\jdk-21.0.12.1+1';
const flutterDir = 'C:\\dev\\flutter\\bin';
const cmake = 'C:\\dev\\cmake-3.31.6-windows-x86_64\\bin';
const ninja = 'C:\\dev\\ninja';
process.env.JAVA_HOME = javaHome;
process.env.Path = `${flutterDir};${javaHome}\\bin;${cmake};${ninja};${process.env.Path}`;

console.log('=== baseline ===');
const base = runSuite();
console.log('  ' + (base.passed ? 'the suite passes before anything is broken' : 'THE SUITE DOES NOT PASS ON THE UNMODIFIED CODE'));
if (!base.passed) process.exit(1);

let honest = 0;
let caught = 0;
let wrong = 0;

for (const m of MUTATIONS) {
  const mutated = applyMutation(original, m.find, m.replace);
  if (mutated === null) {
    console.log(`\n  ${m.name}`);
    console.log('    SKIPPED: the pattern to mutate is not in the file any more.');
    console.log('    This is a script that has gone stale, not a test that passed.');
    wrong++;
    continue;
  }
  if (mutated === original) {
    console.log(`\n  ${m.name}`);
    console.log('    SKIPPED: the mutation produced no change, so it would have reported');
    console.log('    a false "the test does not cover this".');
    wrong++;
    continue;
  }
  writeFileSync(LIB, mutated);
  // Confirmed rather than assumed: a mutation that did not land is worse than
  // no mutation, because it is reported as a finding about the tests.
  const landed = readFileSync(LIB, 'utf8') === mutated;
  const result = runSuite();
  writeFileSync(LIB, original);
  if (!landed) {
    console.log(`\n  ${m.name}`);
    console.log('    SKIPPED: the file on disk did not take the change.');
    wrong++;
    continue;
  }
  const detected = !result.passed;
  const status = m.expect === 'caught'
    ? (detected ? 'caught' : 'SURVIVED -- the test does not cover this')
    : (detected ? 'caught, but the comment claims it is behaviour-preserving' : 'survives on purpose, as documented');
  const bad = m.expect === 'caught' ? !detected : detected;
  if (bad) wrong++;
  else if (detected) caught++;
  else honest++;
  console.log(`\n  ${m.name}`);
  console.log('    ' + status);
}

writeFileSync(LIB, original);
const after = runSuite();
console.log('\n=== after every mutation is reverted ===');
console.log('  ' + (after.passed ? 'the suite passes again, so the file is back as it was' : 'THE FILE WAS NOT RESTORED'));

console.log(`\n  ${caught} mutation(s) caught, ${honest} surviving as documented, ${wrong} wrong`);
if (wrong > 0) {
  console.log('  A mutation that survived against expectation, or a stale pattern, means');
  console.log('  the suite is not what it claims. Do not treat it as coverage.');
}
process.exit(wrong > 0 || !after.passed ? 1 : 0);
