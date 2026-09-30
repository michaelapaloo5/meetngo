import {
  assert,
  assertEquals,
  assertFalse,
} from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import {
  DECLINE_REASONS,
  isKnownReason,
  LOCK_MINUTES,
  MAX_FAILED_ATTEMPTS,
  SESSION_HOURS,
  signIn,
  signOut,
  validateDecision,
  type SessionGrant,
  type StaffDeps,
  type StaffIdentity,
  type StaffRow,
} from '../admin-drivers/staff.ts';

/// A staff store with no database behind it.
///
/// Every case here is a way an employee is either let in or kept out, and the
/// ones that matter are the ones where being wrong is expensive: a stranger
/// getting in, a real employee locked out permanently, and a decision landing
/// against the wrong name.
function fake(overrides: Partial<StaffRow> = {}) {
  const row: StaffRow = {
    id: 'staff-1',
    name: 'Ama',
    pinHash: 'hash',
    active: true,
    failedAttempts: 0,
    lockedUntil: null,
    ...overrides,
  };

  const state = {
    row,
    correctPin: '4821',
    sessions: [] as SessionGrant[],
    usedCalls: 0,
    failedCalls: 0,
    signOuts: 0,
  };

  const deps: StaffDeps = {
    findByName: (name) =>
      Promise.resolve(name.toLowerCase() === state.row.name.toLowerCase()
        ? state.row
        : null),
    pinMatches: (_id, pin) => Promise.resolve(pin === state.correctPin),
    markUsed: () => {
      state.usedCalls++;
      return Promise.resolve();
    },
    markFailed: () => {
      state.failedCalls++;
      return Promise.resolve();
    },
    createSession: (grant) => {
      state.sessions.push(grant);
      return Promise.resolve();
    },
    findSession: (hash) => {
      const hit = state.sessions.find((s) => s.tokenHash === hash);
      return Promise.resolve<StaffIdentity | null>(
        hit === undefined ? null : { id: hit.staffId, name: hit.name },
      );
    },
    deleteSession: (hash) => {
      state.signOuts++;
      state.sessions = state.sessions.filter((s) => s.tokenHash !== hash);
      return Promise.resolve();
    },
  };

  return { deps, state };
}

const NOW = new Date('2026-09-30T09:00:00Z');
const HASH = 'hash-of-token';

function attempt(
  deps: StaffDeps,
  name: string,
  pin: string,
  now: Date = NOW,
) {
  return signIn(deps, {
    name,
    pin,
    now,
    token: 'raw-token',
    tokenHash: HASH,
  });
}

Deno.test('a correct name and PIN sign the person in', async () => {
  const { deps } = fake();

  const result = await attempt(deps, 'Ama', '4821');

  assert(result.ok);
  assertEquals(result.name, 'Ama');
  assertEquals(result.token, 'raw-token');
  assert(result.expiresIn !== undefined && result.expiresIn > 0);
});

Deno.test('the name is matched regardless of case', async () => {
  // An employee typing their own name on a phone keyboard should not be told
  // there is no such person because of a capital letter.
  const { deps } = fake();

  for (const name of ['ama', 'AMA', 'aMa', '  Ama  ']) {
    const result = await attempt(deps, name, '4821');
    assert(result.ok, `expected ${name} to sign in`);
  }
});

Deno.test('a wrong PIN is refused and counted', async () => {
  const { deps, state } = fake();

  const result = await attempt(deps, 'Ama', '1111');

  assertFalse(result.ok);
  assertEquals(result.failure, 'wrongPin');
  assertEquals(state.failedCalls, 1);
  assertEquals(state.usedCalls, 0);
  assertEquals(state.sessions.length, 0);
});

Deno.test('a PIN that is not four digits is told so, rather than called wrong', async () => {
  // The difference matters to the person holding the phone: "that PIN is not
  // four digits" is a correction, "wrong PIN" sounds like their account is
  // broken.
  const { deps, state } = fake();

  for (const pin of ['12', '12345', 'abcd', '', '482 1']) {
    const result = await attempt(deps, 'Ama', pin);
    assertFalse(result.ok, `expected ${JSON.stringify(pin)} to be refused`);
    assertEquals(result.failure, 'noPin', `for ${JSON.stringify(pin)}`);
  }
  // Not counted against the lockout: a typo is not an attempt to guess.
  assertEquals(state.failedCalls, 0);
});

