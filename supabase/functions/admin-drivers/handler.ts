// The admin KYC decision, with no supabase-js in it.
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
    decidedBy: string,
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
}

/**
 * What a driver has to send before they can be approved: the six photographs
 * and the face check's frame.
 *
 * The same seven, in the same wire values, as the `driver_documents` check
 * constraint in `20260929000003_liveness_frame.sql` and the
 * `DriverDocumentKind` enum in the app. Written out here because this function
 * has no access to the Dart enum, and a list that silently drifts from the
 * constraint would let an admin approve a driver who sent a document the
 * database would not even accept.
 *
 * `livenessFrame` is in this list, and that is the point of it. A driver with
 * all six photographs and no face check looks, to anything that counts only
 * photographs, like a complete application -- and the frame is the only item
 * here an admin can compare against the licence photograph.
 */
export const REQUIRED_DOCUMENTS: readonly string[] = [
  'profilePhoto',
  'vehiclePhoto',
  'ghanaCardPhoto',
  'driversLicence',
  'roadWorthy',
  'insuranceSticker',
  'livenessFrame',
] as const;

/** What a driver is missing, in the order the app asks for them. */
export function missingDocuments(sent: readonly { kind: string }[]): string[] {
  const have = new Set(sent.map((d) => d.kind));
  return REQUIRED_DOCUMENTS.filter((kind) => !have.has(kind));
}

/** One driver, as the admin page shows them. */
export interface PendingDriver {
  id: string;
  email: string;
  fullName: string;
  phone: string;
  /** What the app stores of the Ghana Card. See the note on `last4` below. */
  cardLast4: string;
  cardExpiry: string;
  selfieUrl: string;
  vehicle: { make: string; model: string; plate: string; seats: number } | null;
  submittedAt: string;

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
): Promise<ListResult> {
  const gate = await requireAdmin(deps, callerId);
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
): Promise<DecideResult> {
  const gate = await requireAdmin(deps, callerId);
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
    const missing = missingDocuments(await deps.documentsFor(input.driverId));
    if (missing.length > 0) {
      return {
        status: 409,
        body: {
          error: 'This driver has not sent all six documents yet.',
          missing,
        },
      };
    }
  }

  const row = await deps.decide(input.driverId, status, gate.adminId);
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
async function requireAdmin(
  deps: AdminDeps,
  callerId: string | null,
): Promise<{ adminId: string } | { error: ListResult }> {
  if (callerId === null) {
    return { error: { status: 401, body: { error: 'sign in as an admin' } } };
  }
  if (!isAdmin(await deps.roleOf(callerId))) {
    return { error: { status: 403, body: { error: 'admin only' } } };
  }
  return { adminId: callerId };
}
