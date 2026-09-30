// The `van` -> `lite` ride-category rename, applied file by file.
//
//   node toolchain/rename-van-to-lite.mjs --check    (report only)
//   node toolchain/rename-van-to-lite.mjs --apply
//
// Run twice on purpose. The second run must find nothing, and that is the
// evidence the rename is complete rather than partial -- a half-done rename
// leaves an enum value that no longer parses, which is loud, but a half-done
// rename of a *string* in a test key is silent and just stops finding the
// widget.
//
// The rule this encodes: `van` is TWO different things in this codebase and only
// one of them is being renamed.
//
//   ride category  -> `lite`. A fare tier a driver sells. Renamed.
//   body style     -> `van` stays. `VehicleCategory { sedan, suv, van, luxury }`
//                     describes the shape of the car, and a van is a real body
//                     style. Renaming it would have made a car body selectable
//                     as a fare tier.
//
// A blanket find-and-replace across *.dart would have hit the English word
// "vanish", the word "van" in comments about vans, and the body-style enum. All
// three are still there after this runs, and `--check` prints them so you can
// see they were left alone on purpose.

import { readFileSync, writeFileSync } from 'node:fs';
import { execSync } from 'node:child_process';

const apply = process.argv.includes('--apply');

// Every substitution, with the reason it is safe. Each is anchored to the enum
// member or to a key/label that is derived from it -- never to the bare word.
const SUBSTITUTIONS = [
  ['RideCategory.van', 'RideCategory.lite', 'the enum member itself'],
  ['rideCard-van', 'rideCard-lite', 'a widget key built from the category name'],
  ['chip-van', 'chip-lite', 'a widget key built from the category name'],
  ["borderOf('van')", "borderOf('lite')", 'a test looking up by category name'],
  ["'Van'", "'Lite'", "the category's display label"],
  ['Asking Van drivers', 'Asking Lite drivers', 'a rendered string built from the label'],
];

// Files where `van` means the body style, or is the English word, and which
// must come out of this byte-for-byte unchanged. Checked, not trusted.
const DO_NOT_TOUCH = [
  'packages/mng_core/lib/src/models/vehicle.dart',
  'packages/mng_core/lib/src/models/category.dart',
  'packages/mng_core/lib/src/theme/tokens.dart',
  'packages/mng_core/test/car_topdown_icon_test.dart',
  'apps/driver/lib/src/data/supabase_driver_repository.dart',
  'apps/driver/test/support/fakes.dart',
];

const files = execSync('git ls-files "*.dart"', { encoding: 'utf8' })
  .split('\n').filter(Boolean);

let changed = 0, edits = 0;
for (const rel of files) {
  if (DO_NOT_TOUCH.includes(rel)) continue;
  const before = readFileSync(rel, 'utf8');
  let after = before;
  const applied = [];
  for (const [from, to, why] of SUBSTITUTIONS) {
    if (!after.includes(from)) continue;
    const n = after.split(from).length - 1;
    after = after.split(from).join(to);
    applied.push(`      ${n}x  ${from}  ->  ${to}   (${why})`);
    edits += n;
  }
  if (after !== before) {
    changed++;
    console.log(`  ${rel}`);
    applied.forEach((l) => console.log(l));
    if (apply) writeFileSync(rel, after);
  }
}

console.log(`\n  ${changed} file(s), ${edits} substitution(s)${apply ? ' written' : ' would change -- run with --apply'}`);

// The body style must have survived. These are the assertions that catch a
// rename that reached one layer too far.
console.log('\n=== these must still say van, and must be unchanged ===');
const guards = [
  ['packages/mng_core/lib/src/models/vehicle.dart', 'enum VehicleCategory { sedan, suv, van, luxury }'],
  ['apps/driver/lib/src/data/supabase_driver_repository.dart', "seats > 4 ? 'van' : 'sedan'"],
  ['apps/driver/test/support/fakes.dart', 'VehicleCategory.van'],
  ['packages/mng_core/test/car_topdown_icon_test.dart', 'does not read as a van'],
];
let clean = true;
for (const [rel, needle] of guards) {
  const has = readFileSync(rel, 'utf8').includes(needle);
  if (!has) clean = false;
  console.log(`  ${has ? 'ok  ' : 'LOST'}  ${needle}   (${rel})`);
}
console.log('\n  ' + (clean ? 'the body style survived the rename' : 'THE BODY STYLE WAS TOUCHED -- stop'));
process.exit(clean ? 0 : 1);
