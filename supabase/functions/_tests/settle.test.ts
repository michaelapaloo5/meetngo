import {
  assertEquals,
  assertThrows,
} from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import { settleAgainstTripState, settleFare } from '../complete-trip/ledger.ts';

Deno.test('platform takes 15 percent of the fare', () => {
  const s = settleFare(20.4);
  assertEquals(s.fareGhs, 20.4);
  assertEquals(s.commissionGhs, 3.06);
  assertEquals(s.driverPayoutGhs, 17.34);
});

Deno.test('commission rate is configurable', () => {
  assertEquals(settleFare(100, 0.2).driverPayoutGhs, 80);
});

Deno.test('settlement on a completed trip charges the rider', () => {
  const r = settleAgainstTripState({
    tripState: 'completed',
    paymentState: 'pending',
    settlement: settleFare(20.4),
  });
  assertEquals(r.shouldCharge, true);
  assertEquals(r.paymentState, 'succeeded');
  assertEquals(r.ledgerKinds, ['fare', 'commission']);
});

Deno.test('settle_cancelled_trip_voids_payment_test', () => {
  const r = settleAgainstTripState({
    tripState: 'cancelled',
    paymentState: 'pending',
    settlement: settleFare(20.4),
  });
  assertEquals(r.shouldCharge, false);
  assertEquals(r.paymentState, 'voided');
  assertEquals(r.ledgerKinds, ['void']);
});

Deno.test('settling an already-voided payment changes nothing', () => {
  const r = settleAgainstTripState({
    tripState: 'cancelled',
    paymentState: 'voided',
    settlement: settleFare(20.4),
  });
  assertEquals(r.shouldCharge, false);
  assertEquals(r.paymentState, 'voided');
});

Deno.test('an ongoing trip cannot be settled', () => {
  const r = settleAgainstTripState({
    tripState: 'ongoing',
    paymentState: 'pending',
    settlement: settleFare(20.4),
  });
  assertEquals(r.shouldCharge, false);
  assertEquals(r.paymentState, 'pending');
});

Deno.test('a non-finite fare is refused rather than settled as NaN', () => {
  // Math.max(0, NaN) is NaN, and numeric(10,2) accepts a NaN written by a
  // privileged role, so an unguarded fare reaches the ledger as NaN.
  assertThrows(() => settleFare(Number.NaN), TypeError);
  assertThrows(() => settleFare(Number.POSITIVE_INFINITY), TypeError);
  assertThrows(() => settleFare(20.4, Number.NaN), TypeError);
});

Deno.test('a settlement never leaves the zero-to-fare band', () => {
  for (const fare of [0, 0.01, 0.05, 6, 20.4, 20.42, 33.33, 112221, -5]) {
    for (const rate of [0.15, 0.2, 0, 1]) {
      const s = settleFare(fare, rate);
      assertEquals(s.fareGhs >= 0, true, `fare ${fare} rate ${rate}`);
      assertEquals(
        s.driverPayoutGhs >= 0 && s.driverPayoutGhs <= s.fareGhs,
        true,
        `payout ${s.driverPayoutGhs} outside 0..${s.fareGhs} at fare ${fare} rate ${rate}`,
      );
    }
  }
});

Deno.test('zero fare still settles without negative commission', () => {
  const s = settleFare(0);
  assertEquals(s.commissionGhs, 0);
  assertEquals(s.driverPayoutGhs, 0);
});
