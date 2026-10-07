// The admin KYC decision, with no supabase-js in it.

import { type StaffIdentity } from './staff.ts';
//
// Split from `index.ts` for the reason every other function in this directory
// is split the same way: the port builder imports
// `https://esm.sh/@supabase/supabase-js@2.45.4` at module scope, and the Deno
// test job does not resolve `esm.sh` -- `_shared/rows.ts` sets out exactly what
// that costs and why the test files avoid it. The rules that decide who may
// approve a driver, and what approving one does, are ordinary functions over a
// narrow `AdminDeps` interface, so they are testable with a fake and no network.

/** What the function needs from the database, so a test can supply a fake. */
export interface AdminDeps {
  /** Resolves a bearer token to a user id, or null if the auth server refuses. */
  authenticate: (token: string) => Promise<string | null>;

  /** The caller's `role`, or null when they have no profile row. */
  roleOf: (userId: string) => Promise<string | null>;

  /** Drivers awaiting a decision, newest submission first. */
  listPending: () => Promise<PendingDriver[]>;

  /**
   * Applies the decision to the profile.
   *
   * Returns the row as written, or null when nothing matched -- a driver who
   * deleted their account between the list and the click.
   */
  decide: (
    driverId: string,
    status: 'approved' | 'rejected',
    /**
     * The Supabase user who decided, or null when a staff member did.
     *
     * Nullable because `profiles.approved_by` is a foreign key to `auth.users`
     * and a staff member has no auth user. Their attribution goes to
     * `kyc_decisions` instead, which is the table built for it.
     */
    decidedBy: string | null,
  ) => Promise<PendingDriver | null>;

  /**
   * Approves the driver's vehicle, if they have one.
   *
   * Separate from `decide` because it is a different table and a different
   * failure: a driver can be approved with no vehicle, and the caller has to be
   * told so rather than being shown a green tick for a driver who will never be
   * offered a trip.
   */
  approveVehicle: (driverId: string) => Promise<boolean>;

  /**
   * The documents this driver has sent, as `{ kind, path }`.
   *
   * Kinds and paths, never URLs. A signed URL is a bearer credential for
   * somebody's passport, and minting six of them per driver into a list
   * response would put a week of expiring credentials in one JSON blob that is
   * easy to log. [signDocument] is the only thing that turns a path into one,
   * and it is only called when an admin actually asks to look.
   */
  documentsFor: (driverId: string) => Promise<DriverDocumentRow[]>;

  /**
   * A short-lived signed URL for one document, or null if it cannot be signed.
   *
   * Refuses for a `kind` the driver has not sent, not just for a missing file:
   * this takes a kind from the request, and a signed URL for a path chosen by
   * the caller would sign anything in the bucket.
   */
  signDocument: (
    driverId: string,
    kind: string,
  ) => Promise<string | null>;
}

/** One document a driver has sent, as the database holds it. */
export interface DriverDocumentRow {
  kind: string;
  path: string;
  /**
   * When the row was written, from `driver_documents.created_at`.
   *
   * Optional because one caller does not need it: `documentsFor` serves a signed
   * URL for a single document and has no reason to read a timestamp. The list
   * path needs it, and `submittedAtFor` below is where it is used.
   */
  createdAt?: string;
}

/**
 * The six photographs, without which a driver cannot be approved.
 *
 * The same wire values as the `driver_documents` check constraint in
 * `20260929000002_driver_documents.sql` and `DriverDocumentKind` in the app.
 * Written out here because this function has no access to the Dart enum, and a
 * list that silently drifts from the constraint would let an admin approve a
 * driver who sent a document the database would not even accept.
 *
 * `livenessFrame` is deliberately NOT here, and the reason is a fact about the
 * app's history rather than a view about whether liveness matters.
 *
 * The face check was required until ML Kit proved unusable on the test phone:
 * `detector.processImage` threw a NullPointerException out of Google's own
 * runtime on every frame, through the community plugin on two versions and
 * through a MethodChannel calling the same native API directly. A required
 * check that cannot run blocks every driver at the last step of onboarding over
 * something they cannot act on, so it was made optional rather than left as a
 * wall.
 *
 * It has since been rebuilt on MediaPipe plus MiniFASNet, both Apache 2.0 and
 * both on-device, and it is covered by tests. It is not required *here* yet
 * because it has not been run on a real phone. Being precise about what that
 * costs: an admin approving a driver who skipped it is approving on the six
 * photographs plus their own comparison of the profile picture against the
 * licence, and the face check frame is the one extra photograph they could
 * have compared.
 *
 * It is still in [ALL_DOCUMENTS], so the page shows a row for it, says when it
 * is missing, and displays the frame when there is one. Optional for approval,
 * visible to the reviewer -- hiding it would hide the one photograph from the
 * only person who could judge it. Once the check has been seen working on a
 * phone, this becomes `[...REQUIRED_DOCUMENTS, 'livenessFrame']`.
 */
