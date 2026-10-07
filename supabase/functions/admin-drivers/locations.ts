// What the Locations tab shows, and the rules about keeping the data.
//
// ## The decision this module encodes
//
// Drivers are tracked because the product cannot work otherwise: matching a
// driver to a trip needs their position, so `driver_locations` has existed since
// the first migration and the driver app publishes to it whenever it is online.
//
// Riders are not. There is no `rider_locations` history and there is not going to
// be one. A rider's position is recorded while they have a trip in progress --
// which is exactly when their driver needs to find them -- and the row is deleted
// when that trip ends. Outside a trip the app sends nothing.
//
// That is not a technical limit, it is the point. "Where is everyone right now"
// is a different product from "where is the rider I am collecting", and only the
// second one is a ride-hailing app.
//
// ## Why a place name and never a coordinate
//
// The same rule as the reports page, and the same reason: a build once wrote
// "5.5879, -0.2204" into a place field and those rows are permanent. A support
// screen is the last place that should answer "where is this person" with a
// latitude. So a row with no place name says it has none; it never falls back to
// printing the point.

/** How long location data is kept before the purge removes it. */
export const RETENTION_DAYS = 14;

/** The longest anybody may ask for the data to be kept beyond that. */
export const MAX_KEEP_DAYS = 30;

export type Who = 'driver' | 'rider';

export interface LocationRow {
  profileId: string;
  who: Who;
  name: string;
  phone: string;
  /** 'PGPOINT', or null when the row could not be read. */
  point: string | null;
  updatedAt: string;
  /** The cached reverse-geocoded place name, or null if never resolved. */
  placeLabel: string | null;
  /** When that label was resolved, so it can be refreshed as the driver moves. */
  placeLabelAt: string | null;
  /** Present for riders: the trip the position belongs to. */
  tripId: string | null;
  tripState: string | null;
}

export interface ShownLocation {
  profileId: string;
  who: Who;
  name: string;
  phone: string;
  hasPhone: boolean;
  /** Never a coordinate. 'place name unavailable' when there is not one. */
  where: string;
  /** Whether `where` came from the cache or is still missing. */
  needsLabel: boolean;
  ago: string;
  tripState: string | null;
}

export interface RecordingState {
  keep: boolean;
  until: string | null;
  by: string | null;
  /** Whole days left, or null when not keeping. */
  daysLeft: number | null;
}

/** A `latitude,longitude` pair, which is never a place name. */
export function looksLikeCoordinates(value: string | null | undefined): boolean {
  if (value === null || value === undefined) return false;
  return /^\s*-?\d+(?:\.\d+)?\s*,\s*-?\d+(?:\.\d+)?\s*$/.test(value);
}

/**
 * The text for the "where" line.
 *
 * Falls back to a sentence saying the name is missing. It does not fall back to
 * the point, and that is the whole reason this function exists.
 */
export function whereText(label: string | null | undefined): string {
  const trimmed = (label ?? '').trim();
  if (trimmed === '' || looksLikeCoordinates(trimmed)) return 'place name unavailable';
  return trimmed;
}

/** "just now", "12 min ago", "3 days ago". Whole units, never negative. */
export function agoText(iso: string | null | undefined, now: Date): string {
  if (iso === null || iso === undefined) return 'unknown';
  const then = new Date(iso).getTime();
  if (!Number.isFinite(then)) return 'unknown';
  const mins = Math.max(0, Math.round((now.getTime() - then) / 60000));
  if (mins < 1) return 'just now';
  if (mins < 60) return mins + ' min ago';
  const hrs = Math.round(mins / 60);
  if (hrs < 24) return hrs + (hrs === 1 ? ' hr ago' : ' hrs ago');
  const days = Math.round(hrs / 24);
  return days + (days === 1 ? ' day ago' : ' days ago');
}

