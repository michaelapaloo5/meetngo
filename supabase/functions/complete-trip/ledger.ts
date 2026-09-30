export interface Settlement {
  fareGhs: number;
  commissionGhs: number;
  driverPayoutGhs: number;
}

const round2 = (v: number) => Math.round(v * 100) / 100;

/**
 * The fare off a `trips` row, or null when the row does not carry a finite one.
 *
 * `fare_ghs` is `numeric(10,2) not null` (`init.sql:61`), and PostgREST
 * serialises a `numeric` as a JSON **number** -- which is the shape
 * `apps/rider/test/data/trip_json_test.dart` is written by hand against. It is
 * still read and checked rather than coerced, because the coercion the brief
 * used (`Number(trip.fare_ghs)`) is not the identity on a row that has been
 * damaged: `Number(null)` is 0 and `Number(undefined)` is NaN, so a row that
 * lost its fare settled as `GHS 0.00` and a row that carried a string settled
 * as whatever that string parsed to. Both read as a real fare and neither is
 * one, and this is the money path.
 *
 * One definition, used by both functions: `demo-pay` writes the fare the
 * `complete-trip` settlement will charge, so it has to read it the same way.
 */
export function readFareGhs(row: { fare_ghs?: unknown }): number | null {
  const raw = row.fare_ghs;
  return typeof raw === 'number' && Number.isFinite(raw) ? raw : null;
}

export function settleFare(fareGhs: number, commissionRate = 0.15): Settlement {
  // Math.max(0, NaN) is NaN, so an unguarded non-finite fare would write NaN
  // into numeric(10,2). A corrupt fare settles as zero rather than as NaN.
  if (!Number.isFinite(fareGhs)) {
    throw new TypeError(`fareGhs must be finite, got ${fareGhs}`);
  }
  if (!Number.isFinite(commissionRate)) {
    throw new TypeError(`commissionRate must be finite, got ${commissionRate}`);
  }
  const fare = Math.max(0, round2(fareGhs));
  const commission = round2(fare * commissionRate);
  return {
    fareGhs: fare,
    commissionGhs: commission,
    driverPayoutGhs: round2(Math.max(0, fare - commission)),
  };
}

export function settleAgainstTripState(input: {
  tripState: string;
  paymentState: string;
  settlement: Settlement;
}): { shouldCharge: boolean; paymentState: 'pending' | 'succeeded' | 'voided'; ledgerKinds: string[] } {
  // A cancelled trip can never be charged. The pending charge is voided and
  // the driver sees a void entry rather than a fare.
  if (input.tripState === 'cancelled' || input.paymentState === 'voided') {
    return { shouldCharge: false, paymentState: 'voided', ledgerKinds: ['void'] };
  }
  if (input.tripState !== 'completed') {
    return { shouldCharge: false, paymentState: 'pending', ledgerKinds: [] };
  }
  // A completed trip whose payment is **already** succeeded is a repeat call,
  // and charging it again writes a second `fare` entry and a second `payouts`
  // row against the same `trip_id`: neither table carries a unique constraint
  // on trip (`init.sql:112-130`), so the duplicate is accepted, and
  // `ledger_entries` is the only per-trip record a driver has of what they are
  // owed (`own ledger` is a SELECT policy, `init.sql:553-554`), so the fare is
  // then counted twice. Nothing makes the call once: a double tap on the
  // receipt, or a client that retries a call whose response was lost, both
  // re-enter this function.
  //
  // This is the same guard the void branch above already has, one level up: the
  // void path is idempotent because `complete-trip`'s handler re-reads the
  // payment and only voids a row whose state is not already `voided`, and the
  // charge path had no such check. The residual, stated rather than hidden: if
  // the payment write succeeds and the ledger write then fails, the trip is
  // left settled and the driver unpaid, and this guard is what keeps the retry
  // from paying twice rather than what makes the retry pay. Closing that
  // properly needs the payment write and the two money writes in one
  // transaction, and this build has no RPC for it. Task 18's runbook owns the
  // live check.
  if (input.paymentState === 'succeeded') {
    return { shouldCharge: false, paymentState: 'succeeded', ledgerKinds: [] };
  }
  // The launch promo settles at a 0% rate, and a `commission` entry of 0.00 is
  // not a neutral no-op: it is a line on the driver's own statement reading
  // "commission GH¢0.00" beside a fare they kept in full, which reads as an
  // account that was meant to be charged and escaped it. The kinds come from
  // the money, not from the state -- `['fare', 'commission']` on every charge
  // was right when every charge took a commission, and is wrong now that some
  // take none.
  const charged = input.settlement.commissionGhs > 0;
  return {
    shouldCharge: true,
    paymentState: 'succeeded',
    ledgerKinds: charged ? ['fare', 'commission'] : ['fare'],
  };
}
