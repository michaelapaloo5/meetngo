-- Rider-reported problems with a ride.
--
-- There was no way for a rider to tell anyone that a ride went wrong. The driver
-- app can report an item left behind (`left_item_reports`, migration
-- 20260930000007) and can raise an SOS, but a rider whose driver never arrived,
-- who was dropped somewhere wrong, or who was charged something they did not
-- agree to had nowhere to say so. That is the worst gap in the rider app and it
-- is a reporting gap rather than a feature gap.
--
-- ## One row per ride per reporter
--
-- Not "one row per report". A rider who reports twice about the same ride has
-- said the same thing twice, and a support inbox full of duplicates of one
-- complaint is harder to work than one row that can be updated. `upsert` depends
-- on this existing.
--
-- ## The reporter is on the row, not inferred
--
-- `reported_by` is the rider's own id, and the SELECT policy is scoped to it, so
-- a rider can see what they reported about their own ride and nobody else can see
-- it. Staff read this through the service role, the same as `kyc_decisions`.
--
-- ## Why `reason` is free text and not an enum
--
-- A fixed list of reasons is a guess about what goes wrong, made before anyone
-- has reported anything, and it is the list that quietly decides what the product
-- believes is possible. `reason` is a short human phrase ("Driver never arrived")
-- and `detail` is whatever they want to add. The categories that turn out to be
-- common can be counted from the rows afterwards and turned into chips.

create table if not exists public.trip_reports (
  id uuid primary key default uuid_generate_v4(),
  trip_id uuid not null references public.trips on delete cascade,
  reported_by uuid not null references public.profiles on delete cascade,
  reason text not null check (length(btrim(reason)) > 0),
  detail text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- A rider reports a ride once. `updated_at` moves if they add to it.
  unique (trip_id, reported_by)
);

create index if not exists trip_reports_trip_idx
  on public.trip_reports (trip_id, created_at desc);

-- Staff triage order: newest first across every ride, which is the question a
-- support inbox actually asks.
create index if not exists trip_reports_recent_idx
  on public.trip_reports (created_at desc);

alter table public.trip_reports enable row level security;

drop policy if exists "rider reads own reports" on public.trip_reports;
create policy "rider reads own reports" on public.trip_reports
  for select using (reported_by = auth.uid());

drop policy if exists "rider reports on a ride they took" on public.trip_reports;
create policy "rider reports on a ride they took" on public.trip_reports
  for insert with check (
    reported_by = auth.uid()
    and exists (
      select 1 from public.trips t
       where t.id = trip_reports.trip_id
         and t.rider_id = auth.uid()
    )
  );

-- `using` as well as `with check`, so a rider cannot move a row onto a ride of
-- somebody else's by guessing an id.
drop policy if exists "rider updates own reports" on public.trip_reports;
create policy "rider updates own reports" on public.trip_reports
  for update using (reported_by = auth.uid()) with check (reported_by = auth.uid());

-- No delete policy. A rider who reported something cannot take it back, and a
-- delete policy would mean "I regret asking", which is not what reporting means.
-- `updated_at` exists for adding detail to an existing report.

-- ## Only a finished ride can be reported on
--
-- A rider mid-ride has the SOS button and the driver on the phone, and a report
-- raised while the car is still arriving is a support ticket about a journey in
-- progress that nobody will read until it is over. Enforced here rather than in
-- the app so it cannot be bypassed by a client that wants to.
create or replace function public.trips_can_be_reported(p_trip_id uuid, p_rider_id uuid)
returns boolean
language sql
stable
as $$
  select exists (
    select 1 from public.trips t
     where t.id = p_trip_id
       and t.rider_id = p_rider_id
       and t.state in ('completed', 'cancelled')
  );
$$;

comment on function public.trips_can_be_reported(uuid, uuid) is
  'Whether a ride is finished enough to report a problem about. False mid-ride, where SOS and the driver are the right tools.';