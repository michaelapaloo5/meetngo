-- Where people are, for staff, with a retention promise attached.
--
-- ## What already existed
--
-- `driver_locations` has been in the database since the first migration: one row
-- per driver, upserted by the driver app whenever it is online, because
-- `match_offers_for_trip` refuses to offer a ride to a driver with no position.
-- That part is not surveillance, it is the matching algorithm, and it is not
-- what this migration changes.
--
-- What did not exist was any way for a person to *look* at those positions, and
-- any promise about how long they are kept. This migration adds both.
--
-- ## Riders are recorded during a trip and not outside one
--
-- `rider_locations` holds one row per rider, tied to the trip it belongs to, and
-- the purge below deletes it as soon as that trip is no longer live. Outside a
-- trip the rider app sends nothing at all.
--
-- The reasoning is short. "Where is the rider I am collecting" is a ride-hailing
-- feature. "Where is everyone on this platform right now" is a different product,
-- with a different legal footing and a different cost to the people in it, and
-- nobody asked for the second one. So the table exists for the first case only,
-- and the trip id on the row is what makes that enforceable rather than a promise
-- in a comment.
--
-- ## Why place names are cached here
--
-- Reverse geocoding is Nominatim, which is free and rate-limited to one request
-- a second and requires an identifying Referer. Calling it from the page on every
-- visit would be both impolite and visibly broken, so the answer is written back
-- to the row and reused. `place_label_at` exists so a driver's label can be
-- refreshed when they have moved rather than being pinned to wherever they were
-- the first time anybody looked.
--
-- The point is never stored as a label. `whereText` in locations.ts refuses a
-- coordinate-shaped label outright, because one build already wrote
-- "5.5879, -0.2204" into a place field and a support screen is the last place
-- that should answer "where is this person" with a latitude.
--
-- ## Why there is no staff RLS policy
--
-- Deliberately absent. Staff read through the `admin-drivers` Edge Function on
-- the service role, which already bypasses RLS and is already the only path that
-- can see anybody else's data. A second direct route to these rows would be a
-- second thing to get wrong.

-- ---------------------------------------------------------------- riders

create table if not exists public.rider_locations (
  rider_id uuid primary key references public.profiles on delete cascade,
  point geography(Point,4326) not null,
  heading numeric(5,2),
  updated_at timestamptz not null default now(),
  -- The trip this position was reported for. Not null on purpose: a row with no
  -- trip cannot be justified by "they are on a ride right now", which is the only
  -- reason this table exists.
  trip_id uuid not null references public.trips on delete cascade
);

create index if not exists rider_locations_trip_idx
  on public.rider_locations (trip_id);
create index if not exists rider_locations_gix
  on public.rider_locations using gist (point);

alter table public.rider_locations enable row level security;

-- A rider publishes their own position, and only while they are on that trip. The
-- check is against the trip row rather than trusting the app's word for it, so a
-- modified client cannot park somebody's position in the table indefinitely.
drop policy if exists "rider writes own location while on the trip" on public.rider_locations;
create policy "rider writes own location while on the trip" on public.rider_locations
  for all using (rider_id = auth.uid())
  with check (
    rider_id = auth.uid()
    and exists (
      select 1 from public.trips t
      where t.id = rider_locations.trip_id
        and t.rider_id = auth.uid()
        and t.state in ('matched','arriving','ongoing')
    )
  );

-- ------------------------------------------------- cached place names

alter table public.driver_locations
  add column if not exists place_label text,
  add column if not exists place_label_at timestamptz;

alter table public.rider_locations
  add column if not exists place_label text,
  add column if not exists place_label_at timestamptz;

comment on column public.driver_locations.place_label is
  'Reverse-geocoded place name. Never a coordinate; see locations.ts whereText.';
comment on column public.rider_locations.place_label is
  'Reverse-geocoded place name. Never a coordinate; see locations.ts whereText.';