export function shapeLocation(row: LocationRow, now: Date): ShownLocation {
  return {
    profileId: row.profileId,
    who: row.who,
    name: (row.name ?? '').trim() === '' ? '(no name)' : row.name,
    phone: row.phone ?? '',
    hasPhone: (row.phone ?? '').trim() !== '',
    where: whereText(row.placeLabel),
    // Only a row with no usable label is worth spending a geocoder call on.
    needsLabel: whereText(row.placeLabel) === 'place name unavailable',
    ago: agoText(row.updatedAt, now),
    tripState: row.tripState ?? null,
  };
}

/**
 * Newest first, and riders before drivers within an age.
 *
 * Riders first because a rider on a trip is waiting for a driver, and a driver
 * who is not on a trip is simply available. That is the order in which the two
 * facts matter to somebody reading this screen.
 */
export function orderLocations(rows: ShownLocation[]): ShownLocation[] {
  return rows.slice().sort(function (a, b) {
    if (a.who !== b.who) return a.who === 'rider' ? -1 : 1;
    // Ascending age, because a smaller age is the newer position. Descending --
    // which is what this said first -- puts the stalest row of each kind at the
    // top, which is the one fact this screen exists not to lead with.
    return minutesAgo(a) - minutesAgo(b);
  });
}

// The sort above needs the age as a number, and ShownLocation deliberately keeps
// only the rendered string. Recovering it by parsing that string would be daft,
// so the age is recomputed from what is available: "N unit(s) ago".
function minutesAgo(row: ShownLocation): number {
  const m = /^(\d+)\s+(min|hr|day)s?\s+ago$/.exec(row.ago);
  if (!m) return 0;
  const n = Number(m[1]);
  return m[2] === 'min' ? n : m[2] === 'hr' ? n * 60 : n * 1440;
}

export function shapeRecording(
  keep: boolean,
  until: string | null,
  by: string | null,
  now: Date,
): RecordingState {
  if (!keep || until === null) return { keep: false, until: null, by: null, daysLeft: null };
  const end = new Date(until).getTime();
  if (!Number.isFinite(end)) {
    // An unreadable date must not read as "keeping forever". It reads as off,
    // which is the safe direction: the purge resumes.
    return { keep: false, until: null, by: null, daysLeft: null };
  }
  return {
    keep: true,
    until,
    by,
    daysLeft: Math.max(0, Math.ceil((end - now.getTime()) / 86400000)),
  };
}

export interface KeepRequest {
  by: string;
  days: number;
  now: Date;
}

export type KeepIntent =
  | { ok: true; write: { keep_recording: boolean; keep_until: string | null; updated_by: string | null } }
  | { ok: false; status: number; error: string };

/**
 * Whether the request to keep location data beyond its retention is allowed.
 *
 * Requires a name, caps the duration, and refuses a zero or negative ask -- all
 * three because this control exists to keep data longer than we said we would,
 * and every one of those is a way to end up keeping it forever by accident.
 */
export function keepIntent(req: KeepRequest): KeepIntent {
  if ((req.by ?? '').trim() === '') {
    return { ok: false, status: 400, error: 'Sign in before changing what is kept.' };
  }
  if (!Number.isFinite(req.days) || req.days <= 0) {
    return { ok: false, status: 400, error: 'Choose how long to keep it for.' };
  }
  const days = Math.min(Math.round(req.days), MAX_KEEP_DAYS);
  return {
    ok: true,
    write: {
      keep_recording: true,
      keep_until: new Date(req.now.getTime() + days * 86400000).toISOString(),
      updated_by: req.by.trim(),
    },
  };
}

/**
 * Stopping is always allowed, and records who stopped it.
 *
 * Separate from [keepIntent] because it takes no duration and refuses nothing:
 * there is no argument for refusing to stop keeping data, and a control that can
 * be talked out of turning it off is not a control.
 */
export function stopIntent(by: string): {
  ok: true;
  write: { keep_recording: boolean; keep_until: string | null; updated_by: string | null };
} {
  return {
    ok: true,
    write: { keep_recording: false, keep_until: null, updated_by: (by ?? '').trim() || null },
  };
}