export const REQUIRED_DOCUMENTS: readonly string[] = [
  'profilePhoto',
  'vehiclePhoto',
  'ghanaCardPhoto',
  'driversLicence',
  'roadWorthy',
  'insuranceSticker',
] as const;

/**
 * Everything a driver can send, required or not.
 *
 * The seven wire values, in the order the app asks for them. The page renders a
 * row per entry, so a document that exists but is not required is shown rather
 * than omitted.
 */
export const ALL_DOCUMENTS: readonly string[] = [
  'profilePhoto',
  'vehiclePhoto',
  'ghanaCardPhoto',
  'driversLicence',
  'roadWorthy',
  'insuranceSticker',
  'livenessFrame',
] as const;

/** Display names, keyed by the same wire values as [ALL_DOCUMENTS]. */
export const DOCUMENT_LABELS: Readonly<Record<string, string>> = {
  profilePhoto: 'Profile picture',
  vehiclePhoto: 'Vehicle photo',
  ghanaCardPhoto: 'Ghana card photo',
  driversLicence: "Driver's licence photo",
  roadWorthy: 'Road worthy certificate',
  insuranceSticker: 'Insurance sticker',
  livenessFrame: 'Face check photo',
};

/**
 * What a driver is missing, in the order the app asks for them.
 *
 * Only the required ones, because this is the list that decides whether an
 * approval is allowed. Optional documents are reported by
 * [optionalMissing] instead, so the page can say "3 of 6 sent" and
 * "no face check photo" without either number being confused for the other.
 */
export function missingDocuments(sent: readonly { kind: string }[]): string[] {
  const have = new Set(sent.map((d) => d.kind));
  return REQUIRED_DOCUMENTS.filter((kind) => !have.has(kind));
}

/** The optional documents a driver has not sent, in display order. */
export function optionalMissing(sent: readonly { kind: string }[]): string[] {
  const have = new Set(sent.map((d) => d.kind));
  return ALL_DOCUMENTS.filter(
    (kind) => !REQUIRED_DOCUMENTS.includes(kind) && !have.has(kind),
  );
}

/**
 * When a driver submitted their application, which is what the queue shows.
 *
 * ## Why this is not the account creation date
 *
 * It was, and it was wrong in a way that matters. `profiles.created_at` is when
 * somebody made an account, which can be days before they photograph anything --
 * they have to find a Ghana Card, a licence, a road worthy certificate, a car
 * and a garage to take the picture in. One real driver signed up on the 28th and
 * uploaded all seven documents on the 30th, and the queue told an employee his
 * application was "2 days ago" while every photograph they were being asked to
 * judge was hours old.
 *
 * Two things go wrong from that, and both are the employee's judgement being
 * quietly poisoned:
 *
 *  * **Recency of the queue.** "2 days ago" reads as "this has been sitting here
 *    for two days", when the truth is it arrived this morning.
 *  * **Freshness of the evidence.** The photographs on that screen are the
 *    evidence. Judging a Ghana Card photo that is a week old because the
 *    *account* is a week old is a different decision from judging one taken an
 *    hour ago, and the number on screen was describing the wrong thing.
 *
 * ## The rule
 *
 * The most recent **required** document's `created_at`. One rule for both the
 * complete and the incomplete case, and it answers both questions above:
 *
 *  * Complete -- that is the moment the application became decidable, so it is
 *    exactly "how long has this been waiting for me" and "how old are these
 *    photographs".
 *  * Incomplete -- it is the last thing they did, which is the progress signal an
 *    employee wants. The missing documents are listed separately by
 *    [missingDocuments], so the number is never read as "ready".
 *
 * `livenessFrame` is excluded along with every other optional document, because
 * a face check taken three days after the licence would otherwise make a
 * two-day-old application look three days old.
 *
 * With no documents at all there is nothing to date, so the account creation
 * date is returned -- which is the truth, and is the one case where the old
 * behaviour was right.
 *
 * Unparseable timestamps are skipped rather than allowed to win. `new Date('nonsense')`
 * is NaN, and a NaN that reached the page would render as "NaN days ago"; losing
 * one timestamp to a fallback is a smaller failure than showing one.
 */