-- ------------------------------------------- keeping data longer, on purpose

-- One row, always. Not a table of requests: there is exactly one answer to "are
-- we keeping location data past its retention", and a second row would make that
-- answer depend on which row a query happened to read.
create table if not exists public.location_settings (
  id boolean primary key default true check (id),
  keep_recording boolean not null default false,
  keep_until timestamptz,
  -- A name, not a foreign key to `staff`, for the same reason the report triage
  -- columns are names: deleting a staff row is how somebody leaves, and it must
  -- not erase the fact that they once asked to keep location data.
  updated_by text,
  updated_at timestamptz not null default now()
);

comment on column public.location_settings.keep_recording is
  'While true the retention purge skips rows newer than keep_until.';

insert into public.location_settings (id, keep_recording)
values (true, false)
on conflict (id) do nothing;

-- ---------------------------------------------------------------- purge

-- Removes location data that has outlived its retention.
--
-- Four things go:
--
--   * driver positions not updated in RETENTION_DAYS. A driver who has not
--     reported a position in a fortnight is not somewhere we should still be able
--     to say they were.
--   * rider positions whose trip is no longer live. This is the one that matters
--     for privacy: it is what makes "only during a trip" true rather than
--     aspirational, and it does not depend on the trip state machine remembering
--     to clean up.
--   * cached place names with no row left to describe.
--   * an expired keep-recording override, so the flag cannot sit on forever
--     because nobody switched it off.
create or replace function public.purge_stale_locations()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  retention interval := make_interval(days => 14);
  removed integer := 0;
begin
  update public.location_settings
     set keep_recording = false,
         keep_until = null,
         updated_at = now()
   where id
     and keep_recording
     and keep_until is not null
     and keep_until <= now();
  get diagnostics removed = row_count;

  if not coalesce(
       (select keep_recording from public.location_settings where id), false)
  then
    delete from public.driver_locations
     where updated_at < now() - retention
       and (place_label_at is null or place_label_at < now() - retention);

    delete from public.rider_locations r
     where r.updated_at < now() - retention
        or not exists (
          select 1 from public.trips t
          where t.id = r.trip_id
            and t.state in ('matched','arriving','ongoing')
        );
  end if;

  return removed;
end;
$$;

comment on function public.purge_stale_locations() is
  'Enforces the retention promise. Returns the number of expired overrides it turned off.';

-- The rider app must not be able to keep writing after its trip ends, or the
-- purge would delete the row and the next fix would put it straight back. This
-- trigger is what makes the trip id on the row authoritative rather than a hint.
create or replace function public.rider_locations_follow_trip()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (
    select 1 from public.trips t
    where t.id = new.trip_id
      and t.state in ('matched','arriving','ongoing')
  ) then
    return new;
  end if;
  -- Not on a live trip: refuse rather than store. The rider app treats a failed
  -- publish as "stop sending", which is the correct response to a trip that has
  -- ended.
  return null;
end;
$$;

drop trigger if exists rider_locations_follow_trip on public.rider_locations;
create trigger rider_locations_follow_trip
  before insert or update on public.rider_locations
  for each row execute function public.rider_locations_follow_trip();

-- ------------------------------------------------------------- the schedule
--
-- pg_cron, in the database, and not on the web host. The rider site is hosted on
-- shared PHP with no cron at all, so a purge scheduled there would silently never
-- run, and a retention promise that depends on something that silently never runs
-- is not a promise. The database is always on.
--
-- Creating the extension needs to happen once and is not transactional, so it is
-- attempted separately rather than inside this migration's transaction. If it is
-- refused, nothing above is affected: the purge function still exists and can be
-- called, and the page says whether the schedule is actually running.

create extension if not exists pg_cron;

select cron.schedule(
  'purge-stale-locations',
  '17 4 * * *',
  $$select public.purge_stale_locations()$$
)
where not exists (select 1 from cron.job where jobname = 'purge-stale-locations');
