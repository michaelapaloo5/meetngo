import { assert, assertEquals } from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import {
  decide,
  isOpen,
  looksLikeCoordinates,
  shapeReport,
  stopText,
  triageOrder,
} from '../admin-drivers/reports.ts';
import type { ReportRow } from '../admin-drivers/reports.ts';

function row(over: Partial<ReportRow> = {}): ReportRow {
  // The cast is the one place a partial override meets a complete row.
  // Without it TypeScript widens every overridden field to `| undefined`, and
  // that has to be cast away at each use instead of once here.
  return {
    id: 'r1',
    tripId: 't1',
    reason: 'Driver never arrived',
    detail: '',
    createdAt: new Date(Date.now() - 30 * 60000).toISOString(),
    dismissedAt: null,
    dismissedBy: null,
    dismissNote: '',
    contactedAt: null,
    contactedBy: null,
    riderName: 'Edem Apaloo',
    riderPhone: '0594922288',
    tripState: 'completed',
    tripFareGhs: 56.86,
    tripCategory: 'standard',
    pickupJson: { label: 'Pickup', address: 'Obibini Street, Avenor, Ghana' },
    dropoffJson: { label: 'Dropoff', address: 'Dansoman Police Station' },
    driverId: 'd1',
    driverName: 'Ama Boateng',
    driverPhone: '0201234567',
    ...over,
  } as ReportRow;
}

Deno.test('a coordinate pair is recognised in the shape the old build wrote', () => {
  // The rider app has this rule in trip_copy.dart and asserts the same strings.
  // Two copies is a real risk of them drifting apart, so these cases are the
  // ones worth keeping in step.
  assert(looksLikeCoordinates('5.5879, -0.2204'));
  assert(looksLikeCoordinates('5.6037,-0.1870'));
  assert(looksLikeCoordinates('  5.6037 , -0.1870  '));
  assert(looksLikeCoordinates('6, -1'));
});

Deno.test('one number is not a coordinate pair', () => {
  // A single number is a house number or a shop name. Treating it as a
  // coordinate would throw away a real address.
  assert(!looksLikeCoordinates('-33.8688'));
});

Deno.test('a real place with a comma in it is not a coordinate pair', () => {
  // The test that decides whether this rule is safe to have at all. If any of
  // these matched, replacing them with "Pickup" would be worse than the
  // coordinate problem ever was.
  assert(!looksLikeCoordinates('Spintex, Addogonnо, Nungua'));
  assert(!looksLikeCoordinates('House 12, Oxford Street'));
  assert(!looksLikeCoordinates('Airport Residential, Accra'));
  assert(!looksLikeCoordinates('Shop 4, Block 7, Cantonments'));
  assert(!looksLikeCoordinates('5 Airport Residential, Accra'));
});

Deno.test('a coordinate is never shown to staff as a place', () => {
  // These rows exist in the database and are not going away. A support page
  // showing "5.5879, -0.2204" where a rider's address should be is the same
  // defect the rider app had on its home screen.
  const shaped = shapeReport(row({
    pickupJson: { label: 'Pickup', address: '5.5879, -0.2204' },
    dropoffJson: { label: '5.6037,-0.1870', address: '   ' },
  }));
  assertEquals(shaped.pickupText, 'Pickup');
  // Both halves are a pair here, so neither is usable and it falls back to the
  // plain word rather than printing two numbers.
  assertEquals(shaped.dropoffText, 'Dropoff');
});

Deno.test('a lone number is left alone, and that limit is deliberate', () => {
  // Recorded rather than hidden. A bare "-0.2204" is indistinguishable from a
  // house number, and treating every lone number as a coordinate would replace
  // real short addresses with the word "Pickup". The rider app draws the same
  // line for the same reason; the pair is what the old build actually wrote.
  assertEquals(
    shapeReport(row({ dropoffJson: { label: '12', address: '' } })).dropoffText,
    '12',
  );
  assertEquals(
    shapeReport(row({ dropoffJson: { label: '-0.2204', address: '' } })).dropoffText,
    '-0.2204',
  );
});

Deno.test('the jsonb stop column is read without throwing on anything', () => {
  // This is the boundary between the database and the page. One bad row must not
  // be able to take the whole reports list down, so every shape a jsonb column
  // can come back as gets a case.
  assertEquals(stopText(null, 'Pickup'), 'Pickup');
  assertEquals(stopText(undefined, 'Pickup'), 'Pickup');
  assertEquals(stopText('a string', 'Pickup'), 'Pickup');
  assertEquals(stopText(42, 'Pickup'), 'Pickup');
  assertEquals(stopText([], 'Pickup'), 'Pickup');
  assertEquals(stopText({}, 'Pickup'), 'Pickup');
  assertEquals(stopText({ label: null, address: null }, 'Pickup'), 'Pickup');
  assertEquals(
    stopText({ label: 'Pickup', address: 'Obibini Street, Avenor, Ghana' }, 'Pickup'),
    'Obibini Street, Avenor, Ghana',
  );
  // The real defect, straight out of the column.
  assertEquals(stopText({ label: 'Pickup', address: '5.5879, -0.2204' }, 'Pickup'), 'Pickup');
});

Deno.test('a real address is preferred over the bare label', () => {
  const shaped = shapeReport(row());
  assertEquals(shaped.pickupText, 'Obibini Street, Avenor, Ghana');
  assertEquals(shaped.dropoffText, 'Dansoman Police Station');
});

Deno.test('an open report is open, and a dismissed one is not', () => {
  assert(isOpen(row()));
  assert(!isOpen(row({ dismissedAt: new Date().toISOString(), dismissedBy: 'Ama' })));
  // The column is nullable and the page must not treat an absent value as
  // "dismissed by nobody at some point".
  assert(isOpen(row({ dismissedAt: null })));
});

