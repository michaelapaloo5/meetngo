// Triage for rider reports. Pure: it shapes rows and decides writes, and touches
// no database, so every rule below is testable without one.
//
// ## What "contact the rider" actually is
//
// There is no messaging channel between the app and a rider. No push, no inbox,
// no SMS integration, nothing. So this does not send anybody a message, and the
// page does not pretend to.
//
// What it does is open the rider's dialler or mail client on the staff member's
// own phone, and record that staff did so and when. That is the whole of it, and
// it is stated here because "contact the rider from the page" reads like a feature
// that does not exist yet. If a real channel is ever added, `contactIntent` is
// the one place that has to change, and it should change to say so rather than
// this quietly growing a `sendMessage` that nobody can deliver.
//
// ## Why a dismissed report cannot be dismissed again
//
// The columns record who and when. Overwriting them would replace one person's
// name and another's with whichever was pressed last, which makes the log worse
// than no log: it looks complete and is not. So a second dismiss is refused, with
// a sentence that names the person and the time, and the page offers to reopen
// instead.
//
// Reopening is deliberate and separate. A report dismissed by mistake and left
// closed is a rider's complaint disappearing, so it has to be reversible -- but as
// its own act, by its own button, with the same attribution.

/**
 * A `trip_reports` row as the database returns it, joined to the people and the
 * ride.
 *
 * Most of it is nullable, and that is not laziness in the type -- it is the shape
 * of the data. A rider can have no name on file or no phone, a driver can be gone
 * from the join because the account was deleted, and a fare is null on a ride
 * that was cancelled before one was set. Typing those as `string` and `number`
 * only moves the null to the page, where it renders as "undefined" in the middle
 * of a rider's complaint.
 */
export interface ReportRow {
  id: string;
  tripId: string;
  reason: string | null;
  detail: string | null;
  createdAt: string;
  dismissedAt: string | null;
  dismissedBy: string | null;
  dismissNote: string | null;
  contactedAt: string | null;
  contactedBy: string | null;

  riderName: string | null;
  riderPhone: string | null;
  // There is deliberately no email field. `profiles` has no email column --
  // email lives in `auth.users` -- so a rider's address is not reachable from
  // this join, and a field that can only ever be null is a button that opens an
  // empty mail client. Contacting a rider is a phone call; see the header.


  tripState: string | null;
  /**
   * `trips.fare_ghs` is `not null`, so a real row always has one. Typed
   * nullable anyway because the join is built here and a missing column reads
   * as undefined rather than throwing -- and a fare that shows as "undefined"
   * is worse than one that admits it was not read.
   */
  tripFareGhs: number | null;
  tripCategory: string | null;
  /**
   * The whole `trips.pickup` / `trips.dropoff` jsonb value, which holds
   * `{label, point, address}` -- there are no `*_label` columns. Carried raw
   * rather than split into two strings so that resolving it happens in exactly
   * one place, [stopText], instead of once in the query layer and again here.
   */
  pickupJson: unknown;
  dropoffJson: unknown;

  driverId: string | null;
  driverName: string | null;
  driverPhone: string | null;
}

/** A report as the page draws it. */
export interface TriageReport {
  id: string;
  reason: string;
  detail: string;
  at: string;
  /** Whole minutes, so the page does not have to round the same way twice. */
  ageMinutes: number;
  open: boolean;
  dismissedAt: string | null;
  dismissedBy: string | null;
  dismissNote: string;
  contactedAt: string | null;
  contactedBy: string | null;
  riderName: string;
  riderPhone: string;
  hasRiderNumber: boolean;
  tripId: string;
  tripState: string;
  /** Null means the fare was not read; the page must say so rather than show 0. */
  fareGhs: number | null;
  category: string;
  /** Never a coordinate. See [placeText]. */
  pickupText: string;
  /** Never a coordinate. See [placeText]. */
  dropoffText: string;
  driverId: string | null;
  driverName: string;
}

/**
 * Whether a string is a latitude/longitude pair rather than a place name.
 *
 * Ported deliberately from the rider app's `trip_copy.dart`, which has the same
 * function with the same name, because the problem is the same one in both
 * places: a build wrote coordinates into `pickup.label`, those rows are real and
 * permanent, and a support page that printed them would be showing a member of
 * staff a latitude instead of an address.
 *
 * The false-positive cases are the reason this function is allowed to exist at
 * all. "Spintex, Addogonnо, Nungua" and "House 12, Oxford Street" contain commas
 * and numbers and are perfectly good addresses; if this matched them, replacing
 * them with "Pickup" would cause more confusion than it prevents.
 */
export function looksLikeCoordinates(value: string | null | undefined): boolean {
  if (value === null || value === undefined) return false;
  return /^\s*-?\d+(?:\.\d+)?\s*,\s*-?\d+(?:\.\d+)?\s*$/.test(value);
}

/**
 * The best available name for a place, and never a coordinate.
 *
 * Prefers the address, then the label, then a plain word. A support page is the
 * last place that should show a rider's home as two numbers.
 */
export function placeText(
  label: string | null | undefined,
  address: string | null | undefined,
  fallback: string,
): string {
  if (!isBlank(address) && !looksLikeCoordinates(address)) return String(address).trim();
  if (!isBlank(label) && !looksLikeCoordinates(label)) return String(label).trim();
  return fallback;
}

/**
 * The place name out of a `trips.pickup` / `trips.dropoff` jsonb value.
 *
 * PostgREST cannot pull a key out of jsonb in a select string, so the whole
 * column comes back and is read here. `unknown` rather than a json type because
 * this is the boundary: anything can come back from a column, including nothing
 * at all if the join finds no trip, and a function that throws on that takes the
 * whole reports page down for one bad row.
 */