export function submittedAtFor(
  accountCreatedAt: string,
  documents: readonly { kind: string; createdAt?: string }[],
): string {
  let newestMs = NaN;
  for (const d of documents) {
    if (!REQUIRED_DOCUMENTS.includes(d.kind)) continue;
    const raw = d.createdAt;
    if (raw === undefined || raw === '') continue;
    const ms = Date.parse(raw);
    if (Number.isNaN(ms)) continue;
    if (Number.isNaN(newestMs) || ms > newestMs) newestMs = ms;
  }
  if (Number.isNaN(newestMs)) return accountCreatedAt;
  return new Date(newestMs).toISOString();
}

/**
 * Whole years from a Ghana Card date of birth to today, or null.
 *
 * The same arithmetic as `ageFromGhanaCardDate` in `mng_core`, written out again
 * because a Deno Edge Function cannot import Dart and an employee needs the age
 * next to the photograph. The two are kept in step by the tests: this one is
 * pinned here, the Dart one in `ghana_card_parser_test.dart`, and the formats
 * they accept are asserted in both.
 *
 * A null is the answer for anything unreadable, and the page says "not given"
 * rather than showing a number. An age is the fastest thing an eye checks
 * against a face, so a plausible wrong one is a plausible wrong approval.
 *
 * `now` is a parameter so the tests do not have to freeze time, and so this is
 * not secretly a second source of today's date.
 */
export function ageFromGhanaCardDate(
  raw: string | null | undefined,
  now: Date = new Date(),
): number | null {
  if (raw === null || raw === undefined) return null;
  const text = raw.trim();
  if (text === '') return null;

  let year: number;
  let month: number;
  let day: number;

  // ISO first: `1994-03-14` would otherwise be read as day 1994, which is not a
  // date. Order matters for the same reason it does in Dart.
  const iso = /^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})$/.exec(text);
  if (iso !== null) {
    year = Number(iso[1]);
    month = Number(iso[2]);
    day = Number(iso[3]);
  } else {
    const dmy = /^(\d{1,2})[-/.](\d{1,2})[-/.](\d{2,4})$/.exec(text);
    if (dmy === null) return null;
    day = Number(dmy[1]);
    month = Number(dmy[2]);
    year = Number(dmy[3]);
    if (year < 100) year += year <= 30 ? 2000 : 1900;
  }

  // Reject rather than roll over. `Date` would turn 31 February into 3 March and
  // the page would show that as a fact.
  if (month < 1 || month > 12) return null;
  if (day < 1 || day > 31) return null;
  if (year < 1900 || year > now.getUTCFullYear() + 1) return null;
  const probe = new Date(Date.UTC(year, month - 1, day));
  if (
    probe.getUTCFullYear() !== year ||
    probe.getUTCMonth() !== month - 1 ||
    probe.getUTCDate() !== day
  ) {
    return null;
  }

  let years = now.getUTCFullYear() - year;
  const hadBirthday = now.getUTCMonth() + 1 > month ||
    (now.getUTCMonth() + 1 === month && now.getUTCDate() >= day);
  if (!hadBirthday) years -= 1;
  return years < 0 ? null : years;
}

/** One driver, as the admin page shows them. */
export interface PendingDriver {
  id: string;
  email: string;
  fullName: string;
  phone: string;
  /** What the app stores of the Ghana Card. See the note on `last4` below. */
  cardLast4: string;
  selfieUrl: string;
  vehicle: { make: string; model: string; plate: string; seats: number } | null;
  submittedAt: string;

