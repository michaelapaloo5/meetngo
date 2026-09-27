export type TripStateName =
  | 'requested'
  | 'matched'
  | 'arriving'
  | 'ongoing'
  | 'completed'
  | 'cancelled';

export const FREE_CANCEL_WINDOW_MS = 2 * 60 * 1000;
export const DRIVER_CANCELLATION_FEE_GHS = 5.0;

const TRIP_STATE_NAMES = [
  'requested',
  'matched',
  'arriving',
  'ongoing',
  'completed',
  'cancelled',
] as const;

/**
 * Narrows the `trips.state` value off a PostgREST read, which arrives as `any`
 * because this client carries no generated `Database` type. `state` is the one
 * column the policy below branches on and the one column whose value decides
 * whether a trip is cancelled and a driver is paid, so it is checked rather
 * than cast: `cancellationCompensationGhs` takes the union, and `as never` at
 * the call site would let any value through the type checker while telling it
 * nothing.
 */
export function isTripStateName(value: unknown): value is TripStateName {
  return TRIP_STATE_NAMES.some((name) => name === value);
}

/**
 * Returns 0 when the rider cancels for free, DRIVER_CANCELLATION_FEE_GHS when
 * the driver has already committed and must be compensated, and -1 when the
 * trip state is not rider-cancellable at all.
 */
export function cancellationCompensationGhs(input: {
  state: TripStateName;
  elapsedMs: number;
}): number {
  switch (input.state) {
    case 'requested':
      // No driver is attached, so there is nobody to hold up.
      return 0;
    case 'matched':
    case 'arriving':
      // matched or arriving: free while no driver has been held up.
      return input.elapsedMs <= FREE_CANCEL_WINDOW_MS
        ? 0
        : DRIVER_CANCELLATION_FEE_GHS;
    case 'ongoing':
    case 'completed':
    case 'cancelled':
      return -1;
    default:
      // A state this function does not know is not a state it may cancel, so
      // it is refused rather than treated as `matched` or `arriving`. The
      // brief's trailing `return` had no such arm, so an unrecognised value
      // fell into the compensation branch: the trip was cancelled and the
      // driver paid for a state nobody had checked. `trip_state` is a six-value
      // enum today (`init.sql:4-5`) and the `isTripStateName` guard in
      // `index.ts` refuses one before it reaches here, so this arm is the
      // second of two refusals rather than the only one.
      return -1;
  }
}
