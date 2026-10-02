-- Saved places, scheduled rides, and the vehicle a trip was actually driven in.
--
-- Four things the rider audit found missing, in one migration because three of
-- them touch the same two tables.
--
-- ## 1. `trips.vehicle_id` was never written
--
-- The column exists and nothing sets it. Not a function, not a trigger, not a
-- client -- `grep` finds only the admin page's own driver query and the one read
-- added in `contact/clients.ts`. So the rider's driver card had no car and no
-- number plate on any trip, ever, and the read had to fall back to the driver's
-- current `profiles.vehicle_id` to give a rider the one detail they can read off
-- a windscreen.
--
-- The fallback is not a fix. A trip that records *which car* is the only thing
-- that can be right when a driver changes vehicle between trips: the fallback
-- shows today's car for a trip driven last month in a different one.
--
-- A trigger, rather than a write in the accept path, because "a trip has a
-- driver" and "a trip has that driver's vehicle" are the same fact and there are
-- several ways a driver gets onto a trip (accepting an offer, a match function,
-- an admin correction). A trigger cannot be forgotten by the fourth way.
--
-- Copied rather than derived on read, so it is a record of what happened rather
-- than a question about what is true now.

-- ## 2. Saved places
--
-- A rider's own list of places. No table existed and nothing local was stored, so
-- "recent destinations" was derived from the last five trips' dropoffs
-- (`rider_shell.dart`) -- which means a rider who searched for somewhere ten
-- times and went nowhere never saw it again, and the only places they could
-- re-use were the ones they had already paid to be driven to.
--
-- `label` is a real place name and never a coordinate, for the same reason the
-- trip stops are: `trip_copy.dart` has a regex whose whole job is to stop a
-- coordinate reaching a rider, and a saved place is a place that gets printed in
-- a list forever.

create table if not exists public.saved_places (
  id uuid primary key default uuid_generate_v4(),
  rider_id uuid not null references public.profiles on delete cascade,
  label text not null check (length(btrim(label)) > 0),
  address text not null default '',
  point jsonb not null check (
    point is not null
    and point ->> 'type' = 'Point'
    and jsonb_typeof(point -> 'coordinates') = 'array'
    and jsonb_array_length(point -> 'coordinates') >= 2
  ),
  created_at timestamptz not null default now()
);

-- One row per rider per place, case-insensitively.
--
-- A unique *index* and not a table constraint, because a constraint cannot
-- contain an expression and `lower(label)` is one. A rider who saves "Home" and
-- then "home" updates the row they already have rather than growing a list of
-- two identical entries, and `upsert` depends on this existing.
--
-- `lower()` rather than `citext`: a column type the whole database then has to
-- be aware of, for one comparison.
create unique index if not exists saved_places_rider_label_uniq
  on public.saved_places (rider_id, lower(label));

create index if not exists saved_places_rider_recent_idx
  on public.saved_places (rider_id, created_at desc);

alter table public.saved_places enable row level security;

-- Select, insert, update and delete are all scoped to the owner in one clause
-- each, because a saved place is the rider's own note about their own life and
-- there is no second party to it. `using` on the update and delete policies is
-- what stops a rider modifying somebody else's row by guessing an id: without
-- it, `with check` alone would allow the write to *become* theirs.
drop policy if exists "rider reads own saved places" on public.saved_places;
create policy "rider reads own saved places" on public.saved_places
  for select using (rider_id = auth.uid());

drop policy if exists "rider saves own places" on public.saved_places;
create policy "rider saves own places" on public.saved_places
  for insert with check (rider_id = auth.uid());

drop policy if exists "rider updates own places" on public.saved_places;
create policy "rider updates own places" on public.saved_places
  for update using (rider_id = auth.uid()) with check (rider_id = auth.uid());

drop policy if exists "rider deletes own places" on public.saved_places;
create policy "rider deletes own places" on public.saved_places
  for delete using (rider_id = auth.uid());


-- ## 3. Scheduled rides
--
-- `scheduled_for` is null for an immediate ride and a timestamptz for one that
-- should join the pool later. It is a column rather than a new trip state
-- because a scheduled ride is *the same ride* with a different start time, and
-- adding a state would mean every existing `canTransition` table, the database
-- trigger that mirrors it, and both apps' state switch statements would need to
-- learn about it. One nullable column and one comparison is smaller than a new
-- state and cannot drift from it.
--
-- A scheduled trip sits in `requested` and is simply **not eligible for the
-- offer pool** until its time arrives. That is the whole of the mechanic, and it
-- is deliberately not a new state: `trips.state` still says `requested` from the
-- moment the rider books, so the rider's own app already knows a trip exists and
-- already knows to cancel it.
--
-- Added before the eligibility function below, because a SQL function's body is
-- parsed when it is created: a function referencing a column that does not exist
-- yet fails at `create`, not at first call.
alter table public.trips
  add column if not exists scheduled_for timestamptz;

comment on column public.trips.scheduled_for is
  'When a scheduled ride should start entering the offer pool. Null means immediately.';

-- The eligibility test lives in one place so the offer query and the
-- "is this due yet" release cannot disagree about which trips may be matched.
-- Two predicates that drift are how a scheduled ride gets dispatched three hours
-- early.
--
-- Takes the two columns rather than reading the row, because it is called from a
-- query over many trips and reading the row inside it would mean a second scan
-- per row. It also means the caller cannot forget to pass the row it means.
create or replace function public.trips_is_offerable(
  p_state text,
  p_scheduled_for timestamptz,
  p_now timestamptz default now()
)
returns boolean
language sql
immutable
as $$
  select p_state = 'requested'
     and (p_scheduled_for is null or p_scheduled_for <= p_now);
$$;

comment on function public.trips_is_offerable(text, timestamptz, timestamptz) is
  'Whether a trip may be put to drivers right now. A null scheduled_for means now.';


-- ## The trigger
--
-- Fires when a trip's driver changes, and copies that driver's current vehicle.
-- `profiles.vehicle_id` is what the driver app sets once they have registered a
-- vehicle, and it is null for a driver who has not.
create or replace function public.trips_take_driver_vehicle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.driver_id is not null
     and (tg_op = 'INSERT' or new.driver_id is distinct from old.driver_id) then
    select p.vehicle_id into new.vehicle_id
      from public.profiles p
     where p.id = new.driver_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trips_take_driver_vehicle on public.trips;
create trigger trips_take_driver_vehicle
  before insert or update of driver_id on public.trips
  for each row execute function public.trips_take_driver_vehicle();

-- Backfill, because every trip that already has a driver should have recorded
-- which vehicle. Left null where the driver has no vehicle, which is honest --
-- there was no vehicle to record.
update public.trips t
   set vehicle_id = p.vehicle_id
  from public.profiles p
 where p.id = t.driver_id
   and t.vehicle_id is null
   and p.vehicle_id is not null;


-- ## 4. Ride history filters
--
-- Nothing to migrate: a filtered query is a query with more predicates. The
-- change is in `TripRepository.history`, and the point of doing it there rather
-- than in the controller is that the controller cannot express "this month" in
-- PostgREST without hand-writing a filter string, and a hand-written filter
-- string is where a rider's own text ends up in a query.

-- A scheduled trip cannot be in the past on creation: a rider who books for a
-- moment that has already gone is asking to be matched now, and the offer path
-- will treat it as exactly that. No constraint, deliberately -- the column is
-- nullable and a check would have to allow null explicitly for no gain.