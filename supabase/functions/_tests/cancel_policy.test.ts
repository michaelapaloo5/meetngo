import { assertEquals } from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import {
  cancellationCompensationGhs,
  isTripStateName,
  type TripStateName,
} from '../cancel-trip/policy.ts';

Deno.test('cancel while requested is free', () => {
  assertEquals(cancellationCompensationGhs({ state: 'requested', elapsedMs: 1_000 }), 0);
});

Deno.test('cancel_after_arriving_compensates_driver_test', () => {
  assertEquals(
    cancellationCompensationGhs({ state: 'arriving', elapsedMs: 6 * 60 * 1000 }),
    5.0,
  );
});

Deno.test('cancel while ongoing is not rider-cancellable', () => {
  assertEquals(cancellationCompensationGhs({ state: 'ongoing', elapsedMs: 10 * 60 * 1000 }), -1);
});

Deno.test('terminal states are not cancellable', () => {
  assertEquals(cancellationCompensationGhs({ state: 'completed', elapsedMs: 1_000 }), -1);
  assertEquals(cancellationCompensationGhs({ state: 'cancelled', elapsedMs: 1_000 }), -1);
});

Deno.test('matched inside the free window costs nothing', () => {
  assertEquals(
    cancellationCompensationGhs({ state: 'matched', elapsedMs: 60 * 1000 }),
    0,
  );
});

Deno.test('matched after the free window compensates the driver', () => {
  assertEquals(
    cancellationCompensationGhs({ state: 'matched', elapsedMs: 3 * 60 * 1000 }),
    5.0,
  );
});

Deno.test('exactly at the free window boundary is still free', () => {
  assertEquals(
    cancellationCompensationGhs({ state: 'matched', elapsedMs: 120_000 }),
    0,
  );
});

Deno.test('a millisecond past the boundary compensates', () => {
  assertEquals(
    cancellationCompensationGhs({ state: 'matched', elapsedMs: 120_001 }),
    5.0,
  );
});

// The policy function's own guard for a state the union does not name. The
// `trip_state` enum has exactly six values (`init.sql:4-5`), so this is not
// reachable from the database today; it is reachable from a caller that casts,
// and the branch it pins is the difference between refusing a cancellation and
// paying a driver for one nobody checked.
Deno.test('a state the union does not name is refused, not compensated', () => {
  assertEquals(
    cancellationCompensationGhs({
      state: 'expired' as TripStateName,
      elapsedMs: 1_000,
    }),
    -1,
  );
  assertEquals(
    cancellationCompensationGhs({
      state: 'expired' as TripStateName,
      elapsedMs: 10 * 60 * 1000,
    }),
    -1,
  );
});

Deno.test('isTripStateName accepts the six enum values and nothing else', () => {
  for (const name of [
    'requested',
    'matched',
    'arriving',
    'ongoing',
    'completed',
    'cancelled',
  ]) {
    assertEquals(isTripStateName(name), true, name);
  }
  assertEquals(isTripStateName('expired'), false);
  assertEquals(isTripStateName(''), false);
  assertEquals(isTripStateName(null), false);
  assertEquals(isTripStateName(undefined), false);
  assertEquals(isTripStateName(3), false);
});
