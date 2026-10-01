// A driver withdraws from a trip they have not picked the rider up from yet.
//
//   POST /functions/v1/leave-trip
//   { "tripId": "<uuid>", "reason": "optional, up to 300 characters" }
//
// ## Why this exists separately from `cancel-trip`
//
// `cancel-trip` refuses a driver, and it is right to. Everything it does is
// calibrated for the rider: a two-minute free window, GHS 5.00 to a driver who
// has been held up past it, and `driver_id` deliberately left on the row so the
// driver's history keeps the trip.
//
// None of that applies here. The rider still wants a ride. The driver is not being
// compensated, they are being released. So this is a different function with
// different rules rather than a branch on that one, and the rider's rules are left
// exactly as they were.
//
// ## The one rule that is not negotiable
//
// A driver may withdraw while `arriving` and may not while `ongoing`.
//
// `arriving` means driving towards a pickup. `ongoing` means the rider is in the
// car. "Leaving" a trip with somebody in the vehicle is stranding them, and no
// reason string in the body should be able to authorise it -- which is why the
// check is on the state the database holds, not on anything sent.
//
// `requested` and `matched` are refused too, and for a different reason: there is
// nothing to withdraw from, because the driver does not have this trip yet. That
// is the case where `offers/decline` applies.
//
// ## What happens to the trip
//
// Back to `requested`, not `cancelled`. The rider asked for a ride and has not
// got it; cancelling because the driver's car was wrong for the street ends a
// journey nobody meant to end. `requested` lets the matcher run again.
//
// And `trip_withdrawals` records who withdrew, because
// `match_offers_for_trip` has no memory and would otherwise offer the trip
// straight back to the driver who just walked away from it.
//
// ## Ports, not a client
//
// Same shape as `cancel-trip`: `buildDeps` turns the service client into the
// ports below, so the rules here are testable without a Supabase client and this
// file stays short enough to read. Every port is on the service key rather than
// the caller's own credential, because none of these tables permits a client to
// write them -- `trip_withdrawals` has no policy at all, and the trip state change
// has to be conditional on the state it is changing away from.

import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { handleLeave, type LeaveDeps } from './handler.ts';
import { buildDeps, buildService } from './clients.ts';

serve((req) => handleLeave(req, buildDeps(buildService())));