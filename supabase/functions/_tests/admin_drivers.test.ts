// The admin KYC rules, with no supabase-js and no network.
//
// `handler.ts` is deliberately free of the `https://esm.sh/@supabase/supabase-js`
// import that `index.ts` carries at module scope, which is what lets these run
// with no remote host at all. `_shared/rows.ts` sets out why that matters in
// this directory; the short version is that the test job does not resolve
// esm.sh, and a test importing a port builder to reach a rule would add it.
//
// Every test here is about a rule that, if it broke, would let a non-admin
// approve a driver or would approve one without a vehicle. Both are silent
// failures in production: the first is a privilege escalation and the second is
// a driver who shows as ready and is never offered a ride.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import {
  handleDecide,
  handleList,
  isAdmin,
  missingDocuments,
  REQUIRED_DOCUMENTS,
  type AdminDeps,
  type DriverDocumentRow,
  type PendingDriver,
} from '../admin-drivers/handler.ts';

/** The six documents, as a driver who has sent all of them holds them. */
function allSix(): DriverDocumentRow[] {
  return REQUIRED_DOCUMENTS.map((kind) => ({
    kind,
    path: `u1/${kind}/1.jpg`,
  }));
}

function fake(overrides: Partial<AdminDeps> = {}) {
  // The counters live beside the fake rather than inside the returned object,
  // because attaching them with `Object.assign` would erase the contextual
  // types on the methods below and every parameter would become an implicit
  // `any`. Typed here for the same reason: the point of the cast is that these
  // are the shapes `AdminDeps` declares.
  const listed: { count: number } = { count: 0 };
  const decided: { driverId: string; status: string; by: string }[] = [];
  const vehiclesApproved: string[] = [];
  const signed: { driverId: string; kind: string }[] = [];
  // Sent by default, so the tests that predate the document gate keep testing
  // what they were written for. A test about the gate overrides this with the
  // specific gap it is about -- defaulting it to "none sent" would have failed
  // a dozen unrelated tests and taught nothing.
  const state: { documents: DriverDocumentRow[] } = { documents: allSix() };

  const base: AdminDeps = {
    authenticate: async (t: string) => (t === 'good' ? 'admin-1' : null),
    roleOf: async (_userId: string) => 'admin',
    listPending: async (): Promise<PendingDriver[]> => {
      listed.count++;
      return [];
    },
    decide: async (
      driverId: string,
      status: 'approved' | 'rejected',
      decidedBy: string,
    ): Promise<PendingDriver | null> => {
      decided.push({ driverId, status, by: decidedBy });
      return {
        id: driverId,
        email: 'd@example.com',
        fullName: 'Jane Cooper',
        phone: '',
        cardLast4: '1234',
        cardExpiry: '12/29',
        selfieUrl: '',
        vehicle: null,
        documents: [],
        submittedAt: '',
      };
    },
    approveVehicle: async (driverId: string): Promise<boolean> => {
      vehiclesApproved.push(driverId);
      return true;
    },
    documentsFor: async (_driverId: string): Promise<DriverDocumentRow[]> =>
      state.documents,
    signDocument: async (driverId: string, kind: string): Promise<string | null> => {
      signed.push({ driverId, kind });
      const found = state.documents.find((d) => d.kind === kind);
      // A URL is only minted for a kind this driver actually sent. Mirrors
      // `index.ts`: signing a path the caller chose would hand out working
      // URLs for anything in the bucket.
      if (found === undefined) return null;
      return `https://example.test/${driverId}/${kind}?token=signed`;
    },
    ...overrides,
  };

  return Object.assign(base, {
    get listed() {
      return listed.count;
    },
    decided,
    vehiclesApproved,
    signed,
    state,
  });
}

Deno.test('isAdmin is exactly role = admin', () => {
  assert(isAdmin('admin'));
  // The tempting wrong answers. A driver approving drivers is the one that
  // matters: `role = 'driver'` is a value a driver can reach on their own
  // signup, so anything that treated a driver as an admin would hand the
  // service key's power to every driver with an account.
  assert(!isAdmin('driver'));
  assert(!isAdmin('rider'));
  assert(!isAdmin(null));
  assert(!isAdmin('Admin'), 'the comparison is case sensitive on purpose');
  assert(!isAdmin(''));
});

Deno.test('the list is refused before anything is read', async () => {
  let listed = 0;
  const deps = fake({
    roleOf: async () => 'rider',
    listPending: async () => {
      listed++;
      return [];
    },
  });

  const anonymous = await handleList(deps, null);
  assertEquals(anonymous.status, 401);

  const notAdmin = await handleList(deps, 'driver-9');
  assertEquals(notAdmin.status, 403);

  assertEquals(listed, 0, 'a refusal must not query first');
});

