// The admin KYC page, and the function that serves it.
//
// One function rather than a function and a website, because the service role
// key can never reach a browser. Anything that flips `kyc_status` to `approved`
// is, by definition, running with RLS switched off, so it has to live behind a
// server that holds the key. Serving the page from the same function keeps the
// privileged code in one file and means there is nothing to deploy, host or
// keep alive alongside it.
//
// The page is a string rather than a file for two reasons: there is no build
// step, and there is no second artefact that can drift out of step with the
// function it talks to.
//
// auth.admin.ts and the page are the two halves of the admin surface and the
// security of both is stated where it is implemented -- see
// `requireAdmin` in `handler.ts` and the note on the page's sign-in below.
import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';
import { corsHeaders } from '../_shared/cors.ts';
import { first, ok } from '../_shared/rows.ts';
import {
  handleDecide,
  handleList,
  requireAdmin,
  ageFromGhanaCardDate,
  ALL_DOCUMENTS,
  REQUIRED_DOCUMENTS,
  submittedAtFor,
  type AdminDeps,
  type DriverDocumentRow,
  type PendingDriver,
} from './handler.ts';
import {
  decide,
  shapeReport,
  triageOrder,
  type ReportRow,
  type TriageReport,
} from './reports.ts';
import {
  keepIntent,
  looksLikeCoordinates,
  orderLocations,
  shapeLocation,
  shapeRecording,
  stopIntent,
  type LocationRow,
  type RecordingState,
  type ShownLocation,
  type Who,
} from './locations.ts';
import { adminPage } from './page.ts';
import { staffPage } from './staff_page.ts';
import {
  findSession,
  signIn,
  signOut,
  validateDecision,
  type SessionGrant,
  type StaffDeps,
  type StaffIdentity,
  type StaffRow,
  type StaffSignInFailure,
} from './staff.ts';

/// The staff store, over a Supabase client.
///
/// A deliberately narrow description of the six queries this file makes against
/// the three staff tables, rather than a cast at every call site. It reads like
/// ceremony and saves a lot of it: without it every method below is an
/// `as never as {...}` and a reader of any one query has to work out whether
/// that particular cast is safe.
///
/// `postgrest` is not imported. The Deno test job does not resolve the module
/// graph this function is deployed with, and [staff.ts] is where the rules live
/// precisely so they can be tested without any of this.
interface StaffStore {
  from(table: string): {
    select(columns: string): {
      eq(column: string, value: unknown): {
        gt(column: string, value: string): {
          maybeSingle(): Promise<{ data: unknown }>;
        };
        maybeSingle(): Promise<{ data: unknown }>;
      };
    };
    insert(values: Record<string, unknown>): Promise<unknown>;
    delete(): {
      eq(column: string, value: unknown): Promise<unknown>;
    };
  };
  rpc(
    name: string,
    args: Record<string, unknown>,
  ): Promise<{ data: unknown; error: unknown }>;
}

/// One service client for the whole function.
///
/// Built once at module scope. The alternative -- a client per request, which is
/// what this file did first -- means a fresh TLS handshake to Supabase for every
/// PIN tap, on a connection that is the thing most likely to be slow.
let cachedService: StaffStore & { auth: unknown } | null = null;

function serviceClient(): StaffStore & { auth: unknown } {
  if (cachedService !== null) return cachedService;
  const client = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
  );
  cachedService = client as unknown as StaffStore & { auth: unknown };
  return cachedService;
}

/// The staff store over the service role.
///
/// Service-role-only because RLS is enabled on all three staff tables with no
/// policies at all. A driver authenticated as themselves cannot read a staff
/// name, a PIN hash or the decision log, and the anon key that ships in both
/// apps gets nothing.
function buildStaffDeps(service: StaffStore): StaffDeps {
  const row = (data: unknown): Record<string, unknown> | null =>
    data === null || data === undefined
      ? null
      : data as Record<string, unknown>;

  return {
    findByName: async (name) => {
      const { data } = await service
        .from('staff')
        .select('id, name, pin_hash, active, failed_attempts, locked_until')
        .eq('name', name)
        .maybeSingle();
      const r = row(data);
      if (r === null) return null;
      return {
        id: String(r['id']),
        name: String(r['name']),
        pinHash: String(r['pin_hash']),
        active: r['active'] === true,
        failedAttempts: Number(r['failed_attempts'] ?? 0),
        lockedUntil: r['locked_until'] == null
          ? null
          : new Date(String(r['locked_until'])),
      } as StaffRow;
    },

    // The comparison happens in Postgres. This function has no bcrypt and is not
    // going to grow one: reading the hash out to compare it here would put it in
    // this function's memory and in any error message, for no gain over a round
    // trip either way.
    pinMatches: async (staffId, pin) => {
      const { data, error } = await service.rpc('staff_pin_matches', {
        p_staff_id: staffId,
        p_pin: pin,
      });
      return error === null && data === true;
    },

    markUsed: async (staffId) => {
      await service.rpc('staff_pin_used', { p_staff_id: staffId });
    },

    markFailed: async (staffId) => {
      // Both the counter and the lock are advanced by a Postgres function, so
      // the rule lives in one place and a caller cannot unlock itself by calling
      // markUsed more often than markFailed.
      await service.rpc('staff_pin_failed', { p_staff_id: staffId });
    },

    createSession: async (grant) => {
      await service.from('staff_sessions').insert({
        token_hash: grant.tokenHash,
        staff_id: grant.staffId,
        expires_at: grant.expiresAt.toISOString(),
      });
    },

    findSession: async (tokenHash) => {
      const { data } = await service
        .from('staff_sessions')
        .select('staff_id, staff(id, name)')
        .eq('token_hash', tokenHash)
        .gt('expires_at', new Date().toISOString())
        .maybeSingle();
      const r = row(data);
      if (r === null) return null;
      const person = r['staff'] as Record<string, unknown> | null;
      if (person === null) return null;
      return { id: String(r['staff_id']), name: String(person['name']) };
    },

    deleteSession: async (tokenHash) => {
      await service.from('staff_sessions').delete().eq('token_hash', tokenHash);
    },
  };
}

/// Resolves a request token to a signed-in staff member, or null.
///
/// Null for every failure -- unknown, expired, revoked -- because the caller
/// answers all of them identically and a different answer would leak which
/// tokens ever existed.
async function staffFor(token: string): Promise<StaffIdentity | null> {
  return findSession(buildStaffDeps(serviceClient()), await sha256Hex(token));
}

// There used to be an `allowed()` here -- "a founder, or a signed-in staff
// member" -- and it was the only authorisation on the `document` and
// `listreports` actions. It returned true for a request carrying no credentials
// whatsoever, which was found by probing the deployed function rather than by
// reading it, and it is gone. `requireAdmin` in handler.ts is the single gate
// now, and `roleOfCaller` went with it: it read `profiles.role` through the
// service client while `requireAdmin` reads it through `deps`, so keeping both
// would have left two ways to answer the same question.

