-- Let a driver put a trip back in the pool.
--
-- The withdrawal rules are in `supabase/functions/leave-trip/`, and they are
-- correct. What they could not do was work: `returnToRequested` moves the trip
-- `arriving -> requested`, and `enforce_trip_transition` refuses that pair, so the
-- function answered 500 with `illegal trip transition arriving -> requested` and
-- the driver saw "Leaving a trip is not available right now".
--
-- Found by deploying the function and running `toolchain/verify-leave-trip.mjs`,
-- whose section 2 had been skipping itself while the function was absent. It
-- skipped for the best reason available -- a 404 proves nothing -- and it failed
-- for the worst reason available: the code was right and the database was not.
--
-- Why only this one pair, and not `matched -> requested`:
--
--   `arriving -> requested` is a driver abandoning a trip they have started to
--   drive towards. `leave-trip` allows exactly this, and it is the only path that
--   re-pools a trip without cancelling it.
--
--   `matched -> requested` is deliberately left illegal. A driver who has been
--   matched but has not moved has not *left* anything, and the control for that
--   is declining the offer (`offers/decline`), which does not put the trip through
--   the transition guard at all. Allowing the pair here would add a second,
--   quieter way for the same thing to happen, reachable by a client that skipped
--   the offer flow.
--
-- `create or replace function` is safe here: the trigger function's signature and
-- return type are both unchanged, so this is a body swap and the trigger keeps
-- firing without being dropped and recreated.

create or replace function enforce_trip_transition()
returns trigger
language plpgsql
as $$
begin
  -- The self-transition note from the original is still true and is not repeated
  -- in detail: a no-op update naming `state` in its SET clause must still raise.
  if not (
    (old.state = 'requested' and new.state in ('matched','cancelled')) or
    (old.state = 'matched'    and new.state in ('arriving','cancelled')) or
    (old.state = 'arriving'   and new.state in ('ongoing','cancelled','requested')) or
    (old.state = 'ongoing'    and new.state = 'completed')
  ) then
    raise exception 'illegal trip transition % -> %', old.state, new.state;
  end if;
  return new;
end;
$$;