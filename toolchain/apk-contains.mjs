// Does the built APK actually contain the code we think it does?
//
//   node toolchain/apk-contains.mjs
//
// `flutter build apk` exits 0 and prints "Built ...app-release.apk" whether or not
// the thing it built is the thing that was asked for. It has done so in this
// project: a release APK shipped with a Supabase anon key the project rejects,
// so every driver who installed it got a sign-in screen that could not work and
// no explanation. The key check that catches that lives in the build script and
// runs *before* the build; this is the check that runs *after*.
//
// A Dart AOT release build keeps its string and numeric literals in
// `lib/arm64-v8a/libapp.so`, so the shipped constants are findable in the
// binary. That makes the fares, the offer TTL and the category labels checkable
// without installing on a phone, which is the only way to know an APK is right
// before someone depends on it.
//
// It is a presence check, not a behaviour check. A rate present in the binary
// does not prove the code that uses it was reached. The suites and the live
// verifications cover that; this covers "is this the build I meant to make".

import { readFileSync, statSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

const APK = process.argv[2]
  ?? 'C:/Users/antoi/AppData/Local/Temp/opencode/apkstage/driver-app-arm64.apk';
// An APK is a zip, and this extracts one entry with .NET's own zip reader rather
// than with `jar`. The JDK's jar.exe is present and works from a shell, but
// spawning it from Node on this host fails with ENOENT, and a check that cannot
// run is a check that does not happen. PowerShell's ZipFile has no such problem
// and needs nothing installed beyond the .NET that is already running the script.
const PS = 'powershell.exe';

try {
  statSync(APK);
} catch {
  console.log('  no APK at ' + APK);
  process.exit(2);
}
console.log('=== ' + APK);
console.log('  ' + (statSync(APK).size / 1024 / 1024).toFixed(1) + ' MB\n');

// Extract into a scratch directory rather than the repository. `jar xf` writes
// relative to the CWD, and doing that in the repo leaves a `lib/` behind --
// which is also the name of the Dart package directory, so the first version of
// this script would have deleted `lib/` and taken the source with it.
const SCRATCH = 'C:/Users/antoi/AppData/Local/Temp/opencode/apkscratch';
// `rmdir` on a directory that is not there exits non-zero, and `execFileSync`
// throws on a non-zero status. The clean-up is best-effort by nature, so it is
// told to ignore the result -- otherwise the script dies on its *first* run,
// before it has done any work, with a stack trace about a missing directory.
const bestEffort = (cmd) => {
  try { execFileSync('cmd.exe', ['/c', cmd], { stdio: 'ignore' }); } catch { /* already gone */ }
};
bestEffort('rmdir /s /q ' + SCRATCH);
bestEffort('mkdir ' + SCRATCH);
// Checked, because the failure that follows is opaque: .NET reports "could not
// find a part of the path" for a missing *directory* just as it does for a
// missing file, and the error names the .so rather than the folder that is
// actually absent. The directory is created with `mkdir` because `mkdir` on an
// existing path is fine but an `if not exist` guard in a cmd one-liner is not
// worth the quoting.
try {
  statSync(SCRATCH);
} catch {
  console.log('  could not create the scratch directory ' + SCRATCH);
  process.exit(2);
}

const ENTRY = 'lib/arm64-v8a/libapp.so';
const TARGET = SCRATCH + '/libapp.so';

let binary;
try {
  // One entry out of a 158 MB archive, so this does not unpack the APK.
  const extract =
    "Add-Type -AssemblyName System.IO.Compression.FileSystem; " +
    '$z = [System.IO.Compression.ZipFile]::OpenRead(' + JSON.stringify(APK) + '); ' +
    'try { $e = $z.Entries | Where-Object { $_.FullName -eq ' + JSON.stringify(ENTRY) + ' }; ' +
    'if ($null -eq $e) { Write-Error "no entry"; exit 3 }; ' +
    '[System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, ' + JSON.stringify(TARGET) + ', $true) ' +
    '} finally { $z.Dispose() }';
  execFileSync(PS, ['-NoProfile', '-Command', extract], { stdio: 'pipe' });
  binary = readFileSync(TARGET);
} catch (e) {
  const detail = (e.stderr?.toString() ?? e.message).trim().split('\n').slice(0, 3).join(' | ');
  console.log('  could not read ' + ENTRY + ' out of the APK: ' + detail);
  process.exit(2);
} finally {
  bestEffort('rmdir /s /q ' + SCRATCH);
}
console.log('  read ' + (binary.length / 1024 / 1024).toFixed(1) + ' MB of Dart AOT data\n');

// A double as IEEE-754 little-endian, which is how a `const double` is stored.
function doubleBytes(n) {
  const b = Buffer.alloc(8);
  b.writeDoubleLE(n);
  return b;
}

const checks = [
  // [label, how to look for it]
  ['per-km rate 0.28 (lite)', binary.includes(doubleBytes(0.28))],
  ['per-km rate 0.35 (standard)', binary.includes(doubleBytes(0.35))],
  ['per-km rate 0.46 (premium)', binary.includes(doubleBytes(0.46))],
  ['the 15 cedi floor', binary.includes(doubleBytes(0.15))],
  ['the 5% commission', binary.includes(doubleBytes(0.05))],
  ['offer TTL of 300 seconds', binary.includes(Buffer.from('300s', 'utf8'))
    || binary.includes(doubleBytes(300))],
  // The category labels are Dart strings, so they are plainly findable. `Van`
  // is deliberately NOT asserted absent: `VehicleCategory.van` is a body style
  // and is supposed to still be in the binary.
  ['the label "Lite"', binary.includes(Buffer.from('Lite', 'utf8'))],
  ['the label "Standard"', binary.includes(Buffer.from('Standard', 'utf8'))],
  ['the body style "van" still present (it is a body style, not a tier)',
    binary.includes(Buffer.from('van', 'utf8'))],
];

console.log('=== the constants the build is supposed to carry ===');
let ok = true;
for (const [label, present] of checks) {
  if (!present) ok = false;
  console.log('  ' + (present ? 'ok   ' : 'MISSING ') + label);
}

console.log('\n  Note: this is a presence check on the AOT data, not a behaviour');
console.log('  check. A rate in the binary does not prove the code using it ran.');
console.log('  What it does prove is that this APK is not a stale build of an older');
console.log('  commit -- which is the failure that has actually happened here.');

console.log('\n' + (ok ? 'THE APK CARRIES THE NEW PRICING' : 'THE APK DOES NOT CARRY THE NEW PRICING'));
process.exit(ok ? 0 : 1);
