-- Let a driver withdraw from a trip they have not picked the rider up from yet.
--
-- ## Why this is a new capability rather than a branch on `cancel-trip`
--
-- `cancel-trip` refuses a driver outright -- `if (row.rider_id !== userId) return
-- json(403, { error: 'not your trip' })` -- and that refusal is correct. Everything
-- that function does is calibrated for the rider: the two-minute free window, the
-- GHS 5.00 compensation for a driver who has been held up, and the note that
-- `driver_id` is deliberately left on the row so the driver's history keeps the
-- trip.
--
-- A driver withdrawing is a different act and none of that applies to it. The
-- rider still wants a ride. The driver is not being compensated; they are being
-- released. And a driver must be able to do it at all, because today the only
-- thing a driver can do with a trip that is not going ahead is sit in it.
--
-- So: a separate table here, a separate function in the Edge Function layer, and
-- the rider's rules left exactly as they were.
--
-- ## What happens to the trip
--
-- Back to `requested`, not `cancelled`.
--
-- The rider asked for a ride and has not got it. Cancelling would end their
-- journey because the driver's car was wrong for the street, which is not a
-- cancellation anybody meant. Returning it to `requested` lets the matcher run
-- again and offer it to the next driver.
--
-- ## Why the withdrawal has to be recorded
--
-- Because `match_offers_for_trip` has no memory. Its conditions are role,
-- `kyc_status`, availability, an approved vehicle of the right category, a known
-- location, and a pickup within 5 km -- so a trip put back to `requested` is
-- offered straight back to the driver who just walked away from it, and the whole
-- feature becomes a way to make a rider wait.
--
-- So `trip_withdrawals` is the memory, and the last change below reads it. A
-- driver may be matched to a trip once. Having withdrawn from it is not a
-- temporary state that ends when somebody else takes it; it is a fact about that
-- driver and that rider.

create table if not exists trip_withdrawals (
  id uuid primary key default uuid_generate_v4(),

  -- Both cascade. A withdrawal is a fact about one driver and one trip; if
  -- either ceases to exist there is nothing left for the row to mean, and leaving
  -- it behind would make `match_offers_for_trip` consult a trip that is not there.
  trip_id uuid not null references trips on delete cascade,
  driver_id uuid not null references profiles on delete cascade,

  -- Free text, like `left_item_reports.item`. A picklist is a migration every
  -- time somebody declines for a reason nobody predicted, and the only person who
  -- reads these is trying to work out whether Accra needs a different set of
  -- pickup instructions or whether a particular driver needs a word.
  reason text not null default '' check (char_length(reason) <= 300),

  created_at timestamptz not null default now(),

  -- One withdrawal per driver per trip. A driver who changes their mind and then
  -- changes it back is one driver who withdrew, and two rows would let the second
  -- delete the first's memory of it.
  constraint trip_withdrawals_one_per_driver unique (trip_id, driver_id)
);

-- The matcher's lookup is `where trip_id = <the trip> and driver_id = <the
-- driver>` for every candidate driver on every match, so this is the index that
-- turns an exclusion from a sequential scan of the driver's whole withdrawal
-- history into a lookup.
create index if not exists trip_withdrawals_trip_driver_idx
  on trip_withdrawals (trip_id, driver_id);

-- Row level security with no policies at all.
--
-- Not an oversight. Nothing a client does reads or writes this table: the
-- `leave-trip` function writes it with `service_role`, and the matcher reads it
-- inside a `security definer` function. RLS is enabled so that if a grant were
-- ever added by accident the rows would still be invisible -- and the absence of
-- a policy is the whole protection, so there is nothing to write down per role.
alter table trip_withdrawals enable row level security;

-- ---------------------------------------------------------------------------
-- The matcher learns to forget.
--
-- The exclusion is `not exists`, which is the same shape as the `exists` on
-- `driver_locations` two lines above it, and for the same reason: a driver with
-- no recent fix is not matchable, and a driver who withdrew from this trip is not
-- matchable either.
--
-- Deliberately a check on the pair rather than on the driver alone. A driver who
-- declined one trip in Osu must still be offered the next one in Osu -- refusing
-- work is a thing drivers do, and a rule that punished it would push them
-- offline, which is the opposite of what this is for.
-- `numeric`, not `double precision`, and that is not a free choice:
-- `pg_get_function_result` on the existing function reports
-- `TABLE(driver_id uuid, pickup_distance_km numeric)`, and `create or replace`
-- refuses to change a return type -- `ERROR 42P13: cannot change return type of
-- existing function`. A `double precision` here is a one-line difference that
-- makes the migration unappliable.
create or replace function match_offers_for_trip(target_trip uuid)
returns table (driver_id uuid, pickup_distance_km numeric)
language sql
security definer
-- `public, extensions`, and the second one is not optional.
--
-- This is a `security definer`, so pinning `search_path` is the thing that stops
-- a caller from hijacking the name resolution -- and pinning it to `public` alone
-- breaks the function outright, because `driver_pickup_distance_km` calls
-- `st_distance` on two `geography` values and PostGIS lives in `extensions`:
-- `ERROR 42883: function st_distance(extensions.geography, extensions.geography)
-- does not exist`. The versions before this migration set no `search_path` at all,
-- which is why they worked.
set search_path = public, extensions
as $$
  select d.id, driver_pickup_distance_km(target_trip, d.id)
    from profiles d
    join vehicles v on v.owner_id = d.id and v.approved
   where d.role = 'driver'
     and d.kyc_status = 'approved'
     and d.availability = 'online'
     and v.ride_category = (select category from trips where id = target_trip)
     and exists (select 1 from driver_locations l where l.driver_id = d.id)
     -- A driver who has withdrawn from this trip is not offered it again. Without
     -- this, a trip returned to `requested` is offered straight back to whoever
     -- just walked away from it.
     and not exists (
       select 1 from trip_withdrawals w
        where w.trip_id = target_trip
          and w.driver_id = d.id
     )
     and driver_pickup_distance_km(target_trip, d.id) <= 5.0
   order by driver_pickup_distance_km(target_trip, d.id)
   limit 5;
$$;

-- Asserted rather than assumed, because this is the one part of the feature with
-- no user-visible failure if it is wrong: the trip still gets matched, just to
-- the driver who declined it, and nothing anywhere reports it.
do $$
begin
  if not exists (
    select 1 from pg_proc
     where proname = 'match_offers_for_trip'
       and prosrc like '%trip_withdrawals%'
  ) then
    raise exception
      'match_offers_for_trip does not exclude withdrawn drivers. A driver who declines a trip will be offered it again.';
  end if;
end;
$$;