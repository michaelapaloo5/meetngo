-- `van` -> `lite` on the ride category, and the launch promo: every driver
-- keeps 100% of the fare for five months from their first completed trip.
--
-- Why the rename is two steps and not one: `vehicles.vehicle_category` is a
-- BODY STYLE (`sedan`,`suv`,`van`,`luxury`) and a van really is a body style, so
-- that constraint is left alone. Only `ride_category` and `trips.category` --
-- the service a driver sells -- change. Renaming the wrong one would have
-- replaced a real word in a real enum with a service level, and the check would
-- have accepted a body style that does not exist.
--
-- Why a backfill: `select` before this migration found one trip carrying 'van',
-- so the swap is a rename in place, not a constraint swap on empty tables.
--
-- The order below is drop, then rewrite, then re-add, and it is load-bearing.
-- Rewriting the rows while the old check is still attached fails immediately:
-- the old check is `category in ('standard','premium','van')`, so setting a row
-- to 'lite' is exactly the value it rejects, and the migration aborts with
-- `new row for relation "trips" violates check constraint
-- "trips_category_check"`. That is the error this file originally produced. The
-- window in which a category outside the enum is storable is the gap between
-- the DROP and the ADD, and it is closed here by the statement three lines down.

begin;

-- ---------------------------------------------------------------- the rename

alter table vehicles drop constraint if exists vehicles_ride_category_check;
alter table trips drop constraint if exists trips_category_check;

update trips set category = 'lite' where category = 'van';
update vehicles set ride_category = 'lite' where ride_category = 'van';

alter table vehicles add constraint vehicles_ride_category_check
  check (ride_category in ('lite','standard','premium'));

alter table trips add constraint trips_category_check
  check (category in ('lite','standard','premium'));

-- --------------------------------------------------- the launch promo window
--
-- One row per driver, written once, on their first completed trip. It is a
-- table rather than two columns on `profiles` because a client must not be
-- able to write its own promo end date: `profiles` is client-writable, and a
-- driver who could set `promo_ends_at` to '2099-01-01' would hold a 0%
-- commission forever. This table has no INSERT or UPDATE policy at all, so the
-- only writer is the trigger below, which runs as the function owner.
--
-- `ends_at` is stored rather than computed at read time so that "how much of
-- the promo is left" is one comparison and cannot drift between the app, the
-- ledger and the admin page, each of which would otherwise be doing its own
-- month arithmetic.

create table if not exists driver_promos (
  driver_id uuid primary key references profiles on delete cascade,
  started_at timestamptz not null,
  ends_at timestamptz not null,
  created_at timestamptz not null default now(),
  constraint driver_promos_window_ordered check (ends_at > started_at)
);

comment on table driver_promos is
  'Launch promo: 0% commission from the driver''s first completed trip for five '
  'months. Written only by the first-completion trigger; no client policy may '
  'insert or update a row.';

create index if not exists driver_promos_ends_at_idx on driver_promos (ends_at);

-- Five calendar months, not 150 days. A driver whose first trip is on the 31st
-- of a month gets five whole months, and `date_trunc` arithmetic on a
-- timestamp is timezone-free here because the column is timestamptz and the
-- comparison happens in SQL.
create or replace function driver_promos_window(p_started_at timestamptz)
returns table (started_at timestamptz, ends_at timestamptz)
language sql
immutable
set search_path = public
as $$
  select p_started_at, p_started_at + interval '5 months';
$$;

-- ------------------------------------------------- starting the promo window
--
-- AFTER UPDATE, and only on the transition INTO 'completed'. Not on insert, not
-- on every update: a trigger on plain UPDATE would reset `started_at` on the
-- second completion of the same trip, silently restarting the window. The WHEN
-- clause compares against `old.state` precisely so that a re-save of an
-- already-completed trip is a no-op -- and `complete-trip` is exactly the
-- function a client retries, per the idempotency note in its ledger.

create or replace function driver_promos_start_on_first_completion()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.driver_id is null then
    return new;
  end if;

  insert into driver_promos (driver_id, started_at, ends_at)
  select new.driver_id, coalesce(new.completed_at, now()), w.ends_at
  from driver_promos_window(coalesce(new.completed_at, now())) as w
  on conflict (driver_id) do nothing;

  return new;
end;
$$;

drop trigger if exists driver_promos_start_trip on trips;
create trigger driver_promos_start_trip
  after update on trips
  for each row
  when (new.state = 'completed' and old.state is distinct from 'completed')
  execute function driver_promos_start_on_first_completion();

-- ----------------------------------------------- the rate a trip settled at
--
-- Stored on the trip, written once at settlement and never recomputed. The
-- alternative -- reading the promo window when a driver reads their earnings
-- history -- repriced their past: a driver who crossed five months would find
-- commission appearing against rides from their first week, with no row
-- explaining it. The fare is the contract; this is the receipt.

alter table trips add column if not exists commission_rate numeric(5,4);

comment on column trips.commission_rate is
  'Commission actually applied to this trip, written once at settlement. 0 '
  'during the launch promo. NULL means "not yet settled".';

-- -------------------------------------------------------------- row security

alter table driver_promos enable row level security;

-- A driver may read their own window so the app can show the months left.
-- There is deliberately no INSERT or UPDATE policy: the trigger is
-- `security definer` and does not go through RLS, so a client cannot mint or
-- extend a window even as the table's owner.
create policy driver_promos_read_own on driver_promos
  for select to authenticated
  using (driver_id = auth.uid());

commit;