  /**
   * The Ghana Card, as the driver entered it.
   *
   * Reported as stored rather than tidied. An employee is comparing these
   * against a photograph of the card, and a value this function has quietly
   * reformatted is a value they cannot check.
   *
   * `cardNumber` is null for a driver who submitted before
   * `20260930000003_ghana_card_fields.sql`, and then carries the four digits of
   * `ghana_card_last4` with `cardNumberIsPartial` set, so the page can say "first
   * four digits only" rather than presenting four digits as the whole number.
   * Note that `last4` holds the *first* four digits -- the app writes
   * `digits.substring(0, 4)` -- so the name is a misnomer that predates this.
   */
  cardNumber: string | null;
  /** True when [cardNumber] is only the leading four digits. */
  cardNumberIsPartial: boolean;
  cardDob: string;
  cardSex: string;
  cardNationality: string;
  cardIssued: string;
  cardExpiry: string;
  /** Computed from [cardDob]; null when it cannot be read. */
  cardAge: number | null;

  /**
   * The kinds this driver has sent.
   *
   * Kinds only, not URLs, for the reason on `AdminDeps.documentsFor`. The
   * admin sees the name of each document and clicks to view it, which is one
   * short-lived signed URL at a time rather than six per driver in a response
   * that is easy to log.
   */
  documents: string[];
}

export interface ListResult {
  status: number;
  body: Record<string, unknown>;
}

/**
 * Who may approve a driver.
 *
 * `role = 'admin'` on the caller's own profile row, read with the service key
 * because a client cannot be trusted to say what role it has. This is the whole
 * authorisation of the function and it is one comparison on purpose: the
 * service key bypasses every RLS policy in the database, so anything that
 * reaches this code without proving it is an admin can approve itself.
 *
 * A caller with no profile row is not an admin. `handle_new_user` creates the
 * row on signup, so a missing one means the account was created outside the
 * normal path -- and an account that came from nowhere is not an admin.
 */
export function isAdmin(role: string | null): boolean {
  return role === 'admin';
}

/**
 * The list of drivers waiting on a decision.
 *
 * Refuses before it reads anything. A 401 that had queried first would tell a
 * non-admin whether the table exists and how long the query took, which is
 * information about a database whose RLS is the only thing between an anon key
 * and every driver's phone number.
 */
export async function handleList(
  deps: AdminDeps,
  callerId: string | null,
  /** Set when the caller is a staff member rather than a Supabase admin. */
  staff?: StaffIdentity | null,
): Promise<ListResult> {
  const gate = await requireAdmin(deps, callerId, staff);
  if ('error' in gate) return gate.error;

  const drivers = await deps.listPending();
  return {
    status: 200,
    body: { drivers },
  };
}

export interface DecideInput {
  driverId: string;
  action: 'approve' | 'reject';
}

export interface DecideResult extends ListResult {
  /** Whether the vehicle was approved too. False is not a failure. */
  vehicleApproved?: boolean;
  /** Set when the driver was approved but has no vehicle row. */
  warning?: string;
}

/**
 * Approves or rejects one driver.
 *
 * The two things that are easy to get wrong are both handled explicitly rather
 * than left to a caller to remember:
 *
 * 1. `match_offers_for_trip` joins `vehicles v on v.owner_id = d.id and
 *    v.approved`, so approving the profile alone leaves a driver invisible to
 *    the matcher however online they are -- while their own app shows them as
 *    ready. The vehicle is approved in the same call, and its absence is a
 *    warning rather than a success.
 *
 * 2. A decision is written with the admin's own id, so there is a record of who
 *    approved a driver. Without it, "why is this driver online" has no answer
 *    after the fact.
 */