/// Writes one row into `kyc_decisions`.
///
/// Best-effort by design: a failure to log must not undo or block a decision
/// that has already been made, because leaving a driver un-approved is worse
/// than a gap in the log. The gap is reported in the log line so it is visible.
async function recordDecision(input: {
  driverId: string;
  decision: 'approved' | 'rejected';
  staff: StaffIdentity | null;
  reason: string | null;
}): Promise<void> {
  try {
    await (serviceClient() as unknown as {
      from(t: string): {
        insert(v: Record<string, unknown>): Promise<unknown>;
      };
    })
      .from('kyc_decisions')
      .insert({
        driver_id: input.driverId,
        decision: input.decision,
        staff_id: input.staff?.id ?? null,
        // Kept beside the id so the log still reads after the staff row is
        // deleted. `on delete set null` on the id would otherwise erase the
        // fact that somebody approved thirty drivers.
        staff_name: input.staff?.name ?? null,
        reason: input.reason,
      });
  } catch (e) {
    console.error('admin-drivers: a decision was made but not logged', e);
  }
}

/// This staff member's own decisions, newest first.
async function myDecisions(staffId: string): Promise<Record<string, unknown>[]> {
  const { data } = await (serviceClient() as unknown as {
    from(t: string): {
      select(c: string): {
        order(c: string, o: { ascending: boolean }): {
          limit(n: number): Promise<{ data: unknown }>;
        };
      };
    };
  })
    .from('kyc_decisions')
    .select('id, driver_id, decision, reason, created_at, profiles(full_name)')
    .order('created_at', { ascending: false })
    .limit(50);
  const rows = (data ?? []) as Record<string, unknown>[];
  return rows.map((r) => ({
    id: String(r['id']),
    driverId: String(r['driver_id']),
    decision: String(r['decision']),
    reason: r['reason'] == null ? null : String(r['reason']),
    at: String(r['created_at']),
    driverName:
      (r['profiles'] as Record<string, unknown> | null)?.['full_name'] ?? null,
  }));
}

/**
 * One report, joined to the rider who left it and the ride it is about.
 *
 * `!inner` on `trips` because a report without a trip cannot be understood by a
 * person doing triage, and an empty page reads as "nothing has been reported"
 * rather than "one row could not be joined". The two `profiles` joins have to be
 * aliased because PostgREST cannot tell which foreign key to follow when a row is
 * reachable by two paths to the same table.
 */
const REPORT_SELECT =
  'id, trip_id, reason, detail, created_at, dismissed_at, dismissed_by, dismiss_note, contacted_at, contacted_by, ' +
  'profiles!trip_reports_reported_by_fkey(full_name, phone), ' +
  'trips!inner(id, state, fare_ghs, category, driver_id, pickup, dropoff, ' +
  'profiles!trips_driver_id_fkey(full_name, phone))';

/** Structural view of the one query builder chain these three functions use. */
function reportQuery() {
  return (serviceClient() as unknown as {
    from(t: string): {
      select(c: string): {
        order(c: string, o: { ascending: boolean }): {
          limit(n: number): Promise<{ data: unknown }>;
        };
        eq(c: string, v: unknown): Promise<{ data: unknown }>;
      };
    };
  }).from('trip_reports');
}

/** A nested join can come back as null or as an array; both are handled. */
function joined(r: Record<string, unknown>, key: string): Record<string, unknown> | null {
  const v = r[key];
  if (typeof v === 'object' && v !== null && !Array.isArray(v)) {
    return v as Record<string, unknown>;
  }
  if (Array.isArray(v) && v.length > 0 && typeof v[0] === 'object' && v[0] !== null) {
    return v[0] as Record<string, unknown>;
  }
  return null;
}

function text(v: unknown): string | null {
  return v == null ? null : String(v);
}

/** Maps one joined row onto [ReportRow]. Pure enough to test with a literal. */
function toReportRow(r: Record<string, unknown>): ReportRow {
  const rider = joined(r, 'profiles');
  const trip = joined(r, 'trips');
  const driver = trip === null ? null : joined(trip, 'profiles');
  const fare = trip === null ? null : trip['fare_ghs'];

  return {
    id: String(r['id']),
    tripId: String(r['trip_id']),
    reason: text(r['reason']),
    detail: text(r['detail']),
    createdAt: String(r['created_at']),
    dismissedAt: text(r['dismissed_at']),
    dismissedBy: text(r['dismissed_by']),
    dismissNote: text(r['dismiss_note']),
    contactedAt: text(r['contacted_at']),
    contactedBy: text(r['contacted_by']),
    riderName: rider === null ? null : text(rider['full_name']),
    riderPhone: rider === null ? null : text(rider['phone']),
    tripState: trip === null ? null : text(trip['state']),
    // numeric comes back as a string from PostgREST. Number() is right here and
    // is why `fareGhs` is a number and not the text Postgres sends.
    tripFareGhs: fare == null ? null : (isNaN(Number(fare)) ? null : Number(fare)),
    tripCategory: trip === null ? null : text(trip['category']),
    // The jsonb columns are read whole; see `stopText` for why.
    pickupJson: trip === null ? null : trip['pickup'],
    dropoffJson: trip === null ? null : trip['dropoff'],
    driverId: trip === null ? null : text(trip['driver_id']),
    driverName: driver === null ? null : text(driver['full_name']),
    driverPhone: driver === null ? null : text(driver['phone']),
  };
}

/**
 * Every report, in triage order.
 *
 * Capped at 200. This is a support queue on a phone, not an export: past that
 * the oldest waiting complaint is one nobody is going to reach, and the honest
 * answer is a tighter retention window rather than a longer scroll.
 */
async function listReports(): Promise<TriageReport[]> {
  const { data } = await reportQuery()
    .select(REPORT_SELECT)
    .order('created_at', { ascending: false })
    .limit(200);
  const rows = Array.isArray(data) ? (data as Record<string, unknown>[]) : [];
  return triageOrder(rows.map((r) => shapeReport(toReportRow(r))));
}

async function readReport(id: string): Promise<ReportRow | null> {
  const { data } = await reportQuery().select(REPORT_SELECT).eq('id', id);
  if (!Array.isArray(data) || data.length === 0) return null;
  return toReportRow(data[0] as Record<string, unknown>);
}

/**
 * Records a decision, or the fact that the rider was contacted.
 *
 * `contacted_at` is written on contact *in addition to* whatever `decide()`
 * returned, and the contact write is deliberately not a dismissal. Answering a
 * rider and closing their complaint are separate acts; the page offers both
 * buttons side by side rather than one button that does both, so the log can say
 * which actually happened.
 */
async function writeReport(
  id: string,
  ask: 'dismiss' | 'reopen' | 'contact',
  write: { dismissed_at: string | null; dismissed_by: string | null; dismiss_note: string },
  by: string,
): Promise<{ ok: true } | { ok: false; status: number; error: string }> {
  const patch: Record<string, unknown> = {
    dismissed_at: write.dismissed_at,
    dismissed_by: write.dismissed_by,
    dismiss_note: write.dismiss_note,
  };
  if (ask === 'contact') {
    patch['contacted_at'] = new Date().toISOString();
    patch['contacted_by'] = by;
  }

  const { error } = await (serviceClient() as unknown as {
    from(t: string): {
      update(v: Record<string, unknown>): {
        eq(c: string, v: unknown): { select(c: string): Promise<{ error: { message: string } | null }> };
      };
    };
  })
    .from('trip_reports')
    .update(patch)
    .eq('id', id)
    .select('id');

  if (error !== null) {
    // The database's own message. An employee pressing Dismiss and being told
    // "something went wrong" has no way to know whether it worked.
    return { ok: false, status: 502, error: error.message || 'the report could not be saved' };
  }
  return { ok: true };
}

