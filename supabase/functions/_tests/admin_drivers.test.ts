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
  type AdminDeps,
  type PendingDriver,
} from '../admin-drivers/handler.ts';

function fake(overrides: Partial<AdminDeps> = {}) {
  // The counters live beside the fake rather than inside the returned object,
  // because attaching them with `Object.assign` would erase the contextual
  // types on the methods below and every parameter would become an implicit
  // `any`. Typed here for the same reason: the point of the cast is that these
  // are the shapes `AdminDeps` declares.
  const listed: { count: number } = { count: 0 };
  const decided: { driverId: string; status: string; by: string }[] = [];
  const vehiclesApproved: string[] = [];

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
        submittedAt: '',
      };
    },
    approveVehicle: async (driverId: string): Promise<boolean> => {
      vehiclesApproved.push(driverId);
      return true;
    },
    ...overrides,
  };

  return Object.assign(base, {
    get listed() {
      return listed.count;
    },
    decided,
    vehiclesApproved,
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