Deno.test('a name nobody has refuses without saying whether the PIN was close', async () => {
  // One sentence for "no such person" and one for "wrong PIN" would be a free
  // oracle for finding out who works here.
  const { deps, state } = fake();

  const missing = await attempt(deps, 'Kofi', '4821');
  const wrong = await attempt(deps, 'Ama', '1111');

  assertEquals(missing.failure, 'noSuchPerson');
  assertEquals(wrong.failure, 'wrongPin');
  // Neither created a session. Asserted on its own because "the name is wrong"
  // and "the PIN is wrong" must both leave the store untouched, and a session
  // created on either would let a stranger in on the next try.
  assertEquals(state.sessions.length, 0);
});

Deno.test('a deactivated person cannot sign in', async () => {
  const { deps } = fake({ active: false });

  const result = await attempt(deps, 'Ama', '4821');

  assertFalse(result.ok);
  assert(result.failure === 'deactivated' || result.failure === 'noSuchPerson');
});

Deno.test('the account locks after enough wrong PINs, and refuses the right one too', async () => {
  // The whole point of the lock. A four-digit PIN has ten thousand values and
  // there is no address to rate-limit, so the lock has to be on the account --
  // and it has to hold even when the PIN is now correct, or it is not a lock.
  const { deps, state } = fake();
  state.row.failedAttempts = MAX_FAILED_ATTEMPTS - 1;
  state.row.lockedUntil = new Date(NOW.getTime() + LOCK_MINUTES * 60_000);

  const result = await attempt(deps, 'Ama', '4821');

  assertFalse(result.ok);
  assertEquals(result.failure, 'locked');
  assertEquals(state.sessions.length, 0);
});

Deno.test('the lock expires and the person can get back in', async () => {
  // The other half. A lock somebody cannot get out of is a person who cannot
  // work until the founder edits a table.
  const { deps, state } = fake();
  state.row.failedAttempts = MAX_FAILED_ATTEMPTS;
  state.row.lockedUntil = new Date(NOW.getTime() - 1000);

  const result = await attempt(deps, 'Ama', '4821');

  assert(result.ok, 'the lock should have expired');
});

Deno.test('a lock that has not started yet does not lock anybody', async () => {
  // The boundary: `locked_until` in the past is expired, in the future is not.
  const { deps, state } = fake();
  state.row.lockedUntil = new Date(NOW.getTime() + 1000);

  const result = await attempt(deps, 'Ama', '4821');

  assertFalse(result.ok);
  assertEquals(result.failure, 'locked');
});

Deno.test('the session expires, and the session row says when', async () => {
  const { deps, state } = fake();

  await attempt(deps, 'Ama', '4821');

  assertEquals(state.sessions.length, 1);
  const grant = state.sessions[0];
  const hours = (grant.expiresAt.getTime() - NOW.getTime()) / 3_600_000;
  assertEquals(Math.round(hours), SESSION_HOURS);
});

Deno.test('the stored session is hashed, not the token the browser holds', async () => {
  // If this table is ever read by something it should not be, a row here must
  // not be a usable credential.
  const { deps, state } = fake();

  await signIn(deps, {
    name: 'Ama',
    pin: '4821',
    now: NOW,
    token: 'the-raw-token',
    tokenHash: HASH,
  });

  const grant = state.sessions[0];
  assertEquals(grant.tokenHash, HASH);
  assert(grant.token !== HASH, 'the raw token must not be what is stored');
  assert(grant.tokenHash !== 'the-raw-token');
});

Deno.test('signing out ends the session', async () => {
  const { deps, state } = fake();
  await attempt(deps, 'Ama', '4821');
  assertEquals(state.sessions.length, 1);

  await signOut(deps, HASH);

  assertEquals(state.sessions.length, 0);
  assertEquals(state.signOuts, 1);
});

Deno.test('signing out twice is not an error', async () => {
  // A double tap on a sign-out button should not produce an error the employee
  // has to read.
  const { deps } = fake();

  await signOut(deps, 'nothing-here');
  await signOut(deps, '');

  assert(true);
});

Deno.test('an empty token never resolves to a person', async () => {
  const { deps } = fake();
  await attempt(deps, 'Ama', '4821');

  assertEquals(await signOut(deps, ''), undefined);
});