// ------------------------------------------------------------- locations

/** Whether location data is being kept past its retention, and by whom. */
async function readRecordingState(now: Date): Promise<RecordingState> {
  const { data: setting } = await (serviceClient() as unknown as {
    from(t: string): {
      select(c: string): {
        eq(c: string, v: unknown): { maybeSingle(): Promise<{ data: unknown }> };
      };
    };
  })
    .from('location_settings')
    .select('keep_recording, keep_until, updated_by')
    .eq('id', true)
    .maybeSingle();

  const row = (setting ?? null) as Record<string, unknown> | null;
  return shapeRecording(
    row !== null && row['keep_recording'] === true,
    row === null || row['keep_until'] == null ? null : String(row['keep_until']),
    row === null || row['updated_by'] == null ? null : String(row['updated_by']),
    now,
  );
}

/**
 * Where people are, and how long we are keeping it.
 *
 * Drivers are last-known because the driver app has always published there --
 * matching a driver to a trip needs their position. Riders appear only while they
 * have a live trip, which is the only reason their position is recorded at all.
 *
 * The point is never returned to the page. Not obfuscated, not rounded: absent.
 * The page shows a reverse-geocoded place name, and a row with no name says it
 * has none rather than falling back to a latitude.
 */
async function listLocations(): Promise<{
  drivers: ShownLocation[];
  riders: ShownLocation[];
  recording: RecordingState;
}> {
  const now = new Date();

  const { data: driverRows } = await locationQuery('driver_locations')
    .select(
      'driver_id, updated_at, place_label, place_label_at, profiles(full_name, phone)',
    )
    .order('updated_at', { ascending: false })
    .limit(200);

  // Inner-joined in SQL rather than filtered afterwards, so a rider whose trip
  // ended a second ago is not on the page at all. `rider_locations` is also
  // purged of dead trips nightly; this is the belt to that pair of braces.
  const { data: riderRows } = await locationQuery('rider_locations')
    .select(
      'rider_id, trip_id, updated_at, place_label, place_label_at, profiles(full_name, phone), trips!inner(state)',
    )
    .eq('trips.state', 'ongoing')
    .limit(200);

  const drivers = orderLocations(
    (Array.isArray(driverRows) ? (driverRows as Record<string, unknown>[]) : []).map(
      (r) => shapeLocation(toLocationRow(r, 'driver'), now),
    ),
  );
  const riders = orderLocations(
    (Array.isArray(riderRows) ? (riderRows as Record<string, unknown>[]) : []).map(
      (r) => shapeLocation(toLocationRow(r, 'rider'), now),
    ),
  );

  const recording = await readRecordingState(now);

  return { drivers, riders, recording };
}

function locationQuery(table: string) {
  return (serviceClient() as unknown as {
    from(t: string): {
      select(c: string): {
        order(c: string, o: { ascending: boolean }): {
          limit(n: number): Promise<{ data: unknown }>;
        };
        eq(c: string, v: unknown): {
          limit(n: number): Promise<{ data: unknown }>;
        };
      };
    };
  }).from(table);
}

function toLocationRow(r: Record<string, unknown>, who: Who): LocationRow {
  const p = joined(r, 'profiles');
  const t = joined(r, 'trips');
  return {
    profileId: String(who === 'driver' ? r['driver_id'] : r['rider_id']),
    who,
    name: p === null ? '' : String(p['full_name'] ?? ''),
    phone: p === null ? '' : String(p['phone'] ?? ''),
    // Read so the row is not silently useless, and deliberately not returned.
    point: r['point'] == null ? null : 'set',
    updatedAt: String(r['updated_at']),
    placeLabel: r['place_label'] == null ? null : String(r['place_label']),
    placeLabelAt: r['place_label_at'] == null ? null : String(r['place_label_at']),
    tripId: r['trip_id'] == null ? null : String(r['trip_id']),
    tripState: t === null ? null : String(t['state'] ?? ''),
  };
}

/**
 * Reverse-geocodes one position and stores the result as a place name.
 *
 * Server-side on purpose. To geocode in the browser the page would need the
 * latitude and longitude, which puts a real person's position into a JSON payload
 * on a page served from shared hosting. Here the point comes out of the database
 * through `location_point`, is turned into a street name, and only the street name
 * is ever returned or stored. The coordinate is read once and discarded.
 *
 * ## Why Photon and not Nominatim
 *
 * Nominatim is what both apps use, and it was tried here first. It refuses to
 * serve cloud egress, so the function -- which runs on one -- got a refusal for
 * every request: verified by calling Nominatim directly (200, correct answer) and
 * then through the deployed function (502, "the place name service refused"). The
 * apps are on a phone and are fine; an edge function is not.
 *
 * Photon is OSM-based, needs no key, and answers server-side. It returns
 * structured fields rather than one long sentence, which suits a phone row: the
 * label is assembled from street, district and city and stops at three parts.
 * Nominatim's `display_name` runs to a paragraph that pushes everything else off
 * the screen.
 *
 * Nominatim's one-request-a-second limit is kept for Photon anyway, which asks
 * for the same.
 */
let lastGeocodeAt = 0;

/** "Otublohum Street, North Industrial Area, Okaikoi South..." -> the first three. */
function labelFromPhoton(props: Record<string, unknown>): string {
  const parts: string[] = [];
  for (const key of ['street', 'name', 'district', 'city', 'county', 'country']) {
    const v = props[key];
    if (typeof v !== 'string') continue;
    const t = v.trim();
    if (t === '') continue;
    // A street name and a `name` are often the same string in Photon; a list with
    // the same place in it twice reads as though two different things were named.
    if (parts.some((p) => p.toLowerCase() === t.toLowerCase())) continue;
    parts.push(t);
    if (parts.length === 3) break;
  }
  return parts.join(', ');
}

