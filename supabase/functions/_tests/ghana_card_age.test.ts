// The age an employee sees next to a Ghana Card photograph.
//
// ## Why this is written out again rather than shared
//
// Because a Deno Edge Function cannot import Dart and an employee needs the age
// on the screen. So the arithmetic exists twice -- `ageFromGhanaCardDate` here and
// `ageFromGhanaCardDate` in `mng_core/lib/src/models/driver.dart` -- and two
// copies of a calculation is exactly the thing that drifts.
//
// These tests are the half of the pair that pins the *formats*. The Dart side is
// pinned by `ghana_card_parser_test.dart`. Between them, a format accepted by one
// and not the other shows up as a test failure on one side rather than as a
// driver whose age is blank on the app and 34 on the employee's screen.
//
// ## Why an unreadable date is null and not a number
//
// Because an age is the fastest thing an eye checks against a face. A blank reads
// as "we do not know" and makes an employee look at the photograph. A plausible
// wrong age is a plausible wrong approval.
import {
  assertEquals,
} from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import {
  ageFromGhanaCardDate,
} from '../admin-drivers/handler.ts';

const now = new Date(Date.UTC(2026, 8, 30)); // 30 September 2026

Deno.test('counts whole years and not a day early', () => {
  // The birthday is today, so the driver turns 32 today.
  assertEquals(ageFromGhanaCardDate('30/09/1994', now), 32);
  // Yesterday's birthday: already 32.
  assertEquals(ageFromGhanaCardDate('29/09/1994', now), 32);
  // Tomorrow's: still 31.
  assertEquals(ageFromGhanaCardDate('01/10/1994', now), 31);
  // A month either side of the boundary.
  assertEquals(ageFromGhanaCardDate('30/10/1994', now), 31);
  assertEquals(ageFromGhanaCardDate('30/08/1994', now), 32);
});

Deno.test('reads the same formats the app accepts', () => {
  // The four in `ghana_card_parser_test.dart`. If one side is loosened and the
  // other is not, this is where it shows.
  assertEquals(ageFromGhanaCardDate('14/03/1994', now), 32);
  assertEquals(ageFromGhanaCardDate('14-03-1994', now), 32);
  assertEquals(ageFromGhanaCardDate('1994-03-14', now), 32);
  assertEquals(ageFromGhanaCardDate('14/03/94', now), 32);
  // Dots, which a card reader can produce from a colon-ish separator.
  assertEquals(ageFromGhanaCardDate('14.03.1994', now), 32);
});

Deno.test('a two-digit year follows the same rule as the app', () => {
  assertEquals(ageFromGhanaCardDate('14/03/94', now), 32);
  assertEquals(ageFromGhanaCardDate('14/03/24', now), 2);
  // `30` is the boundary: 30 or below is 20xx.
  assertEquals(ageFromGhanaCardDate('14/03/30', now), null); // 2030 is the future
  assertEquals(ageFromGhanaCardDate('14/03/29', now), null);
  assertEquals(ageFromGhanaCardDate('14/03/89', now), 37);
});

Deno.test('an unreadable date is no age rather than a wrong one', () => {
  for (const bad of [
    null,
    undefined,
    '',
    '   ',
    'not a date',
    '3/13/994',
    '00/00/0000',
    '31/02/1994',
    '14/13/1994',
    '1994-13-14',
  ]) {
    assertEquals(
      ageFromGhanaCardDate(bad, now),
      null,
      `expected no age for ${JSON.stringify(bad)}`,
    );
  }
});

Deno.test('a date in the future is no age', () => {
  assertEquals(ageFromGhanaCardDate('01/01/2030', now), null);
  assertEquals(ageFromGhanaCardDate('01/01/2200', now), null);
});

Deno.test('a date of birth before 1900 is no age, and 1900 is', () => {
  // Below 1900 is a misread rather than a very old driver, and a two-digit year
  // cannot produce one anyway -- this is the floor for a four-digit one.
  assertEquals(ageFromGhanaCardDate('01/01/1899', now), null);

  // 1900 itself is *allowed*, and gives 126. That is deliberate and it is the
  // honest answer: the bound here is about whether a string is plausibly a date,
  // not about whether the driver is a sensible age. A 126-year-old applicant is
  // a thing an employee looks at and declines -- the photograph is right there
  // beside the number -- and a function that quietly returned null for it would
  // hide the one field that makes the application obviously wrong. Hiding it
  // would make a fraud harder to notice, not safer.
  //
  // The Dart side has the same bound and the same reasoning; see
  // `_date` in `mng_core/lib/src/models/driver.dart`.
  assertEquals(ageFromGhanaCardDate('01/01/1900', now), 126);
});
