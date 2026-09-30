// Staff sign-in, session checks, and decision recording.
//
// Split from `handler.ts` for the same reason every other file in this directory
// is: the port builder imports `https://esm.sh/@supabase/supabase-js@2.45.4` at
// module scope and the Deno test job does not resolve `esm.sh`. This file imports
// nothing, so the rules that decide whether an employee may press Approve are
// testable with a fake and no network.
//
// ## Why staff exist at all
//
// Because the alternative was that every person who approves drivers had to hold
// a Supabase account. The founder could make one in the Dashboard; an employee
// could not, and being handed an email, a password and a long edge-function URL
// is not how a non-technical colleague is onboarded onto a tool they will use all
// day. The old deploy notes made it worse by saying a driver's own account was
// fine, which throws away the only thing an approval log has to be: a name.
//
// So: a name, a short PIN, a session row, and every decision attributed. The
// founder keeps the Supabase path, because creating staff and revoking them is
// deliberately not something the page can do -- a self-service path is a signup
// form.

/** Why a sign-in was refused, in the words the page shows. */
export type StaffSignInFailure =
  | 'noSuchPerson'
  | 'wrongPin'
  | 'locked'
  | 'deactivated'
  | 'noPin';

export interface StaffSignInResult {
  ok: boolean;
  /** Set when ok. The token the browser holds; it is not a JWT and grants nothing on its own. */
  token?: string;
  /** Set when not ok. The page turns this into a sentence. */
  failure?: StaffSignInFailure;
  /** The staff member's name, echoed back so the page can show "signed in as". */
  name?: string;
  /** Seconds until the session expires. */
  expiresIn?: number;
}

/** What the caller of {@link decide} is allowed to record. */
export interface StaffIdentity {
  id: string;
  name: string;
}

/** The row {@link signIn} writes and {@link findSession} reads. */
export interface SessionGrant {
  token: string;
  /** sha256 of {@link token}, which is what is stored. */
  tokenHash: string;
  staffId: string;
  name: string;
  expiresAt: Date;
}

/**
 * The database calls this file needs, and nothing else.
 *
 * Narrow on purpose. A wider interface would be a wider thing to get wrong, and
 * every method here is one a test has to implement.
 */
export interface StaffDeps {
  /**
   * The staff row for a name, case-insensitively, or null.
   *
   * Case-insensitive because employees type their own name on a phone keyboard
   * and a wrong case reading as "no such person" is baffling rather than useful.
   */
  findByName(name: string): Promise<StaffRow | null>;

  /**
   * Whether [pin] is this staff member's PIN.
   *
   * The hash is compared in Postgres and never leaves it. This app has no bcrypt
   * implementation and adding a JavaScript one to compare a value it would then
   * have to read out of the database would put the hash in the function's memory
   * for no benefit -- the round trip is the same either way and this way the
   * plaintext hash is never in a log line or an error message.
   */
  pinMatches(staffId: string, pin: string): Promise<boolean>;

  /** Records a correct PIN: clears the lockout counters, stamps last_used_at. */
  markUsed(staffId: string): Promise<void>;

  /** Records a wrong PIN: increments the counter and applies the lockout. */
  markFailed(staffId: string): Promise<void>;

  /** Stores a session row. */
  createSession(grant: SessionGrant): Promise<void>;

  /** The staff id and name a token hash belongs to, if the session is live. */
  findSession(tokenHash: string): Promise<StaffIdentity | null>;

  /** Ends one session. */
  deleteSession(tokenHash: string): Promise<void>;
}

export interface StaffRow {
  id: string;
  name: string;
  /** Stored, never compared here: comparison happens in Postgres so the hash never leaves it. */
  pinHash: string;
  active: boolean;
  failedAttempts: number;
  lockedUntil: Date | null;
}

/** How long a staff session lasts. */
export const SESSION_HOURS = 12;

/**
 * Wrong PINs before the account locks, and for how long.
 *
 * The lock is on the account rather than the address because there is no address:
 * a four-digit PIN has no room for one, so without an account lock a stranger
 * could work through all ten thousand of them. Twenty attempts with a fifteen
 * minute lock makes guessing slower than pointless while never inconveniencing
 * somebody who fat-fingers their own PIN twice.
 */
export const MAX_FAILED_ATTEMPTS = 20;
export const LOCK_MINUTES = 15;

/**
 * Checks a PIN and starts a session.
 *
 * `now` is a parameter rather than a read from the clock so that the lockout
 * window is testable; `token` likewise, so a test does not depend on randomness.
 */
