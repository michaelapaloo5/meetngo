// The approval page compares three photographs to answer "is this the same
// person": the profile picture, the face check, and the licence.
//
// It has been comparing two.
//
// `documentsForAll` filtered rows with `REQUIRED_DOCUMENTS.includes(kind)`. The
// comment directly above it said the intent was to drop "a kind the list has
// never heard of", which is what `ALL_DOCUMENTS` tests. `REQUIRED_DOCUMENTS`
// tests something else: it also drops every optional kind, and `livenessFrame`
// is the only optional kind. So the face-check row was discarded on the way
// into the map that `handleList` builds its `documents` from, and the list never
// reported that a face check existed.
//
// The page then rendered its third tile from `have.has('livenessFrame')`, which
// was always false, and showed "not sent" under a heading reading "Face check".
//
// What makes this worth a test rather than a one-line fix: **it looked like
// working software.** An empty tile that says "not sent" is a perfectly ordinary
// state. A driver who did the face check, uploaded the frame, and saw it
// accepted is indistinguishable on that screen from a driver who skipped it. So
// an employee is asked to judge identity from two photographs while the screen
// implies they have three, and nothing anywhere says otherwise. The liveness
// check exists precisely to be compared against the licence; discarding the frame
// silently discards the point of running it.
import {
  assert,
  assertEquals,
  assertStringIncludes,
} from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import {
  ALL_DOCUMENTS,
  missingDocuments,
  optionalMissing,
  REQUIRED_DOCUMENTS,
} from '../admin-drivers/handler.ts';
import { staffPage } from '../admin-drivers/staff_page.ts';

/**
 * The filter as it is written in `index.ts`, restated here so the test pins the
 * rule rather than a copy of the file.
 *
 * The real function is not exported -- it is a closure inside the deps builder
 * and it needs a `ServiceClient`. What matters is which list the filter tests,
 * and that is one identifier. A source assertion for it is below so the two
 * cannot drift apart silently.
 */
function keptByTheFilter(kind: string): boolean {
  return ALL_DOCUMENTS.includes(kind);
}

Deno.test('the face check survives the document filter', () => {
  // The regression, in one assertion.
  assert(
    keptByTheFilter('livenessFrame'),
    'the face check is an optional kind and REQUIRED_DOCUMENTS does not contain '
      + 'it, so filtering against that list discards the row and the approval '
      + 'page can never show the photograph',
  );
});

Deno.test('the filter still drops a kind nobody has heard of', () => {
  // The reason the filter exists at all. An unknown kind must not reach an
  // employee as a name they cannot act on.
  assertEquals(keptByTheFilter('passportPhoto'), false);
  assertEquals(keptByTheFilter(''), false);
});

Deno.test('every kind the app can store survives the filter', () => {
  // A kind added to the constraint but not to the list would be uploaded,
  // stored, billed, and then invisible -- the same class of bug as the face
  // check, and the reason this is asserted over the whole list rather than one
  // value.
  for (const kind of ALL_DOCUMENTS) {
    assert(
      keptByTheFilter(kind),
      `${kind} is a kind the database accepts but the list would drop`,
    );
  }
});

Deno.test('the approval gate is unchanged: only the six required kinds block', () => {
  // The fix must not have widened what can be approved. `missingDocuments` is
  // what the server checks before approving, and it answers over
  // REQUIRED_DOCUMENTS, so a driver with no face check is still approvable --
  // which is the decision recorded in `livenessFrame.isRequired => false`.
  const everything = ALL_DOCUMENTS.map((kind) => ({ kind }));
  assertEquals(missingDocuments(everything), []);

  const requiredOnly = REQUIRED_DOCUMENTS.map((k) => ({ kind: k }));
  assertEquals(
    missingDocuments(requiredOnly),
    [],
    'all six required documents present means nothing is missing',
  );

  const withFace = [
    ...requiredOnly,
    { kind: 'livenessFrame' },
  ];
  assertEquals(missingDocuments(withFace), []);
  assertEquals(
    optionalMissing(withFace),
    [],
    'with the face check reported, it must stop being listed as absent',
  );
});

Deno.test('optionalMissing reported the face check as absent even when it was sent', () => {
  // The second half of the same bug, and the reason `optionalMissing` needed the
  // filter fixed rather than worked around. Before it, this returned
  // ['livenessFrame'] for a driver who had uploaded one, so a page that
  // described the driver as having no face check was correct about the database
  // and wrong about the driver.
  const sent = [...REQUIRED_DOCUMENTS, 'livenessFrame'].map((kind) => ({ kind }));
  assertEquals(
    optionalMissing(sent.filter((d) => d.kind !== 'livenessFrame')),
    ['livenessFrame'],
    'with the row filtered out, the face check is indistinguishable from never '
      + 'having been sent',
  );
  assertEquals(optionalMissing(sent), []);
});

Deno.test('the page really does ask for three photographs', () => {
  // The other half of the contract. The test above covers the server; this one
  // fails if the page stops requesting the comparison, which would be a quieter
  // regression in the other direction.
  const html = staffPage('https://project.supabase.co');
  for (const caption of ['Profile', 'Face check', 'Licence']) {
    assertStringIncludes(html, `'${caption}'`);
  }
  assertStringIncludes(html, "shot('livenessFrame', 'Face check')");
});

Deno.test('the filter in index.ts tests ALL_DOCUMENTS, not REQUIRED_DOCUMENTS', async () => {
  // Source-level, because the filter is a closure in a function that needs a
  // client. This is the assertion that notices if someone narrows it back.
  //
  // It is a source assertion rather than a behavioural one, which is normally
  // the weaker kind, and it is here as a belt to the braces above: if the
  // filter is ever changed back to REQUIRED_DOCUMENTS this fails immediately,
  // and the tests above -- which restate the rule rather than executing it --
  // would keep passing.
  const source = await Deno.readTextFile(
    new URL('../admin-drivers/index.ts', import.meta.url),
  );
  const filterLine = source
    .split('\n')
    .find((l) => l.includes('!') && l.includes('.includes(kind)'));
  assert(
    filterLine !== undefined,
    'the document filter line is gone or was renamed; the tests above restate '
      + 'the rule and cannot see it any more',
  );
  assertStringIncludes(
    filterLine,
    'ALL_DOCUMENTS.includes(kind)',
    'the document filter must test ALL_DOCUMENTS, or every optional kind is '
      + 'discarded and the approval page shows "not sent" for a document that '
      + 'was uploaded',
  );
  assert(
    !filterLine.includes('REQUIRED_DOCUMENTS.includes(kind)'),
    'REQUIRED_DOCUMENTS here drops the face check; ALL_DOCUMENTS is the list of '
      + 'kinds the list has heard of',
  );
});