async function resolvePlaceLabel(
  who: Who,
  profileId: string,
): Promise<{ ok: true; label: string } | { ok: false; status: number; error: string }> {
  const { data, error } = await (serviceClient() as unknown as {
    rpc(fn: string, args: Record<string, unknown>): Promise<{ data: unknown; error: unknown }>;
  }).rpc('location_point', { who, profile_id: profileId });

  if (error !== null && error !== undefined) {
    return { ok: false, status: 502, error: 'that position could not be read' };
  }
  const point = data === null || data === undefined ? '' : String(data);
  if (point === '') {
    return { ok: false, status: 404, error: 'no position is stored for that person' };
  }
  const [lat, lon] = point.split(',');
  if (lat === undefined || lon === undefined || lat === '' || lon === '') {
    return { ok: false, status: 502, error: 'that position could not be read' };
  }

  const wait = 1100 - (Date.now() - lastGeocodeAt);
  if (wait > 0) await new Promise((r) => setTimeout(r, wait));
  lastGeocodeAt = Date.now();

  let label = '';
  try {
    const res = await fetch(
      'https://photon.komoot.io/reverse?lat=' + encodeURIComponent(lat) +
        '&lon=' + encodeURIComponent(lon),
    );
    if (!res.ok) return { ok: false, status: 502, error: 'the place name service refused' };
    const body = (await res.json()) as { features?: { properties?: Record<string, unknown> }[] };
    const first = (body.features ?? [])[0];
    label = first?.properties ? labelFromPhoton(first.properties) : '';
  } catch {
    // A geocoder that is down is not a reason to show a coordinate, and not a
    // reason to fail the page. The row keeps its position and tries again later.
    return { ok: false, status: 502, error: 'the place name service could not be reached' };
  }

  // Photon answers 200 with no features for a point in the sea, which is what a
  // position with latitude and longitude the wrong way round looks like. There is
  // no place name for it, so there is nothing to store and nothing to show.
  if (label === '' || looksLikeCoordinates(label)) {
    return { ok: false, status: 404, error: 'no place name was found for that position' };
  }

  const column = who === 'driver' ? 'driver_id' : 'rider_id';
  const { error: writeError } = await (serviceClient() as unknown as {
    from(t: string): {
      update(v: Record<string, unknown>): {
        eq(c: string, v: unknown): {
          select(c: string): Promise<{ error: { message: string } | null }>;
        };
      };
    };
  })
    .from(who === 'driver' ? 'driver_locations' : 'rider_locations')
    .update({ place_label: label, place_label_at: new Date().toISOString() })
    .eq(column, profileId)
    .select('place_label');

  if (writeError !== null) {
    return { ok: false, status: 502, error: writeError.message || 'the place name could not be saved' };
  }
  return { ok: true, label };
}

const json = (status: number, payload: Record<string, unknown>) =>
  new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

/// A random session token, hex.
///
/// 32 bytes from `crypto.getRandomValues`, which is the platform CSPRNG rather
/// than `Math.random`. A guessable session token would make the four-digit PIN
/// the only thing standing between a stranger and the approval button, and
/// "unguessable" has to mean unguessable.
function randomToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

/// sha256 of a token, hex. What is stored in `staff_sessions`.
///
/// The browser holds the raw token and the table holds this, so a table that is
/// ever read by something it should not be does not hand over a set of live
/// sessions.
async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(value),
  );
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0'))
    .join('');
}

/// What the page shows for a refused sign-in.
///
/// The wording is a judgement and this records it, because the obvious version
/// of this function says the same thing for every failure and the first version
/// of this comment claimed that.
///
/// "That name and PIN did not match" and "That PIN is not right" are different
/// sentences, so somebody can tell a wrong name from a wrong PIN. That does
/// technically reveal whether a name is on the staff list, and it is
/// deliberately not treated as a problem here:
///   * The people who sign in are a handful of colleagues who know each other's
///     names, so the list is not a secret from the people who use it.
///   * The person probing has already got as far as typing a name and a PIN,
///     which is most of the work of getting in.
///   * And telling somebody their colleague's name is not recognised is more use
///     than a uniform "no", because the commonest reason somebody is locked out
///     is that they typed a colleague's name slightly wrong.
///
/// A uniform message would be the right call for anything facing the public. This
/// is not that, and the difference is a decision rather than an oversight.
function signInSentence(failure: StaffSignInFailure | undefined): string {
  switch (failure) {
    case 'noPin':
      // A correction rather than a refusal, because four digits is a shape and
      // anything else is a typo.
      return 'A PIN is four numbers.';
    case 'noSuchPerson':
    case 'deactivated':
      // The same sentence for both. Telling a former employee their account is
      // switched off is more use than "wrong name", and saying "ask your
      // supervisor" is the instruction that actually moves them forward.
      return 'That name and PIN did not match. Check with your supervisor.';
    case 'locked':
      return 'Too many tries. Wait 15 minutes.';
    default:
      return 'That PIN is not right.';
  }
}