Deno.test('a blank reason reads as "not given", never as nothing', () => {
  // An empty field on a screen reads as a loading failure, and an employee who
  // sees one assumes the report is empty and moves on.
  const shaped = shapeReport(row({ reason: '   ' }));
  assertEquals(shaped.reason, 'not given');
  // A real reason is untouched.
  assertEquals(shapeReport(row({ reason: 'Overcharged' })).reason, 'Overcharged');
});

Deno.test('a missing rider number is reported as missing', () => {
  // The page offers a call button off this. Without it the button opens an empty
  // dialler, which is the same as having no button and looks worse.
  assertEquals(shapeReport(row({ riderPhone: '' })).hasRiderNumber, false);
  assertEquals(shapeReport(row({ riderPhone: '0594922288' })).hasRiderNumber, true);
  assertEquals(shapeReport(row({ riderPhone: null })).hasRiderNumber, false);
});

Deno.test('a missing rider name does not render as an empty heading', () => {
  assertEquals(shapeReport(row({ riderName: '' })).riderName, '(no name)');
});

Deno.test('an unparseable created_at does not become NaN minutes', () => {
  // NaN here renders as "NaN min ago" and reads as a fault in the page rather
  // than bad data in one row.
  const shaped = shapeReport(row({ createdAt: 'not-a-date' }));
  assertEquals(shaped.ageMinutes, 0);
  assert(Number.isFinite(shaped.ageMinutes));
});

Deno.test('age is whole minutes and never negative', () => {
  const future = new Date(Date.now() + 600000).toISOString();
  assertEquals(shapeReport(row({ createdAt: future })).ageMinutes, 0);
});

Deno.test('the queue is open work first, then handled, newest first in each', () => {
  const openOld = shapeReport(row({ id: 'open-old', createdAt: hoursAgo(9) }));
  const openNew = shapeReport(row({ id: 'open-new', createdAt: hoursAgo(1) }));
  const doneOld = shapeReport(row({
    id: 'done-old',
    createdAt: hoursAgo(9),
    dismissedAt: hoursAgo(8),
    dismissedBy: 'Ama',
  }));
  const doneNew = shapeReport(row({
    id: 'done-new',
    createdAt: hoursAgo(2),
    dismissedAt: hoursAgo(1),
    dismissedBy: 'Ama',
  }));

  assertEquals(
    triageOrder([doneOld, doneNew, openOld, openNew]).map((r) => r.id),
    // Open first, newest of the open first. The handled ones follow, newest
    // first, so the live queue is never buried under closed rows.
    ['open-new', 'open-old', 'done-new', 'done-old'],
  );
});

Deno.test('triageOrder does not mutate what it was given', () => {
  // The page holds this array as the queue and re-renders from it. Sorting in
  // place would make the order depend on whether anything had been looked at.
  const rows = [
    shapeReport(row({ id: 'b', createdAt: hoursAgo(1) })),
    shapeReport(row({ id: 'a', createdAt: hoursAgo(5) })),
  ];
  const before = rows.map((r) => r.id);
  triageOrder(rows);
  assertEquals(rows.map((r) => r.id), before);
});

Deno.test('dismissing an open report records who and when', () => {
  const now = new Date('2026-10-07T12:00:00.000Z');
  const result = decide(row(), { action: 'dismiss', by: 'Ama Boateng', now });
  assert(result.ok);
  assertEquals(result.write.dismissed_at, '2026-10-07T12:00:00.000Z');
  assertEquals(result.write.dismissed_by, 'Ama Boateng');
});

Deno.test('dismissing twice is refused and names who did it first', () => {
  // The columns are the audit trail. Overwriting them with the last person to
  // press the button makes the log look complete when it is not.
  const now = new Date();
  const result = decide(
    row({ dismissedAt: hoursAgo(3), dismissedBy: 'Ama Boateng' }),
    { action: 'dismiss', by: 'Kojo Mensah', now },
  );
  assert(!result.ok);
  assertEquals(result.status, 409);
  assert(result.error.includes('Ama Boateng'));
});

Deno.test('reopening clears the attribution as well as the timestamp', () => {
  // A reopened row that kept "handled by" would say it was handled while it sat
  // in the open queue.
  const now = new Date();
  const result = decide(
    row({ dismissedAt: hoursAgo(3), dismissedBy: 'Ama Boateng' }),
    { action: 'reopen', by: 'Kojo Mensah', now },
  );
  assert(result.ok);
  assertEquals(result.write.dismissed_at, null);
  assertEquals(result.write.dismissed_by, null);
});

Deno.test('reopening an already-open report is refused', () => {
  const result = decide(row(), { action: 'reopen', by: 'Kojo Mensah', now: new Date() });
  assert(!result.ok);
  assertEquals(result.status, 409);
});

Deno.test('contacting does not dismiss', () => {
  // Answering somebody and closing their complaint are two different acts, and
  // conflating them hides the fact that it was answered but not resolved.
  const result = decide(row(), { action: 'contact', by: 'Ama Boateng', now: new Date() });
  assert(result.ok);
  assertEquals(result.write.dismissed_at, null);
  assertEquals(result.write.dismissed_by, null);
});

Deno.test('no decision without a named member of staff', () => {
  // A dismissal with nobody against it is the same as no dismissal, and the
  // column exists to answer "which of my staff did this".
  for (const action of ['dismiss', 'reopen', 'contact'] as const) {
    const result = decide(row(), { action, by: '   ', now: new Date() });
    assert(!result.ok, action + ' was allowed with no name');
    assertEquals(result.status, 400);
  }
});

function hoursAgo(h: number): string {
  return new Date(Date.now() - h * 3600000).toISOString();
}
