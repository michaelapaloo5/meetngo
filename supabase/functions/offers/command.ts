// The request body, parsed and checked, in its own file so the refusals are
// unit-testable the way request-ride/request.ts is.

export type OfferAction = 'accept' | 'decline';

const ACTIONS: readonly OfferAction[] = ['accept', 'decline'];

// `offers.id` is `uuid primary key` (migration:78), and the id goes straight
// into a PostgREST equality filter. A value that is not a uuid is refused here
// rather than sent: PostgREST answers it with 400 "invalid input syntax for
// type uuid", which the handler would report as a 500, so a client typo would
// read as a server fault. The empty string is not a special case and gets the
// same message, because it is not a uuid either.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface OfferCommand {
  action: OfferAction;
  offerId: string;
}

export type OfferCommandResult =
  | { ok: true; value: OfferCommand }
  | { ok: false; error: string };

const refuse = (error: string): OfferCommandResult => ({ ok: false, error });

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

// Both fields are checked, and the action is checked against the two values it
// may take rather than tested for 'decline'. Testing only for 'decline' sends
// every other value down the accept path, so a client that sends 'accept' with
// a typo, 'delete', or no action at all, has its offer accepted on the caller's
// behalf. That is the one failure in this function that cannot be undone by the
// driver, since the trip is already `matched` by the time anyone notices.
//
// A wrong-typed field is a 400 here for the same reason it is in
// `parseRideRequest`: refusing is visible, and dropping or coercing it is not.
// Unknown extra fields are left alone, because a field this function does not
// read cannot change what it does, and refusing them would break a client that
// adds one.
export function parseOfferCommand(body: unknown): OfferCommandResult {
  if (!isRecord(body)) return refuse('body must be a JSON object');

  const { action, offerId } = body;
  if (typeof action !== 'string' || !ACTIONS.includes(action as OfferAction)) {
    return refuse(`action must be one of ${ACTIONS.join(', ')}`);
  }
  if (typeof offerId !== 'string') return refuse('offerId must be a string');
  if (!UUID.test(offerId)) return refuse('offerId must be a uuid');

  return { ok: true, value: { action: action as OfferAction, offerId } };
}