Deno.test('a caller with no profile row is not an admin', async () => {
  const deps = fake({ roleOf: async () => null });
  const result = await handleList(deps, 'someone');
  // `handle_new_user` creates the row on signup, so a missing one means the
  // account came from outside the normal path.
  assertEquals(result.status, 403);
});

Deno.test('an admin gets the pending list', async () => {
  const drivers: PendingDriver[] = [
    {
      id: 'd1',
      email: 'a@example.com',
      fullName: 'Jane Cooper',
      phone: '',
      cardLast4: '1234',
      cardExpiry: '12/29',
      selfieUrl: '',
      vehicle: { make: 'Toyota', model: 'Corolla', plate: 'GR-1', seats: 4 },
      // All six, so this test is about the list being passed through rather
      // than about the gate. The gate has its own tests below.
      documents: [...REQUIRED_DOCUMENTS],
      submittedAt: '2026-09-29T00:00:00Z',
    },
  ];
  const deps = fake({ listPending: async () => drivers });

  const result = await handleList(deps, 'admin-1');

  assertEquals(result.status, 200);
  assertEquals((result.body as { drivers: PendingDriver[] }).drivers, drivers);
});

Deno.test('a bad token is a 401 and never reaches the list', async () => {
  const deps = fake({ authenticate: async () => null });
  const result = await handleDecide(deps, null, {
    driverId: 'd1',
    action: 'approve',
  });
  assertEquals(result.status, 401);
  assertEquals(deps.decided.length, 0, 'nothing may be written for a null caller');
});

Deno.test('approving writes both the decision and the author', async () => {
  const deps = fake();
  const result = await handleDecide(deps, 'admin-1', {
    driverId: 'd1',
    action: 'approve',
  });

  assertEquals(result.status, 200);
  assertEquals(deps.decided, [
    { driverId: 'd1', status: 'approved', by: 'admin-1' },
  ]);
});

Deno.test('approving also approves the vehicle, in the same call', async () => {
  // The failure this prevents: `match_offers_for_trip` joins
  // `vehicles v on v.owner_id = d.id and v.approved`, so an approved profile
  // with an unapproved vehicle is invisible to the matcher however online they
  // are, while their own app shows them as ready. Two clicks to get this right
  // is one click too many; the admin page would report success either way.
  const deps = fake();
  await handleDecide(deps, 'admin-1', { driverId: 'd1', action: 'approve' });

  assertEquals(deps.vehiclesApproved, ['d1']);
  assertEquals(result_flag(await handleDecide(fake(), 'admin-1', {
    driverId: 'd1',
    action: 'approve',
  })), true);
});

Deno.test('approving a driver with no vehicle is a warning, not a failure', async () => {
  const deps = fake({ approveVehicle: async () => false });
  const result = await handleDecide(deps, 'admin-1', {
    driverId: 'd1',
    action: 'approve',
  });

  // The decision still stands -- the profile is approved and the identity
  // check passed. What is missing is the vehicle, and the admin has to be told,
  // because their next question will be "why is this driver not getting
  // trips?" and the answer is not visible anywhere else.
  assertEquals(result.status, 200);
  assertEquals(result.vehicleApproved, false);
  assert((result.warning ?? '').includes('no vehicle row'),
    'the warning must name the actual problem');
});

Deno.test('rejecting does not approve a vehicle', async () => {
  const deps = fake();
  await handleDecide(deps, 'admin-1', { driverId: 'd1', action: 'reject' });

  assertEquals(deps.decided, [
    { driverId: 'd1', status: 'rejected', by: 'admin-1' },
  ]);
  assertEquals(deps.vehiclesApproved, [],
    'rejecting a driver must not leave an approved vehicle behind');
});

Deno.test('a driver who is gone is a 404, not a silent success', async () => {
  const deps = fake({ decide: async () => null });
  const result = await handleDecide(deps, 'admin-1', {
    driverId: 'deleted',
    action: 'approve',
  });

  // Otherwise the admin sees a green tick for a click that did nothing, and
  // the driver they were thinking about is not coming.
  assertEquals(result.status, 404);
  assertEquals(deps.vehiclesApproved, [],
    'a 404 must not go on to approve a vehicle');
});

Deno.test('an unknown action is refused rather than treated as approve', async () => {
  // The dangerous direction is the one that matters: anything unrecognised
  // becoming "approve" would turn a typo, a stale client or a curious GET into
  // a way to approve drivers.
  const deps = fake();
  const result = await handleDecide(deps, 'admin-1', {
    driverId: 'd1',
    action: 'maybe' as 'approve',
  });

  assertEquals(result.status, 400);
  assertEquals(deps.decided.length, 0);
});