export function buildAdminDeps(
  supabaseUrl: string,
  serviceKey: string,
): AdminDeps {
  const service = createClient(supabaseUrl, serviceKey);
  // The bridge cast is at the boundary and nowhere else. supabase-js types its
  // query builder against a schema generic this function deliberately does not
  // declare, so the concrete client is not structurally assignable to
  // [ServiceClient] even though every call made through it is one [ServiceClient]
  // describes. Cast once, here, so the mismatch does not become a cast on every
  // call site -- and so a reader of any single query is not trying to work out
  // whether that particular one is safe.
  const typed = service as unknown as ServiceClient;

  return {
    // supabase-js only sets `Authorization` when the request carries none
    // (`fetch.js`: `if (!headers.has('Authorization'))`), so a service key paired
    // with a forwarded bearer leaves the bearer as the effective credential
    // rather than the key. One client, nothing forwarded onto it, and the
    // caller's token is the explicit argument to `getUser`.
    authenticate: async (token) => {
      const { data, error } = await service.auth.getUser(token);
      if (ok(error) !== null) return null;
      return data.user?.id ?? null;
    },

    roleOf: async (userId) => {
      const { data, error } = await service
        .from('profiles')
        .select('role')
        .eq('id', userId)
        .limit(1);
      if (ok(error) !== null) return null;
      return (first(data) as { role?: string } | null)?.role ?? null;
    },

    listPending: async () => {
      // The driver's own email is not in `profiles` -- it is in `auth.users` --
      // so the two are joined by hand. An admin has to be able to tell two
      // drivers called "Kwame Mensah" apart, and a name is not enough.
      const { data, error } = await service
        .from('profiles')
        .select('id, full_name, phone, ghana_card_last4, ghana_card_expiry, ' +
          'ghana_card_number, ghana_card_dob, ghana_card_sex, ' +
          'ghana_card_nationality, ghana_card_issued, ' +
          'selfie_url, vehicle_id, created_at')
        .eq('role', 'driver')
        .eq('kyc_status', 'pending')
        .order('created_at', { ascending: false });
      if (ok(error) !== null) return [];

      const ids = (data ?? []) as unknown as Record<string, unknown>[];
      const emails = await emailsFor(typed, ids.map((r) => r['id'] as string));
      const vehicles = await vehiclesFor(
        typed,
        ids
          .map((r) => r['vehicle_id'])
          .filter((v): v is string => typeof v === 'string'),
      );
      // One read of every pending driver's documents rather than one per
      // driver. Six documents times a list of drivers is six round trips each
      // if done naively, and this page is opened on a phone as often as a
      // laptop.
      const pendingDocs = await documentsForAll(
        typed,
        ids.map((r) => r['id'] as string),
      );

      return ids.map((r): PendingDriver => {
        const id = r['id'] as string;
        const vehicleId = r['vehicle_id'];
        const vehicle = typeof vehicleId === 'string'
          ? vehicles.get(vehicleId) ?? null
          : null;
        return {
          id,
          email: emails.get(id) ?? '(no email on the account)',
          fullName: str(r['full_name']),
          phone: str(r['phone']),
          // `ghana_card_last4` is named for the last four digits and the app
          // writes the *first* four (`digits.substring(0, 4)` in
          // `supabase_driver_repository.dart`), so this is the leading four.
          // The column is reported as stored rather than quietly corrected: an
          // admin approving a driver should see what is actually in the row,
          // and the mismatch is worth seeing.
          cardLast4: str(r['ghana_card_last4']),
          cardExpiry: str(r['ghana_card_expiry']),
          // The full number when the driver sent one, and the leading four
          // digits when they submitted before the column existed. Flagged rather
          // than padded: four digits presented as a card number is something an
          // employee could check and find wrong, or worse, not check.
          cardNumber: str(r['ghana_card_number']) ||
            str(r['ghana_card_last4']) ||
            null,
          cardNumberIsPartial: str(r['ghana_card_number']) === '' &&
            str(r['ghana_card_last4']) !== '',
          cardDob: str(r['ghana_card_dob']),
          cardSex: str(r['ghana_card_sex']),
          cardNationality: str(r['ghana_card_nationality']),
          cardIssued: str(r['ghana_card_issued']),
          cardAge: ageFromGhanaCardDate(str(r['ghana_card_dob'])),
          selfieUrl: str(r['selfie_url']),
          vehicle: vehicle === null ? null : {
            make: vehicle.make,
            model: vehicle.model,
            plate: vehicle.plate,
            seats: vehicle.seats,
          },
          // Synchronous on purpose: the kinds come from the same read the
          // decision will be checked against, so the page cannot show a driver
          // six documents and then refuse the approval because one is missing.
          // Only the kinds, never URLs -- see `AdminDeps.documentsFor`.
          documents: (pendingDocs.get(id) ?? []).map((d) => d.kind),
          // When the application arrived, which is when its last required
          // document did. NOT `profiles.created_at`: that is when the account was
          // made, which can be days before anybody photographed anything, and an
          // employee reading "2 days ago" next to six photographs taken this
          // morning is being told the wrong thing about the evidence. See
          // `submittedAtFor`.
          submittedAt: submittedAtFor(
            str(r['created_at']),
            pendingDocs.get(id) ?? [],
          ),
        };
      })
        // Newest application first, by the value the page displays.
        //
        // The query above orders by `created_at`, which is still the account
        // date, so the list order and the number on each row disagreed: a
        // driver who signed up yesterday and submitted this morning sat below one
        // who signed up this morning and submitted yesterday. Sorting here rather
        // than in SQL costs nothing -- the rows are already in memory, and the
        // alternative is either a second query or an aggregation across a
        // one-to-many table that PostgREST would need a view for.
        .sort((a, b) => Date.parse(b.submittedAt) - Date.parse(a.submittedAt));
    },

    decide: async (driverId, status, decidedBy) => {      // `approved_by` and `approved_at` are added by the migration beside this
      // function. They are the difference between an approval and an anonymous
      // change of state: without them, "why is this driver online" has no answer
      // after the fact. The write is conditional on the row still being
      // `pending`, so two admins clicking at once cannot approve a driver one
      // of them has already rejected.
      const { data, error } = await service
        .from('profiles')
        .update({
          kyc_status: status,
          approved_by: decidedBy,
          approved_at: new Date().toISOString(),
          // A driver who restarts onboarding has not been approved by this
          // click, so the previous decision's author is cleared rather than
          // left pointing at whoever decided last time.
          ...(status === 'approved' ? {} : { availability: 'offline' }),
        })
        .eq('id', driverId)
        .eq('kyc_status', 'pending')
        .select('id, full_name, phone, ghana_card_last4, ghana_card_expiry')
        .limit(1);
      if (ok(error) !== null) return null;
      const row = first(data) as unknown as Record<string, unknown> | null;
      if (row === null) return null;
      return {
        id: str(row['id']),
        email: '',
        fullName: str(row['full_name']),
        phone: str(row['phone']),
        cardLast4: str(row['ghana_card_last4']),
        cardExpiry: str(row['ghana_card_expiry']),
        selfieUrl: '',
        vehicle: null,
        // Empty rather than the six, because this row is what the page is left
        // holding after a decision -- and the driver is no longer pending, so
        // "no documents" is the honest summary of a driver who is not on the
        // list any more. The names would be a claim about a driver who is gone.
        documents: [],
        submittedAt: '',
        // The card fields are empty here for the same reason `documents` is: this
        // row is what the page is left holding after a decision, and the driver
        // is no longer on the list. Only the card number and expiry are carried
        // at all, because they were on the row this query already selected for
        // the decision's own sake.
        cardNumber: null,
        cardNumberIsPartial: false,
        cardDob: '',
        cardSex: '',
        cardNationality: '',
        cardIssued: '',
        cardAge: null,
      };
    },

    approveVehicle: async (driverId) => {
      const { data, error } = await service
        .from('vehicles')
        .update({ approved: true })
        .eq('owner_id', driverId)
        .select('id')
        .limit(1);
      if (ok(error) !== null) return false;
      // A zero-row update is a 200 with an empty body, not an error, so the
      // caller would otherwise be told a driver with no vehicle was approved.
      return (data ?? []).length > 0;
    },

    documentsFor: (driverId) =>
      documentsForAll(typed, [driverId]).then((m) => m.get(driverId) ?? []),

    signDocument: async (driverId, kind) => {
      // The kind is checked against what this driver actually sent, and the
      // path comes from the row rather than from the request. Signing a path
      // the caller chose would mint a working, expiring, shareable URL for any
      // object in the bucket -- including another driver's documents.
      const docs = (await documentsForAll(typed, [driverId])).get(driverId) ?? [];
      const doc = docs.find((d) => d.kind === kind);
      if (doc === undefined) return null;
      const { data, error } = await service.storage
        .from(DOCUMENT_BUCKET)
        .createSignedUrl(doc.path, DOCUMENT_URL_TTL_SECONDS);
      if (ok(error) !== null) return null;
      const url = data?.signedUrl;
      return typeof url === 'string' && url !== '' ? url : null;
    },
  };
}


const str = (value: unknown): string => (typeof value === 'string' ? value : '');

/**
 * The service client, as this file needs it.
 *
 * Not `ReturnType<typeof createClient>`: that resolves to a schema-generic
 * `SupabaseClient<unknown, never, ...>`, which the `any`-parameterised client
 * `createClient(url, key)` actually returns is not assignable to -- a variance
 * complaint with no meaning here. And not a hand-rolled chain of exact shapes,
 * because a PostgREST builder is fluent in a way a fixed interface gets wrong:
 * `.in()` hangs off `.select()`, not off `.eq()`, and the terminal call
 * differs per query. So the builder is one recursive type, and the terminal
 * calls are the ones that are awaitable.
 */
type ServiceResult = PromiseLike<{
  data: unknown;
  error: { message: string } | null;
}>;

interface ServiceQuery {
  select: (columns: string) => ServiceQuery;
  update: (values: Record<string, unknown>) => ServiceQuery;
  eq: (column: string, value: unknown) => ServiceQuery;
  order: (column: string, opts: { ascending: boolean }) => ServiceResult;
  in: (column: string, values: readonly unknown[]) => ServiceResult;
  limit: (n: number) => ServiceResult;
}