export async function signIn(
  deps: StaffDeps,
  input: { name: string; pin: string; now: Date; token: string; tokenHash: string },
): Promise<StaffSignInResult> {
  const name = input.name.trim();
  // Not an error, a correction: a PIN is four digits and anything else is a
  // typo, and "that PIN is not four digits" is more use than "wrong PIN".
  if (!/^\d{4}$/.test(input.pin.trim())) {
    return { ok: false, failure: 'noPin' };
  }
  if (name === '') {
    return { ok: false, failure: 'noSuchPerson' };
  }

  const row = await deps.findByName(name);
  // Refused before the PIN is even looked at when the row is missing or the
  // person is not active, and the page says the same sentence for both. Telling
  // a stranger "no such person" and "that PIN is wrong" apart is a free oracle
  // for finding out who works here.
  if (row === null || !row.active) {
    return { ok: false, failure: row === null ? 'noSuchPerson' : 'deactivated' };
  }

  if (row.lockedUntil !== null && row.lockedUntil > input.now) {
    return { ok: false, failure: 'locked' };
  }

  const matches = await deps.pinMatches(row.id, input.pin.trim());
  if (!matches) {
    await deps.markFailed(row.id);
    return { ok: false, failure: 'wrongPin' };
  }

  await deps.markUsed(row.id);
  const expiresAt = new Date(
    input.now.getTime() + SESSION_HOURS * 60 * 60 * 1000,
  );
  await deps.createSession({
    token: input.token,
    tokenHash: input.tokenHash,
    staffId: row.id,
    name: row.name,
    expiresAt,
  });

  return {
    ok: true,
    token: input.token,
    name: row.name,
    expiresIn: SESSION_HOURS * 60 * 60,
  };
}

/**
 * Resolves a bearer token to a staff member, or null.
 *
 * Null for every kind of failure -- unknown, expired, revoked -- because the
 * caller answers all of them the same way and a different answer would leak
 * which tokens ever existed.
 */
export async function findSession(
  deps: StaffDeps,
  tokenHash: string,
): Promise<StaffIdentity | null> {
  if (tokenHash === '') return null;
  const found = await deps.findSession(tokenHash);
  return found ?? null;
}

/** Signs a staff member out. Safe to call with a token that is already gone. */
export async function signOut(deps: StaffDeps, tokenHash: string): Promise<void> {
  if (tokenHash === '') return;
  await deps.deleteSession(tokenHash);
}

/**
 * The reasons a driver can be turned away.
 *
 * A fixed list, and the page makes the employee choose one. A rejection with no
 * reason is the single most useless thing this tool can do to a driver: they
 * are told no, they cannot work out why, and they cannot fix it. "Other" exists
 * so nobody is forced into a wrong answer, and it is the only one that asks for
 * a sentence.
 */
export const DECLINE_REASONS: Readonly<Record<string, string>> = {
  missingDocument: 'A required document is missing',
  unreadablePhoto: 'A photo is too dark, blurred or cut off to read',
  faceDoesNotMatch: 'The face does not match the licence photo',
  detailsDoNotMatch: 'The name, card number or vehicle details do not agree',
  looksLikeAnotherPerson: 'This does not look like the person applying',
  other: 'Something else',
};

/** Whether a reason is one the page offered. */
export function isKnownReason(reason: string | null): boolean {
  if (reason === null) return false;
  return Object.prototype.hasOwnProperty.call(DECLINE_REASONS, reason);
}

/**
 * A decision, as the handler will write it.
 *
 * `staff` is null for a decision made through the Supabase admin path, which is
 * a real case and not an error: the founder approves drivers too.
 */
export interface DecisionRecord {
  driverId: string;
  decision: 'approved' | 'rejected';
  staff: StaffIdentity | null;
  reason: string | null;
}

/**
 * Checks a decision before anything is written.
 *
 * The rule that matters: **a rejection must say why.** Not "should" -- must,
 * because the alternative is a driver who cannot act on the outcome. An approval
 * needs no reason.
 */
export function validateDecision(
  decision: DecisionRecord,
): { ok: true } | { ok: false; error: string } {
  if (decision.decision === 'rejected') {
    if (decision.reason === null || decision.reason === '') {
      return {
        ok: false,
        error: 'Say why this driver is being turned away, so they can fix it.',
      };
    }
    if (!isKnownReason(decision.reason)) {
      return { ok: false, error: 'That reason is not one of the options.' };
    }
  }
  return { ok: true };
}