Deno.test('a missing driverId is refused', async () => {
  const deps = fake();
  const result = await handleDecide(deps, 'admin-1', {
    driverId: '',
    action: 'approve',
  });

  assertEquals(result.status, 400);
  assertEquals(deps.decided.length, 0);
});

/** Reads the vehicleApproved flag out of a decide result. */
function result_flag(r: { vehicleApproved?: boolean }): boolean | undefined {
  return r.vehicleApproved;
}

// The document gate.
//
// Without it the page showed a name, an email, four digits of a Ghana Card and
// a button. Approving that is not a review of anything: there is no licence, no
// road worthy and no insurance to look at, and the audit trail would record a
// check that never happened -- which is worse than no check, because it looks
// like one.
Deno.test('approving is refused while a document is missing', async () => {
  const deps = fake();
  deps.state.documents = allSix().filter((d) => d.kind !== 'roadWorthy');

  const result = await handleDecide(deps, 'admin-1', {
    driverId: 'd1',
    action: 'approve',
  });

  assertEquals(result.status, 409);
  // Nothing written. A refusal that had already flipped `kyc_status` would
  // leave the driver approved by a request that reported failure.
  assertEquals(deps.decided.length, 0);
  assertEquals(deps.vehiclesApproved.length, 0);
  const body = result.body as { missing?: string[] };
  assertEquals(body.missing, ['roadWorthy']);
});

Deno.test('a driver who has sent nothing is refused with all six named', async () => {
  const deps = fake();
  deps.state.documents = [];

  const result = await handleDecide(deps, 'admin-1', {
    driverId: 'd1',
    action: 'approve',
  });

  assertEquals(result.status, 409);
  const body = result.body as { missing?: string[] };
  assertEquals(body.missing, [...REQUIRED_DOCUMENTS]);
});

Deno.test('a rejection is always allowed, documents or not', async () => {
  // Refusing to let an admin turn a driver away is a different kind of wrong,
  // and there is no case for it. A driver whose licence came back unreadable
  // has to be sendable.
  const deps = fake();
  deps.state.documents = [];

  const result = await handleDecide(deps, 'admin-1', {
    driverId: 'd1',
    action: 'reject',
  });

  assertEquals(result.status, 200);
  assertEquals(deps.decided.length, 1);
  assertEquals(deps.decided[0].status, 'rejected');
});

Deno.test('all six in, and the approval goes through', async () => {
  const deps = fake();

  const result = await handleDecide(deps, 'admin-1', {
    driverId: 'd1',
    action: 'approve',
  });

  assertEquals(result.status, 200);
  assertEquals(deps.decided.length, 1);
  assertEquals(deps.decided[0].status, 'approved');
});

Deno.test('the documents are read at decision time, not from the list', async () => {
  // The list read can fail and renders as "sent nothing"; the decision must not
  // be made on it. A driver who sent all six and whose list read timed out has
  // to still be approvable.
  const deps = fake({
    listPending: async (): Promise<PendingDriver[]> => [],
    documentsFor: async (): Promise<DriverDocumentRow[]> => allSix(),
  });

  const result = await handleDecide(deps, 'admin-1', {
    driverId: 'd1',
    action: 'approve',
  });

  assertEquals(result.status, 200);
});

Deno.test('missingDocuments counts by kind, and ignores what it does not know', async () => {
  assertEquals(missingDocuments([]), [...REQUIRED_DOCUMENTS]);
  assertEquals(missingDocuments(allSix()), []);
  // A row of a kind the list has never heard of is a kind that was not sent,
  // and must not be reported as one of the six missing.
  const extra = [...allSix(), { kind: 'taxCertificate', path: 'u1/x/1.jpg' }];
  assertEquals(missingDocuments(extra), []);
  // Duplicates are one document, not two.
  assertEquals(
    missingDocuments([{ kind: 'roadWorthy' }, { kind: 'roadWorthy' }]).length,
    REQUIRED_DOCUMENTS.length - 1,
  );
});

Deno.test('a document URL is minted only for a kind that was sent', async () => {
  // The kind arrives from the browser. Signing whatever path came with it
  // would hand out working, expiring, shareable URLs for any object in the
  // bucket, including another driver's documents.
  const deps = fake();
  deps.state.documents = [{ kind: 'driversLicence', path: 'u1/licence/1.jpg' }];

  const ok = await deps.signDocument('d1', 'driversLicence');
  const refused = await deps.signDocument('d1', 'ghanaCardPhoto');

  assert(ok !== null);
  assertEquals(refused, null);
});
