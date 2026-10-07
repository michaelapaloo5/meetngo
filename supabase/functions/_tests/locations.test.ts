import { assert, assertEquals } from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import {
  agoText,
  keepIntent,
  MAX_KEEP_DAYS,
  orderLocations,
  RETENTION_DAYS,
  shapeLocation,
  shapeRecording,
  stopIntent,
  whereText,
} from '../admin-drivers/locations.ts';
import type { LocationRow } from '../admin-drivers/locations.ts';

function row(over: Partial<LocationRow> = {}): LocationRow {
  return {
    profileId: 'p1',
    who: 'driver',
    name: 'Ama Boateng',
    phone: '0594922288',
    point: 'SRID=4326;POINT(-0.187 5.6037)',
    updatedAt: new Date(Date.now() - 5 * 60000).toISOString(),
    placeLabel: 'Obibini Street, Avenor, Ghana',
    placeLabelAt: new Date(Date.now() - 5 * 60000).toISOString(),
    tripId: null,
    tripState: null,
    ...over,
  };
}

Deno.test('a place name is shown as itself', () => {
  assertEquals(whereText('Obibini Street, Avenor, Ghana'), 'Obibini Street, Avenor, Ghana');
});

Deno.test('a missing place name says so and never shows a coordinate', () => {
  // The point is in the row and is deliberately not returned to the page. A
  // support screen answering "where is this person" with a latitude is the exact
  // defect this whole rule exists to prevent.
  for (const missing of [null, undefined, '', '   ']) {
    assertEquals(whereText(missing), 'place name unavailable');
  }
});

Deno.test('a coordinate stored as a place name is refused', () => {
  // Defensive: if a geocoder is ever pointed at the wrong field, this is the
  // last thing standing between that and a latitude on a staff screen.
  assertEquals(whereText('5.5879, -0.2204'), 'place name unavailable');
  assertEquals(whereText('-0.2204, 5.6037'), 'place name unavailable');
  // A real address with a comma survives.
  assertEquals(whereText('Spintex, Addogonnо, Nungua'), 'Spintex, Addogonnо, Nungua');
});

Deno.test('a row is only worth a geocoder call when its label is missing', () => {
  assertEquals(shapeLocation(row(), new Date()).needsLabel, false);
  assertEquals(shapeLocation(row({ placeLabel: null }), new Date()).needsLabel, true);
});

Deno.test('an empty name does not render as an empty heading', () => {
  assertEquals(shapeLocation(row({ name: '  ' }), new Date()).name, '(no name)');
});

Deno.test('a rider with no phone says so rather than offering an empty dialler', () => {
  assertEquals(shapeLocation(row({ phone: '' }), new Date()).hasPhone, false);
  assertEquals(shapeLocation(row(), new Date()).hasPhone, true);
});

Deno.test('age reads in whole units and never goes negative', () => {
  const now = new Date();
  const at = (mins: number) => new Date(now.getTime() - mins * 60000).toISOString();
  assertEquals(agoText(at(0), now), 'just now');
  assertEquals(agoText(at(12), now), '12 min ago');
  assertEquals(agoText(at(1), now), '1 min ago');
  assertEquals(agoText(at(60), now), '1 hr ago');
  assertEquals(agoText(at(180), now), '3 hrs ago');
  assertEquals(agoText(at(1440), now), '1 day ago');
  assertEquals(agoText(at(4320), now), '3 days ago');
  // A clock skew that puts the row in the future must not read as "-2 min ago".
  assertEquals(agoText(new Date(now.getTime() + 600000).toISOString(), now), 'just now');
  // Unreadable dates do not become NaN min ago.
  assertEquals(agoText('not-a-date', now), 'unknown');
  assertEquals(agoText(null, now), 'unknown');
});

Deno.test('riders are listed before drivers, newest first within each', () => {
  const now = new Date();
  const s = (over: Partial<LocationRow>) => shapeLocation(row(over), now);
  const rows = [
    s({ profileId: 'd-old', who: 'driver', updatedAt: new Date(now.getTime() - 600000).toISOString() }),
    s({ profileId: 'r-old', who: 'rider', updatedAt: new Date(now.getTime() - 600000).toISOString() }),
    s({ profileId: 'd-new', who: 'driver', updatedAt: new Date(now.getTime() - 60000).toISOString() }),
    s({ profileId: 'r-new', who: 'rider', updatedAt: new Date(now.getTime() - 60000).toISOString() }),
  ];
  assertEquals(
    orderLocations(rows).map((r) => r.profileId),
    // Riders first: a rider mid-trip is waiting on somebody. Then newest.
    ['r-new', 'r-old', 'd-new', 'd-old'],
  );
});

Deno.test('orderLocations does not mutate what it was given', () => {
  const now = new Date();
  const rows = [
    shapeLocation(row({ profileId: 'b', who: 'rider' }), now),
    shapeLocation(row({ profileId: 'a', who: 'driver' }), now),
  ];
  orderLocations(rows);
  assertEquals(rows.map((r) => r.profileId), ['b', 'a']);
});

Deno.test('keeping location data needs a named member of staff', () => {
  const result = keepIntent({ by: '  ', days: 7, now: new Date() });
  assert(!result.ok);
  assertEquals(result.status, 400);
});

Deno.test('keeping location data needs a real duration', () => {
  for (const days of [0, -3, NaN]) {
    const result = keepIntent({ by: 'Ama Boateng', days, now: new Date() });
    assert(!result.ok, String(days) + ' was allowed');
  }
});

Deno.test('keeping location data is capped', () => {
  // Asking to keep it for a year is the failure this cap exists for. It is
  // clamped rather than refused, because a member of staff mid-investigation
  // should get the thirty days they asked for in the way they understand, and
  // the banner then says when it ends.
  const now = new Date('2026-10-07T12:00:00.000Z');
  const result = keepIntent({ by: 'Ama Boateng', days: 365, now });
  assert(result.ok);
  assertEquals(result.write.keep_recording, true);
  assertEquals(result.write.updated_by, 'Ama Boateng');
  assertEquals(result.write.keep_until, '2026-11-06T12:00:00.000Z');
  assertEquals(MAX_KEEP_DAYS, 30);
});

Deno.test('the normal retention is a fortnight', () => {
  assertEquals(RETENTION_DAYS, 14);
});

Deno.test('stopping is always allowed', () => {
  const result = stopIntent('Ama Boateng');
  assertEquals(result.write.keep_recording, false);
  assertEquals(result.write.keep_until, null);
  assertEquals(result.write.updated_by, 'Ama Boateng');
});

Deno.test('the banner counts down in whole days', () => {
  const now = new Date('2026-10-07T12:00:00.000Z');
  assertEquals(
    shapeRecording(true, '2026-10-10T12:00:00.000Z', 'Ama Boateng', now).daysLeft,
    3,
  );
  assertEquals(shapeRecording(true, null, 'Ama Boateng', now).keep, false);
  assertEquals(shapeRecording(false, '2026-10-10T12:00:00.000Z', 'Ama Boateng', now).keep, false);
});

Deno.test('an unreadable keep-until reads as off, never as keeping forever', () => {
  // The unsafe direction here is a row that says "keeping" and can never end,
  // because that silently disables the purge. Broken data must fall back to
  // letting the purge run.
  const state = shapeRecording(true, 'not-a-date', 'Ama Boateng', new Date());
  assertEquals(state.keep, false);
  assertEquals(state.daysLeft, null);
});