export function stopText(raw: unknown, fallback: string): string {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return fallback;
  const stop = raw as Record<string, unknown>;
  return placeText(
    stop['label'] == null ? null : String(stop['label']),
    stop['address'] == null ? null : String(stop['address']),
    fallback,
  );
}

/** Whether a row is still waiting on somebody. */
export function isOpen(row: Pick<ReportRow, 'dismissedAt'>): boolean {
  return row.dismissedAt === null || row.dismissedAt === undefined;
}

export function shapeReport(row: ReportRow): TriageReport {
  const created = new Date(row.createdAt).getTime();
  // A `createdAt` that will not parse is somebody's data being wrong, not the
  // queue being unanswerable. Age falls back to 0 rather than NaN, because NaN
  // in this field renders as "NaN min ago" and reads like a bug in the page.
  const ageMinutes = Number.isFinite(created)
    ? Math.max(0, Math.round((Date.now() - created) / 60000))
    : 0;

  return {
    id: row.id,
    // Never blank. A rider who typed nothing gets "not given" rather than an
    // empty row that reads as a loading failure -- the same rule the KYC page
    // applies to a Ghana Card field, for the same reason.
    reason: isBlank(row.reason) ? 'not given' : String(row.reason),
    detail: isBlank(row.detail) ? '' : String(row.detail),
    at: row.createdAt,
    ageMinutes,
    open: isOpen(row),
    dismissedAt: row.dismissedAt ?? null,
    dismissedBy: row.dismissedBy ?? null,
    dismissNote: row.dismissNote ?? '',
    contactedAt: row.contactedAt ?? null,
    contactedBy: row.contactedBy ?? null,
    riderName: isBlank(row.riderName) ? '(no name)' : String(row.riderName),
    riderPhone: row.riderPhone ?? '',
    // The page uses this to decide whether to offer the call button at all,
    // rather than offering one that opens an empty dialler.
    hasRiderNumber: !isBlank(row.riderPhone),
    tripId: row.tripId,
    tripState: String(row.tripState ?? 'unknown'),
    fareGhs: row.tripFareGhs,
    category: isBlank(row.tripCategory) ? 'unknown' : String(row.tripCategory),
    pickupText: stopText(row.pickupJson, 'Pickup'),
    dropoffText: stopText(row.dropoffJson, 'Dropoff'),
    driverId: row.driverId ?? null,
    driverName: isBlank(row.driverName) ? 'no driver' : String(row.driverName),
  };
}

/**
 * The order a support inbox works in: everything still open, newest first, then
 * everything already handled, newest first.
 *
 * Open before handled rather than purely by age, because the two questions are
 * different. "What is waiting?" is the queue. "What did we already do?" is a
 * lookup somebody does once, and burying the live work under a fortnight of closed
 * rows is how a real report gets missed.
 */
export function triageOrder(rows: TriageReport[]): TriageReport[] {
  return rows.slice().sort(function (a, b) {
    if (a.open !== b.open) return a.open ? -1 : 1;
    // Ascending age, because a *smaller* age is the newer report. Sorting this
    // descending puts the oldest complaint at the top of the queue with every
    // fresher one stacked under it, which is the exact inverse of what an
    // employee opening the page needs to see.
    return a.ageMinutes - b.ageMinutes;
  });
}

export interface StaffAction {
  action: 'dismiss' | 'reopen' | 'contact';
  by: string;
  note?: string;
  now: Date;
}

export type Intent =
  | { ok: true; write: { dismissed_at: string | null; dismissed_by: string | null; dismiss_note: string } }
  | { ok: false; status: number; error: string };

/**
 * Whether a named member of staff may record a decision, and what the write is.
 *
 * The name is required rather than optional. A dismissal with nobody against it
 * is the same as no dismissal, and the column exists precisely to answer "which
 * of my staff did this" -- so an empty name is refused rather than stored.
 */
export function decide(
  row: Pick<ReportRow, 'dismissedAt' | 'dismissedBy'>,
  ask: StaffAction,
): Intent {
  if (isBlank(ask.by)) {
    return {
      ok: false,
      status: 400,
      error: 'Sign in before deciding on a report.',
    };
  }

  if (ask.action === 'contact') {
    // Contacts do not dismiss. Answering somebody and closing their complaint are
    // two different acts, and conflating them hides the fact that it was answered
    // but not resolved. `contacted_at` is written by the caller alongside this.
    return { ok: true, write: { dismissed_at: null, dismissed_by: null, dismiss_note: '' } };
  }

  if (ask.action === 'dismiss') {
    if (!isOpen(row)) {
      return {
        ok: false,
        status: 409,
        error: 'Already handled by ' +
          (row.dismissedBy || 'somebody') +
          '. Reopen it first if that was wrong.',
      };
    }
    return {
      ok: true,
      write: {
        dismissed_at: ask.now.toISOString(),
        dismissed_by: ask.by,
        dismiss_note: (ask.note ?? '').trim(),
      },
    };
  }

  // reopen
  if (isOpen(row)) {
    return {
      ok: false,
      status: 409,
      error: 'That report is already open.',
    };
  }
  // Clears the attribution as well as the timestamp. A reopened row that kept
  // the old "handled by" would say it was handled while it sat in the open queue.
  return {
    ok: true,
    write: { dismissed_at: null, dismissed_by: null, dismiss_note: '' },
  };
}

function isBlank(v: string | null | undefined): boolean {
  return v === null || v === undefined || String(v).trim() === '';
}