interface ServiceClient {
  from: (table: string) => ServiceQuery;
  auth: {
    admin: {
      listUsers: (opts: {
        page: number;
        perPage: number;
      }) => PromiseLike<{
        data: { users: { id: string; email?: string }[] | null } | null;
        error: { message: string } | null;
      }>;
    };
  };
  storage: {
    from: (bucket: string) => {
      createSignedUrl: (
        path: string,
        expiresIn: number,
      ) => PromiseLike<{
        data: { signedUrl: string } | null;
        error: { message: string } | null;
      }>;
    };
  };
}

/**
 * The bucket driver documents live in.
 *
 * The same string as `kDocumentBucket` in
 * `apps/driver/lib/src/data/supabase_driver_repository.dart` and the bucket in
 * `20260929000002_driver_documents.sql`. A function that named a bucket that
 * did not exist would return a list of drivers with no documents and no error,
 * which reads as "this driver sent nothing" -- the same answer a driver who
 * sent nothing gets.
 */
const DOCUMENT_BUCKET = 'kyc-documents';

/**
 * How long a signed document URL lasts.
 *
 * Five minutes: long enough to open a licence and read it, short enough that a
 * URL pasted into a chat is dead before it is useful. These are somebody's
 * identity documents, so the window is deliberately not generous.
 */
const DOCUMENT_URL_TTL_SECONDS = 300;

async function emailsFor(
  service: ServiceClient,
  ids: string[],
): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  if (ids.length === 0) return out;
  // `listUsers` is paginated and supabase-js has no per-id filter, so this asks
  // for a generous page rather than assuming every driver fits. A pilot has far
  // fewer; the reason for the large page is that going past the default would
  // otherwise be a driver silently missing from the list rather than a slower
  // page.
  const { data, error } = await service.auth.admin.listUsers({
    page: 1,
    perPage: 1000,
  });
  if (ok(error) !== null) return out;
  const wanted = new Set(ids);
  for (const user of data?.users ?? []) {
    if (wanted.has(user.id) && user.email) out.set(user.id, user.email);
  }
  return out;
}

async function vehiclesFor(
  service: ServiceClient,
  vehicleIds: string[],
): Promise<Map<string, { make: string; model: string; plate: string; seats: number }>> {
  const out = new Map<string, { make: string; model: string; plate: string; seats: number }>();
  if (vehicleIds.length === 0) return out;
  const { data, error } = await service
    .from('vehicles')
    .select('id, make, model, plate, seats')
    .in('id', vehicleIds);
  if (ok(error) !== null) return out;
  const rows = (data ?? []) as Record<string, unknown>[];
  for (const r of rows) {
    out.set(str(r['id']), {
      make: str(r['make']),
      model: str(r['model']),
      plate: str(r['plate']),
      seats: typeof r['seats'] === 'number' ? r['seats'] : 0,
    });
  }
  return out;
}

/**
 * The documents these drivers have sent, keyed by driver id.
 *
 * One query for the whole list rather than one per driver: six documents times
 * a list of drivers is six round trips each if done naively, and this page gets
 * opened on a phone as often as on a laptop.
 *
 * A read that fails yields an empty map, which the page renders as "these
 * drivers sent no documents" -- the same answer a driver who really did send
 * none gets. That is the wrong way round for a security check, and it is why
 * `handleDecide` reads the documents for the one driver being approved on a
 * fresh query rather than trusting this: the list is for the admin's eyes, the
 * decision is made on its own read.
 *
 * `in` rather than `eq` is not a style choice. On a PostgREST builder `eq`
 * returns another builder, and this function's narrow `ServiceQuery` type only
 * makes `in`, `order` and `limit` awaitable -- so a `.eq()` with no terminal
 * would be a builder where this code expects rows.
 */