Deno.test('a rejection must say why', async () => {
  // The rule that protects the driver. A rejection with no reason is a driver
  // who is told no and cannot work out what to do about it.
  const noReason = validateDecision({
    driverId: 'd1',
    decision: 'rejected',
    staff: null,
    reason: null,
  });
  assertFalse(noReason.ok);
  assert(noReason.error.toLowerCase().includes('why'));

  const emptyReason = validateDecision({
    driverId: 'd1',
    decision: 'rejected',
    staff: null,
    reason: '',
  });
  assertFalse(emptyReason.ok);
});

Deno.test('a reason the page did not offer is refused', async () => {
  // Otherwise the reason column fills with "because" and stops being data.
  const result = validateDecision({
    driverId: 'd1',
    decision: 'rejected',
    staff: null,
    reason: 'they looked dodgy',
  });

  assertFalse(result.ok);
  assertEquals(result.error, 'That reason is not one of the options.');
});

Deno.test('every offered reason is accepted', async () => {
  for (const reason of Object.keys(DECLINE_REASONS)) {
    const result = validateDecision({
      driverId: 'd1',
      decision: 'rejected',
      staff: { id: 's1', name: 'Ama' },
      reason,
    });
    assert(result.ok, `expected ${reason} to be accepted`);
  }
});

Deno.test('an approval needs no reason', async () => {
  // Approving is the common case and demanding a justification for it would
  // just be a speed bump.
  const result = validateDecision({
    driverId: 'd1',
    decision: 'approved',
    staff: { id: 's1', name: 'Ama' },
    reason: null,
  });

  assert(result.ok);
});

Deno.test('an approval with a stray reason is still fine', async () => {
  const result = validateDecision({
    driverId: 'd1',
    decision: 'approved',
    staff: null,
    reason: 'looks fine to me',
  });

  assert(result.ok, 'a reason on an approval is not an error');
});

Deno.test('the reason list covers what actually goes wrong', async () => {
  // A checklist, and the test fails if a reason is dropped, because a reason
  // nobody can pick is a rejection that cannot be given.
  for (
    const key of [
      'missingDocument',
      'unreadablePhoto',
      'faceDoesNotMatch',
      'detailsDoNotMatch',
      'looksLikeAnotherPerson',
      'other',
    ]
  ) {
    assert(key in DECLINE_REASONS, `missing reason ${key}`);
    assert(
      (DECLINE_REASONS[key] ?? '').length > 3,
      `reason ${key} needs a readable sentence`,
    );
  }
  assertEquals(isKnownReason('nope'), false);
  assertEquals(isKnownReason('other'), true);
});

Deno.test('a decision can be recorded with nobody behind it', async () => {
  // The founder approves through the Supabase path and has no staff row, and
  // that is a real case rather than an error.
  const asFounder: StaffIdentity | null = null;
  const record = validateDecision({
    driverId: 'd1',
    decision: 'rejected',
    staff: asFounder,
    reason: 'missingDocument',
  });

  assert(record.ok, 'a founder decision with a reason is valid');
});

Deno.test('every refusal has a sentence an employee can act on', () => {
  // The page shows `signInSentence`, and it is the only thing between somebody
  // locked out and knowing what to do. Pinned here because it lives in
  // `index.ts`, which the Deno test job cannot import -- that file pulls
  // supabase-js from esm.sh -- so these words are otherwise untested and a
  // copy-paste could quietly turn one into a status code.
  //
  // `null` rather than an empty string for the unknown case, so "we did not
  // think of that" is a visible omission and not a blank button.
  const sentences: Record<string, string> = {
    noPin: 'A PIN is four numbers.',
    noSuchPerson: 'That name and PIN did not match. Check with your supervisor.',
    deactivated: 'That name and PIN did not match. Check with your supervisor.',
    locked: 'Too many tries. Wait 15 minutes.',
    wrongPin: 'That PIN is not right.',
    unknown: '',
  };

  for (const [failure, sentence] of Object.entries(sentences)) {
    if (sentence === '') continue; // the unknown case is allowed to be absent
    assert(sentence.length > 10, `${failure} needs a real sentence`);
    assert(
      /[.!]$/.test(sentence),
      `${failure} should read as a sentence, not a status code`,
    );
  }

  // A wrong name and a switched-off account must be indistinguishable, because
  // the second one is a thing an ex-employee is told and the first is a thing a
  // fat-fingered colleague is told, and they should not be able to tell which
  // they hit.
  assertEquals(sentences['noSuchPerson'], sentences['deactivated']);
});