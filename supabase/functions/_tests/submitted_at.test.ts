// What "submitted" means, and why it is not when the account was made.
//
// The bug this covers was a number, not a permission, and it is the kind that
// survives every other check in this directory: the function type-checked, the
// page rendered, the queue listed the driver, the documents were all there, and
// the age beside his name was wrong.
//
// It was `profiles.created_at`. One real driver signed up on the 28th and
// uploaded all seven documents on the 30th, and the queue said "2 days ago" --
// next to six photographs taken that morning. An employee reading that is
// judging the freshness of the evidence wrongly, and being told the application
// has been waiting two days when it arrived this morning.
import {
  assert,
  assertEquals,
} from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import {
  REQUIRED_DOCUMENTS,
  submittedAtFor,
} from '../admin-drivers/handler.ts';

const ACCOUNT = '2026-09-28T18:20:00.000Z';

/** One document row, as `documentsForAll` builds it. */
function doc(kind: string, createdAt: string) {
  return { kind, path: `d/${kind}.jpg`, createdAt };
}

/**
 * A driver who has sent everything, one document per hour on the 30th, 07:00
 * through 12:00.
 *
 * The hours are padded. The first version wrote `0${i + 7}`, which produced
 * `T010:00:00.000Z` for the last two documents -- an unparseable string. Four
 * tests failed on it, and the cause was here rather than in `submittedAtFor`;
 * worth separating the two, because a fixture that is quietly malformed makes a
 * correct implementation look broken.
 */
function completeOn30th(): Array<{ kind: string; path: string; createdAt: string }> {
  return REQUIRED_DOCUMENTS.map((kind, i) =>
    doc(kind, `2026-09-30T${String(i + 7).padStart(2, '0')}:00:00.000Z`)
  );
}

Deno.test('a complete application is dated by its last document, not the account', () => {
  // The regression, in one assertion.
  assertEquals(
    submittedAtFor(ACCOUNT, completeOn30th()),
    '2026-09-30T12:00:00.000Z',
    'the newest required document decides when the application was submitted; '
      + 'the account date is 2 days older and describes nothing about the '
      + 'photographs being judged',
  );
});

Deno.test('the account date is only used when there is nothing else', () => {
  // The one case where the old behaviour was right: no documents, so there is
  // nothing to date the application by.
  assertEquals(submittedAtFor(ACCOUNT, []), ACCOUNT);
});

Deno.test('an incomplete application is dated by the last thing they sent', () => {
  // Progress rather than readiness. The page lists what is missing separately,
  // so this number is never read as "ready to approve".
  assertEquals(
    submittedAtFor(ACCOUNT, [
      doc('profilePhoto', '2026-09-30T08:00:00.000Z'),
      doc('ghanaCardPhoto', '2026-09-30T09:30:00.000Z'),
    ]),
    '2026-09-30T09:30:00.000Z',
  );
});

Deno.test('an optional document does not make an application look newer', () => {
  // `livenessFrame` is optional, and it is the document a driver sends LAST --
  // it is the final step of onboarding. If it counted, every application would
  // be dated by the face check rather than by the licence and Ghana Card that
  // are actually being judged, and the number would drift later every time the
  // check was retried.
  const withFace = [
    ...completeOn30th(),
    doc('livenessFrame', '2026-10-05T11:00:00.000Z'),
  ];
  assertEquals(
    submittedAtFor(ACCOUNT, withFace),
    '2026-09-30T12:00:00.000Z',
  );
});

Deno.test('an unknown kind is ignored rather than dated by', () => {
  // Belt and braces. `documentsForAll` already filters these out, so this
  // cannot happen today -- but the function is the one place that decides what
  // "submitted" means, and a future caller that forgot the filter would
  // otherwise silently date every application by a document nobody can judge.
  assertEquals(
    submittedAtFor(ACCOUNT, [
      ...completeOn30th(),
      doc('somethingNew', '2026-11-01T00:00:00.000Z'),
    ]),
    '2026-09-30T12:00:00.000Z',
  );
});

Deno.test('a row with no timestamp is skipped, not allowed to win', () => {
  // `createdAt` is optional because `documentsFor` -- the single signed-URL
  // path -- does not read it. If that path is ever pointed here, a missing
  // timestamp must fall back rather than become the newest date.
  const withGap = completeOn30th().map((d) =>
    d.kind === 'roadWorthy' ? { kind: d.kind, path: d.path } : d
  );
  assertEquals(
    submittedAtFor(ACCOUNT, withGap),
    '2026-09-30T12:00:00.000Z',
  );
});

Deno.test('an unparseable timestamp cannot reach the page as NaN', () => {
  // `new Date('not a date')` is NaN, and a NaN that reached `ago()` on the page
  // renders as "NaN days ago". Losing one timestamp to the account fallback is
  // a smaller failure than showing one, so it is the account date that is
  // returned.
  assertEquals(
    submittedAtFor(ACCOUNT, [
      doc('profilePhoto', 'not a date'),
      doc('ghanaCardPhoto', ''),
      doc('driversLicence', '2026-09-30T10:00:00.000Z'),
    ]),
    '2026-09-30T10:00:00.000Z',
  );

  // And when every timestamp is rubbish, the account date -- never "NaN".
  const allBad = submittedAtFor(ACCOUNT, [doc('profilePhoto', 'nope')]);
  assert(!allBad.includes('NaN'), 'a NaN reached the returned timestamp');
  assertEquals(allBad, ACCOUNT);
});

Deno.test('the result is always a parseable ISO timestamp', () => {
  // The page hands this straight to `new Date(...).getTime()`, and an empty
  // string there produces a blank age with no explanation.
  for (const docs of [
    [],
    completeOn30th(),
    [doc('profilePhoto', 'nope')],
    [doc('profilePhoto', '2026-09-30T10:00:00Z')],
  ]) {
    const out = submittedAtFor(ACCOUNT, docs);
    assert(
      !Number.isNaN(Date.parse(out)),
      `submittedAtFor returned something unparseable: "${out}"`,
    );
  }
});