async function documentsForAll(
  service: ServiceClient,
  driverIds: string[],
): Promise<Map<string, DriverDocumentRow[]>> {
  const out = new Map<string, DriverDocumentRow[]>();
  if (driverIds.length === 0) return out;
  const { data, error } = await service
    .from('driver_documents')
    .select('driver_id, kind, path, created_at')
    .in('driver_id', driverIds);
  if (ok(error) !== null) return out;
  const rows = (data ?? []) as Record<string, unknown>[];
  for (const r of rows) {
    const id = str(r['driver_id']);
    const kind = str(r['kind']);
    const path = str(r['path']);
    // A row whose kind the list has never heard of is dropped rather than
    // reported, because passing it through would put an unknown name in an
    // admin's face. The list of kinds it *has* heard of is `ALL_DOCUMENTS`, which
    // includes the optional ones -- see the note at the filter below.
    // Filtered against ALL_DOCUMENTS, not REQUIRED_DOCUMENTS, and the difference
    // is the face check.
    //
    // This tested `REQUIRED_DOCUMENTS.includes(kind)`, which reads like the
    // comment above it -- "a kind the list has never heard of is a kind that was
    // never sent" -- but it does something else: it drops every *optional* kind
    // as well. `livenessFrame` is optional, so the row was discarded here, and
    // `handleList` builds its `documents` from this map, so the list never
    // reported that a face check existed.
    //
    // The approval page asks for exactly three photographs side by side to answer
    // "is this the same person": the profile picture, the face check, and the
    // licence. With the face check silently missing, that comparison has been
    // running on two photographs, and the empty tile reads as "this driver did
    // not do the face check" rather than as a fault. An employee is being asked
    // to make a judgement on identity from less evidence than the screen says
    // they have, with nothing to tell them so.
    //
    // Nothing downstream depended on the narrower filter. `missingDocuments`
    // still answers over REQUIRED_DOCUMENTS, so the approval gate is unchanged,
    // and `optionalMissing` is now correct rather than always listing the face
    // check as absent.
    if (id === '' || !ALL_DOCUMENTS.includes(kind) || path === '') continue;
    const list = out.get(id) ?? [];
    // `created_at` is what `submittedAtFor` dates the application by. Read here
    // rather than in a second query: this is already one read for every pending
    // driver's documents, and a per-driver query to find out when they submitted
    // would undo the reason this function exists at all.
    list.push({ kind, path, createdAt: str(r['created_at']) });
    out.set(id, list);
  }
  return out;
}

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const url = Deno.env.get('SUPABASE_URL') ?? '';
  // The anon key, used for exactly one thing: verifying a sign-in. It is not a
  // secret in the sense the service key is -- it ships inside both apps -- but
  // keeping it server-side means the admin page holds no credential at all.
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
  const deps = buildAdminDeps(
    url,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
  );
  // The staff store, over the same service role. Built once at module scope by
  // `serviceClient`, so this is a reference rather than a second TLS handshake
  // on every PIN tap.
  const staffStore = buildStaffDeps(serviceClient());

  // The page itself, and deliberately unauthenticated: it contains no data and
  // no credential, only a sign-in form. Everything it displays arrives from the
  // authenticated calls below, and a 401 renders as "sign in" rather than as
  // an empty page that looks like there are no drivers.
  if (req.method === 'GET' && !req.headers.get('Authorization')) {
    // The staff page is what a driver approver sees.
  //
  // `?view=dense` still serves the old table for the founder, which is worth
  // keeping for one reason: it is the faster view when there are forty
  // applications in the queue and you know the drivers. It is not what an
  // employee should be handed, which is why it is no longer the default.
  const dense = new URL(req.url).searchParams.get('view') === 'dense';
  const body = dense ? adminPage(url) : staffPage(url);

  // The Content-Type is set three ways on purpose, because it kept coming back
  // as `text/plain` and the browser showed the page as source.
  //
  // What is going on: the edge gateway in front of this function rewrites
  // Content-Type on the way out. It merges its own `Access-Control-Allow-Origin`
  // alongside the lowercase ones from `corsHeaders`, so it is rebuilding the
  // header set rather than passing it through -- and Deno's own default for a
  // string body is `text/plain;charset=UTF-8`, which is what comes out. Cloudflare
  // then sees a non-HTML response and adds `X-Content-Type-Options: nosniff` and
  // `Content-Security-Policy: default-src 'none'; sandbox` on top, and the
  // browser dutifully displays the markup instead of rendering it.
  //
  // The obvious lesson, which cost the original page everything: **verifying a
  // page with `curl` proves nothing about whether it renders.** Every check that
  // said this page worked was reading the body, and the body was always right.
  const headers = new Headers();
  for (const [k, v] of Object.entries(corsHeaders)) headers.set(k, v);
  // Lowercase only, deliberately.
  //
  // `Content-Type` with a capital C is what HTTP specifies as the conventional
  // spelling, it is what `cors.ts` uses for the two allow-headers it sets, and
  // it is what this function set for its whole life -- and the gateway replaced
  // it with `text/plain` every single time. Setting it in both cases at once
  // did not help either, which is the clue: two values under names that differ
  // only in case is a set the gateway cannot normalise, so it falls back to its
  // own default. One lowercase name is the only shape left to try.
  //
  // If this does not work the fix is not in this function at all: the page moves
  // to Supabase Storage, which serves a static file with a correct
  // Content-Type and takes the gateway out of the path entirely.
  headers.set('content-type', 'text/html; charset=utf-8');
  return new Response(body, { status: 200, headers });
}

  // A Deno Edge Function has no session to read, so the identity comes from
  // the request's own bearer and is passed to `getUser` explicitly: the
  // argumentless form resolves against a client-carried session this function
  // does not have, and every call would 401. The `Bearer ` scheme is required
  // rather than stripped leniently, because PostgREST resolves the role from
  // the scheme word -- a bare token authenticates nowhere.
  const match = /^Bearer\s+(\S+)\s*$/i.exec(req.headers.get('Authorization') ?? '');
  const rawToken = match === null ? null : match[1];

  // Two kinds of caller, and the difference is who presses Approve.
  //
  // A founder token is a Supabase user JWT checked against `profiles.role =
  // 'admin'`, and it can do everything including being the person who made a
  // decision. A staff token is a row in `staff_sessions`, checked by hash, and
  // it can do the reviewing and nothing else -- it cannot create staff, cannot
  // see the founder's path, and cannot reach anything that is not a pending
  // driver.
  //
  // The two are tried in that order so a staff token is never mistaken for a JWT
  // and refused as a malformed bearer. Neither one is accepted on the strength
  // of looking like the other: each is resolved through its own store.
  const callerId = rawToken === null ? null : await deps.authenticate(rawToken);
  const staff: StaffIdentity | null = callerId === null && rawToken !== null
    ? await staffFor(rawToken)
    : null;

  let body: unknown = {};
  if (req.method === 'POST') {
    try {
      body = await req.json();
    } catch {
      return json(400, { error: 'body must be JSON' });
    }
  }
  const record = (typeof body === 'object' && body !== null && !Array.isArray(body))
    ? body as Record<string, unknown>
    : {};

  // Sign-in, handled here rather than in the page, so the browser holds no
  // credential at all -- not even the anon key, which is the same one that
  // ships in both apps. Two of them, because there are two kinds of person.
  if (record['action'] === 'staffsignin') {
    // The one an employee uses: a name and a four-digit PIN, no account, no
    // email, no password. The PIN is checked in Postgres with `crypt` so the
    // hash never leaves the database, and what comes back is a random session
    // token rather than a JWT -- a row in `staff_sessions`, deletable in one
    // statement when somebody leaves.
    const name = typeof record['name'] === 'string' ? record['name'] : '';
    const pin = typeof record['pin'] === 'string' ? record['pin'] : '';
    const token = randomToken();
    const result = await signIn(staffStore, {
      name,
      pin,
      now: new Date(),
      token,
      tokenHash: await sha256Hex(token),
    });
    if (!result.ok) return json(401, { error: signInSentence(result.failure) });
    return json(200, {
      token: result.token,
      name: result.name,
      expiresIn: result.expiresIn,
    });
  }

  if (record['action'] === 'staffsignout') {
    // Ends this session only. Deleting the staff row is the founder's move in
    // the SQL editor and is not reachable from here on purpose.
    if (rawToken !== null) {
      await signOut(staffStore, await sha256Hex(rawToken));
    }
    return json(200, { ok: true });
  }

  // Sign-in, handled here rather than in the page, so the browser holds no
  // credential at all -- not even the anon key, which is the same one that
  // ships in both apps. The password is verified by the auth server through the
  // anon client and only a short-lived user JWT comes back. Everything after
  // this is a decision about a driver, and every one of those re-checks
  // `role = 'admin'` server-side.
  if (record['action'] === 'signin') {
    const email = typeof record['email'] === 'string' ? record['email'] : '';
    const password = typeof record['password'] === 'string' ? record['password'] : '';
    if (email === '' || password === '') {
      return json(400, { error: 'email and password are required' });
    }
    const { data, error } = await createClient(url, anonKey).auth.signInWithPassword({
      email,
      password,
    });
    if (ok(error) !== null) {
      // The auth server's own message, deliberately not swallowed. "Invalid
      // login credentials" tells an admin their password is wrong; a generic
      // failure would have them retrying a password that was always right.
      return json(401, { error: error?.message ?? 'sign in failed' });
    }
    const accessToken = data.session?.access_token;
    if (typeof accessToken !== 'string' || accessToken === '') {
      return json(500, { error: 'no session was returned' });
    }
    return json(200, { token: accessToken });
  }

  if (req.method === 'POST' && record['action'] === 'document') {
    // Minted on demand, one at a time, and only for a kind this driver
    // actually sent. The alternative -- six signed URLs per driver inside the
    // list response -- would put a burst of expiring bearer credentials for
    // identity documents into a single JSON body, which is the kind of thing
    // that ends up in a log. Five minutes is long enough to read a licence.
    //
    // Both kinds of caller are allowed, which is the point: an employee has to
    // be able to open a licence to do the job.
    // `requireAdmin` and not the local `allowed()` this used to call. `allowed()`
    // returned true for a request with no credentials at all -- verified live,
    // not reasoned about -- so this endpoint was handing out signed URLs to
    // identity documents to anybody on the internet who asked. `handleList` uses
    // `requireAdmin` and answered 401 to that same request, which is what made
    // the disagreement visible. One gate now, and it is the one that works.
    const gate = await requireAdmin(deps, callerId, staff);
    if ('error' in gate) return json(gate.error.status, gate.error.body);
    const driverId = typeof record['driverId'] === 'string' ? record['driverId'] : '';
    const kind = typeof record['kind'] === 'string' ? record['kind'] : '';
    if (driverId === '' || kind === '') {
      return json(400, { error: 'driverId and kind are required' });
    }
    const url = await deps.signDocument(driverId, kind);
    // 404 rather than a 403: a driver who never sent this kind is a wrong
    // request, and a 403 would read as "you are not allowed to see documents",
    // which is a different and misleading thing to tell an admin.
    if (url === null) return json(404, { error: 'no such document' });
    return json(200, { url });
  }

  // The decisions this person has made, newest first.
  //
  // Not a luxury. An employee pressing Approve all afternoon needs to be able to
  // answer "did I already do that one?" without a supervisor, and the founder
  // needs it for "which of my staff approved these". Scoped to the caller: one
  // employee cannot see another's decisions, because in a small business that
  // is how you get people auditing each other instead of working.
  if (req.method === 'POST' && record['action'] === 'mydecisions') {
    if (staff === null) return json(401, { error: 'sign in to review applications' });
    const rows = await myDecisions(staff.id);
    return json(200, { decisions: rows });
  }

  if (req.method === 'POST' && record['action'] === 'decide') {
    const driverId = typeof record['driverId'] === 'string' ? record['driverId'] : '';
    const action = record['decision'] === 'reject' ? 'reject' : 'approve';
    const reason = typeof record['reason'] === 'string' ? record['reason'] : null;

    // The reason is checked before anything is written, and a rejection without
    // one is refused. A driver told "no" with no reason cannot do anything about
    // it, which makes the rejection worse than useless to them and no better
    // for the company than a delay.
    const check = validateDecision({
      driverId,
      decision: action === 'reject' ? 'rejected' : 'approved',
      staff,
      reason,
    });
    if (!check.ok) return json(400, { error: check.error });

    const result = await handleDecide(deps, callerId, { driverId, action }, staff);
    // Recorded only after the decision landed, so the log cannot claim an
    // approval that was refused -- which is the failure an audit trail exists to
    // make impossible.
    if (result.status === 200) {
      await recordDecision({
        driverId,
        decision: action === 'reject' ? 'rejected' : 'approved',
        staff,
        reason,
      });
    }
    return json(result.status, result.body);
  }

  // ## Reports
  //
  // Same gate as the KYC queue. `allowed()` is deliberately not narrowed to
  // `staff === null` for reads: anybody who can approve a driver can read a
  // rider's complaint, because in a business this size the person doing triage
  // and the person doing approvals are the same people, and splitting them
  // creates a second thing to administer without removing anybody's access.

  if (req.method === 'POST' && record['action'] === 'listreports') {
    const gate = await requireAdmin(deps, callerId, staff);
    if ('error' in gate) return json(gate.error.status, gate.error.body);
    // The recording state rides along with the reports rather than costing a
    // second round trip. The page needs it on every screen, because the banner
    // saying data is being kept longer than promised has to be visible to
    // somebody who came to approve a driver and never opened the Where tab.
    return json(200, {
      reports: await listReports(),
      recording: await readRecordingState(new Date()),
    });
  }

  if (req.method === 'POST' && record['action'] === 'decidereport') {
    const reportId = typeof record['reportId'] === 'string' ? record['reportId'] : '';
    const ask = record['decision'] === 'reopen'
      ? 'reopen'
      : record['decision'] === 'contact'
      ? 'contact'
      : record['decision'] === 'dismiss'
      ? 'dismiss'
      : null;
    if (reportId === '') return json(400, { error: 'reportId is required' });
    if (ask === null) return json(400, { error: 'decision must be dismiss, reopen or contact' });

    // The name comes from the session, never from the request body. A page that
    // could send its own `dismissed_by` would let any signed-in member of staff
    // write somebody else's name into the audit trail with one devtools call.
    //
    // A staff session is required rather than an admin login, and that is
    // stricter than the KYC queue on purpose: dismissing somebody's complaint is
    // a recorded decision about a named person, so it needs a named person. The
    // founder approves drivers under an admin account all day; for reports they
    // sign in as staff like everyone else.
    const by = staff === null ? null : staff.name;
    if (by === null) {
      return json(401, { error: 'sign in with your staff name and PIN to work on reports' });
    }

    const current = await readReport(reportId);
    // 404 for a report that does not exist. There is no such report as far as
    // this endpoint is concerned, and saying so to an attacker guessing ids
    // costs nothing to the employee who simply has a stale page open.
    if (current === null) return json(404, { error: 'no such report' });

    const intent = decide(current, {
      action: ask,
      by,
      note: typeof record['note'] === 'string' ? record['note'] : '',
      now: new Date(),
    });
    if (!intent.ok) return json(intent.status, { error: intent.error });

    const written = await writeReport(reportId, ask, intent.write, by);
    if (!written.ok) return json(written.status, { error: written.error });
    // Re-read rather than patching the row in place, so what the page renders
    // afterwards is what the database holds. Two maps agreeing by hand is how a
    // page starts showing a state nobody saved.
    const after = await readReport(reportId);
    return json(200, { report: after === null ? null : shapeReport(after) });
  }

  // ## Locations
  //
  // The same `requireAdmin` gate as everything else. Somebody who can approve a
  // driver can see where drivers are; there is no narrower group this business
  // has, and inventing one would mean administering it.

  if (req.method === 'POST' && record['action'] === 'listlocations') {
    const gate = await requireAdmin(deps, callerId, staff);
    if ('error' in gate) return json(gate.error.status, gate.error.body);
    return json(200, await listLocations());
  }

  if (req.method === 'POST' && record['action'] === 'resolveplace') {
    const gate = await requireAdmin(deps, callerId, staff);
    if ('error' in gate) return json(gate.error.status, gate.error.body);
    const who: Who = record['who'] === 'rider' ? 'rider' : 'driver';
    const profileId = typeof record['profileId'] === 'string' ? record['profileId'] : '';
    if (profileId === '') return json(400, { error: 'profileId is required' });
    const resolved = await resolvePlaceLabel(who, profileId);
    if (!resolved.ok) return json(resolved.status, { error: resolved.error });
    return json(200, { label: resolved.label });
  }

  if (req.method === 'POST' && record['action'] === 'setrecording') {
    const gate = await requireAdmin(deps, callerId, staff);
    if ('error' in gate) return json(gate.error.status, gate.error.body);

    // Turning it off is always permitted. Turning it on needs a name and a
    // duration, and the duration is capped -- see keepIntent.
    const stopping = record['keep'] !== true;
    const intent = stopping
      ? stopIntent(staff === null ? '' : staff.name)
      : keepIntent({
        by: staff === null ? '' : staff.name,
        days: typeof record['days'] === 'number' ? record['days'] : Number(record['days']),
        now: new Date(),
      });
    if (!intent.ok) return json(intent.status, { error: intent.error });

    const { error } = await (serviceClient() as unknown as {
      from(t: string): {
        update(v: Record<string, unknown>): {
          eq(c: string, v: unknown): {
            select(c: string): Promise<{ error: { message: string } | null }>;
          };
        };
      };
    })
      .from('location_settings')
      .update(intent.write)
      .eq('id', true)
      .select('keep_recording');

    if (error !== null) {
      return json(502, { error: error.message || 'that could not be saved' });
    }
    const state = await listLocations();
    return json(200, { recording: state.recording });
  }

  const result = await handleList(deps, callerId, staff);
  return json(result.status, result.body);
});