export async function handleDecide(
  deps: AdminDeps,
  callerId: string | null,
  input: DecideInput,
  /** Set when the caller is a staff member rather than a Supabase admin. */
  staff?: StaffIdentity | null,
): Promise<DecideResult> {
  const gate = await requireAdmin(deps, callerId, staff);
  if ('error' in gate) return gate.error;

  if (input.action !== 'approve' && input.action !== 'reject') {
    return {
      status: 400,
      body: { error: 'action must be approve or reject' },
    };
  }
  if (input.driverId === '') {
    return { status: 400, body: { error: 'driverId is required' } };
  }

  const status = input.action === 'approve' ? 'approved' : 'rejected';

  // Checked before anything is written, and only for an approval.
  //
  // The six documents are the entire substance of this decision: a licence, a
  // road worthy and an insurance sticker are what "this person may drive this
  // vehicle for paying passengers" is actually made of. Approving without them
  // would not be a slower review, it would be no review at all -- the button
  // would be a rubber stamp with an audit trail attached, which is worse than
  // no button because it produces a record of a check that never happened.
  //
  // A rejection is always allowed. Refusing to let an admin turn a driver away
  // is a different kind of wrong, and there is no case for it.
  if (input.action === 'approve') {
    const sent = await deps.documentsFor(input.driverId);
    const missing = missingDocuments(sent);
    if (missing.length > 0) {
      // A count, not the word "all six", because [REQUIRED_DOCUMENTS] is the
      // list the number comes from and a hardcoded six in a sentence beside a
      // list that can change is a sentence that will be wrong.
      return {
        status: 409,
        body: {
          error:
            `This driver is still missing ${missing.length} of the ` +
            `${REQUIRED_DOCUMENTS.length} required documents.`,
          missing,
        },
      };
    }
  }

  // `approved_by` is null for a staff decision, and that is the honest value.
  //
  // The column is a foreign key to `auth.users` and a staff member has no auth
  // user, so writing their id there would fail the constraint and take the whole
  // decision down. The attribution for staff decisions lives in
  // `kyc_decisions`, which carries both a staff id and a name; this column stays
  // null and the founder's own approvals keep filling it.
  const approvedBy = gate.staffName === null ? gate.adminId : null;

  const row = await deps.decide(input.driverId, status, approvedBy);
  if (row === null) {
    // The driver is gone. A 404 rather than a 200 that quietly did nothing,
    // because the admin's next question would be "did that work".
    return { status: 404, body: { error: 'driver not found' } };
  }

  if (input.action === 'reject') {
    return { status: 200, body: { driver: row } };
  }

  const vehicleApproved = await deps.approveVehicle(input.driverId);
  const warning = vehicleApproved
    ? undefined
    : 'Approved, but this driver has no vehicle row, so they will not be ' +
      'offered any trips. Add the vehicle and approve it too.';

  return {
    status: 200,
    body: { driver: row },
    vehicleApproved,
    warning,
  };
}

/**
 * The admin's own id when they are one, or the refusal to answer with.
 *
 * A discriminated union rather than a `ListResult | null`, because the two
 * answers are not the same kind of thing and mixing them up is how a caller
 * ends up writing `approved_by` with an HTTP status in it. The refusal is an
 * object so it cannot be silently used as the id.
 */
/**
 * Who may act on a driver application, resolved once.
 *
 * Exported because this is the *only* authorisation this function has, and there
 * was a second, weaker copy of it living in `index.ts` as `allowed()`. The copy
 * in `index.ts` let an unauthenticated `POST {action:'document'}` through with no
 * credentials at all -- it returned a signed URL to a driver's Ghana Card and
 * licence photograph to anybody who asked -- while this one, used by `handleList`
 * on the very same request, correctly returned 401. Two gates for one decision is
 * how that happens, so there is now one, and it is this one.
 *
 * Both caller kinds are still allowed, deliberately: a founder and a member of
 * staff both have to be able to open a licence to do the job.
 */
export async function requireAdmin(
  deps: AdminDeps,
  callerId: string | null,
  staff?: StaffIdentity | null,
): Promise<
  { adminId: string; staffName: string | null } | { error: ListResult }
> {
  // A staff member is already resolved by `staffFor`, which found a live
  // `staff_sessions` row for this token. There is no role to check -- the row
  // existing *is* the permission -- so this returns immediately and the Supabase
  // path below is never reached for them.
  //
  // `adminId` is the staff id rather than a `profiles` row, because
  // `profiles.approved_by` is a foreign key to `auth.users` and a staff member
  // has no auth user. The id is still the right thing to record: it is stable,
  // it is what the decision log joins on, and `profiles.approved_by` is nullable
  // so a staff decision leaves it null rather than failing on the constraint.
  if (staff != null) {
    return { adminId: staff.id, staffName: staff.name };
  }
  if (callerId === null) {
    return {
      error: {
        status: 401,
        // Said as an instruction rather than as the platform's word. An
        // employee who signs in with a PIN and then sees "admin only" has no
        // idea what an admin is.
        body: { error: 'sign in to review applications' },
      },
    };
  }
  if (!isAdmin(await deps.roleOf(callerId))) {
    return { error: { status: 403, body: { error: 'admin only' } } };
  }
  return { adminId: callerId, staffName: null };
}
