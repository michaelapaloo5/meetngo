create extension if not exists postgis;
create extension if not exists "uuid-ossp";

create type trip_state as enum
  ('requested','matched','arriving','ongoing','completed','cancelled');
create type offer_state as enum
  ('pending','accepted','declined','expired','released');
create type payment_state as enum ('pending','succeeded','failed','voided');
create type pay_method as enum ('momo','cash','card');
create type kyc_status as enum ('notStarted','pending','approved','rejected');
create type driver_availability as enum ('offline','online','onTrip');

create table profiles (
  id uuid primary key references auth.users on delete cascade,
  role text not null check (role in ('rider','driver','admin')),
  full_name text not null default '',
  phone text not null default '',
  photo_url text not null default '',
  rating numeric(2,1) not null default 5.0,
  trip_count integer not null default 0,
  kyc_status kyc_status not null default 'notStarted',
  availability driver_availability not null default 'offline',
  ghana_card_last4 text,
  selfie_url text,
  vehicle_id uuid,
  created_at timestamptz not null default now()
);

create table vehicles (
  id uuid primary key default uuid_generate_v4(),
  owner_id uuid not null unique references profiles on delete cascade,
  vehicle_category text not null check (vehicle_category in ('sedan','suv','van','luxury')),
  ride_category text not null check (ride_category in ('standard','premium','van')),
  make text not null,
  model text not null,
  plate text not null unique,
  seats integer not null default 4,
  photo_url text not null default '',
  approved boolean not null default false,
  created_at timestamptz not null default now()
);

alter table profiles
  add constraint profiles_vehicle_fk
  foreign key (vehicle_id) references vehicles(id) on delete set null;

create table trips (
  id uuid primary key default uuid_generate_v4(),
  rider_id uuid not null references profiles on delete cascade,
  driver_id uuid references profiles on delete set null,
  vehicle_id uuid references vehicles on delete set null,
  category text not null check (category in ('standard','premium','van')),
  state trip_state not null default 'requested',
  pickup jsonb not null,
  dropoff jsonb not null,
  pickup_point geography(Point,4326) not null,
  dropoff_point geography(Point,4326) not null,
  distance_km numeric(8,2) not null,
  surge numeric(3,2) not null default 1.00,
  fare_ghs numeric(10,2) not null,
  eta_minutes integer,
  pickup_otp text,
  is_demo boolean not null default true,
  created_at timestamptz not null default now(),
  matched_at timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz
);

create index trips_rider_idx on trips (rider_id, created_at desc);
create index trips_driver_idx on trips (driver_id, created_at desc);
create index trips_state_idx on trips (state);
create index trips_pickup_gix on trips using gist (pickup_point);

create table offers (
  id uuid primary key default uuid_generate_v4(),
  trip_id uuid not null references trips on delete cascade,
  driver_id uuid not null references profiles on delete cascade,
  fare_ghs numeric(10,2) not null,
  pickup_distance_km numeric(8,2) not null,
  state offer_state not null default 'pending',
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique (trip_id, driver_id)
);

create index offers_driver_idx on offers (driver_id, state);
create index offers_trip_idx on offers (trip_id, state);

create table driver_locations (
  driver_id uuid primary key references profiles on delete cascade,
  point geography(Point,4326) not null,
  heading numeric(5,2),
  updated_at timestamptz not null default now()
);

create index driver_locations_gix on driver_locations using gist (point);

create table payments (
  id uuid primary key default uuid_generate_v4(),
  trip_id uuid not null references trips on delete cascade,
  payer_id uuid not null references profiles on delete cascade,
  amount_ghs numeric(10,2) not null,
  method pay_method not null,
  state payment_state not null default 'pending',
  is_demo boolean not null default true,
  created_at timestamptz not null default now()
);

create table payouts (
  id uuid primary key default uuid_generate_v4(),
  driver_id uuid not null references profiles on delete cascade,
  trip_id uuid references trips on delete set null,
  amount_ghs numeric(10,2) not null,
  is_demo boolean not null default true,
  created_at timestamptz not null default now()
);

create table ledger_entries (
  id uuid primary key default uuid_generate_v4(),
  driver_id uuid not null references profiles on delete cascade,
  trip_id uuid references trips on delete set null,
  amount_ghs numeric(10,2) not null,
  kind text not null check (kind in ('fare','commission','compensation','void','bonus')),
  note text not null default '',
  is_demo boolean not null default true,
  created_at timestamptz not null default now()
);

create table ratings (
  id uuid primary key default uuid_generate_v4(),
  trip_id uuid not null references trips on delete cascade,
  rater_id uuid not null references profiles on delete cascade,
  ratee_id uuid not null references profiles on delete cascade,
  from_role text not null check (from_role in ('rider','driver')),
  stars integer not null check (stars between 1 and 5),
  comment text not null default '',
  created_at timestamptz not null default now(),
  unique (trip_id, from_role)
);

create table promos (
  id uuid primary key default uuid_generate_v4(),
  code text not null unique,
  percent_off numeric(5,2) not null check (percent_off > 0 and percent_off <= 100),
  max_discount_ghs numeric(10,2) not null default 50.00,
  active boolean not null default true,
  expires_at timestamptz,
  created_at timestamptz not null default now()
);

create table chat_messages (
  id uuid primary key default uuid_generate_v4(),
  trip_id uuid not null references trips on delete cascade,
  sender_id uuid not null references profiles on delete cascade,
  body text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now()
);

create index chat_trip_idx on chat_messages (trip_id, created_at);

create table sos_events (
  id uuid primary key default uuid_generate_v4(),
  trip_id uuid not null references trips on delete cascade,
  raised_by uuid not null references profiles on delete cascade,
  point geography(Point,4326),
  note text not null default '',
  status text not null default 'open' check (status in ('open','resolved')),
  created_at timestamptz not null default now()
);

-- Global Constraint: every trip and every money row is demo-only in this build.
alter table trips add constraint trips_demo_only check (is_demo);
alter table payments add constraint payments_demo_only check (is_demo);
alter table payouts add constraint payouts_demo_only check (is_demo);
alter table ledger_entries add constraint ledger_demo_only check (is_demo);

-- Global Constraint: the only legal trip transitions, enforced in the database
-- so a buggy client cannot walk a trip backwards or complete it twice.
create or replace function enforce_trip_transition()
returns trigger
language plpgsql
as $$
begin
  -- No self-transition short circuit: a no-op update that names `state` in its
  -- SET clause falls through to the legality predicate below, so
  -- `new.state = old.state` raises like any other illegal move. Do not
  -- reintroduce an early `return new` here. The Dart `canTransition` table is
  -- the single authority; the Task 17 fake calls it rather than keeping a copy.
  if not (
    (old.state = 'requested' and new.state in ('matched','cancelled')) or
    (old.state = 'matched'    and new.state in ('arriving','cancelled')) or
    (old.state = 'arriving'   and new.state in ('ongoing','cancelled')) or
    (old.state = 'ongoing'    and new.state = 'completed')
  ) then
    raise exception 'illegal trip transition % -> %', old.state, new.state;
  end if;
  return new;
end;
$$;

create trigger trips_transition_guard
before update of state on trips
for each row execute function enforce_trip_transition();

-- Geometry helpers used by the Edge Functions.
--
-- These use st_distance on geography, not st_distance_sphere. PostGIS 3.5 no
-- longer ships the geography overload of st_distance_sphere, so the original
-- `st_distance_sphere(a::geography, b::geography)` fails with
-- `function st_distance_sphere(geography, geography) does not exist` on both
-- PostGIS 3.5 and therefore on any current hosted Supabase project.
-- st_distance(geography, geography) returns the same unit (metres) on every
-- PostGIS since 1.5, and `immutable` still holds.
create or replace function trip_distance_km(a text, b text)
returns numeric
language sql
immutable
as $$
  select st_distance(a::geography, b::geography) / 1000.0;
$$;

create or replace function driver_pickup_distance_km(target_trip uuid, target_driver uuid)
returns numeric
language sql
stable
as $$
  select st_distance(
    l.point,
    (select pickup_point from trips where id = target_trip)
  ) / 1000.0
  from driver_locations l
  where l.driver_id = target_driver;
$$;

create or replace function match_offers_for_trip(target_trip uuid)
returns table (driver_id uuid, pickup_distance_km numeric)
language sql
security definer
set search_path = public
as $$
  select d.id, driver_pickup_distance_km(target_trip, d.id)
  from profiles d
  join vehicles v on v.owner_id = d.id and v.approved
  where d.role = 'driver'
    and d.kyc_status = 'approved'
    and d.availability = 'online'
    and exists (select 1 from driver_locations l where l.driver_id = d.id)
    and driver_pickup_distance_km(target_trip, d.id) <= 5.0
  order by driver_pickup_distance_km(target_trip, d.id)
  limit 5;
$$;

-- Single-winner offer acceptance. Row locks make a simultaneous double-accept
-- resolve to exactly one winner; the loser sees `false` and no trip.
create or replace function accept_offer(p_offer uuid)
returns table (accepted boolean, trip_id uuid, driver_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_offer offers%rowtype;
  v_trip trips%rowtype;
begin
  select * into v_offer from offers where id = p_offer for update;
  if not found then
    return query select false, null::uuid, null::uuid;
    return;
  end if;

  select * into v_trip from trips where id = v_offer.trip_id for update;

  if v_trip.state <> 'requested'
     or v_offer.state <> 'pending'
     or v_offer.expires_at <= now() then
    update offers set state = 'expired' where id = p_offer and state = 'pending';
    return query select false, v_trip.id, null::uuid;
    return;
  end if;

  update offers set state = 'accepted' where id = p_offer;
  -- `offers.`-qualify every column here. The OUT parameters of this function
  -- are named `trip_id` and `driver_id`, so they are PL/pgSQL variables, and
  -- plpgsql's default variable_conflict = error rejects the bare `trip_id` in
  -- this WHERE clause with:
  --   ERROR: column reference "trip_id" is ambiguous
  -- The brief's unqualified version made accept_offer uncallable, so the
  -- single-winner rule never ran. The OUT names themselves are load bearing:
  -- the offers Edge Function reads row.trip_id and row.driver_id, so they stay
  -- as they are and the columns get qualified instead.
  update offers set state = 'released'
    where offers.trip_id = v_offer.trip_id
      and offers.id <> p_offer
      and offers.state = 'pending';

  update trips
     set state = 'matched',
         driver_id = v_offer.driver_id,
         vehicle_id = (select id from vehicles where owner_id = v_offer.driver_id),
         matched_at = now()
   where id = v_offer.trip_id and state = 'requested';

  return query select true, v_trip.id, v_offer.driver_id;
end;
$$;

alter table profiles enable row level security;
alter table vehicles enable row level security;
alter table trips enable row level security;
alter table offers enable row level security;
alter table driver_locations enable row level security;
alter table payments enable row level security;
alter table payouts enable row level security;
alter table ledger_entries enable row level security;
alter table ratings enable row level security;
alter table promos enable row level security;
alter table chat_messages enable row level security;
alter table sos_events enable row level security;

create policy "own profile" on profiles
  for select using (id = auth.uid());
create policy "update own profile" on profiles
  for update using (id = auth.uid());
create policy "driver directory is public" on profiles
  for select using (role = 'driver');

create policy "own vehicle" on vehicles
  for all using (owner_id = auth.uid());

create policy "rider reads own trips" on trips
  for select using (rider_id = auth.uid());
create policy "driver reads assigned trips" on trips
  for select using (driver_id = auth.uid());

create policy "driver reads own offers" on offers
  for select using (driver_id = auth.uid());
create policy "rider reads offers on own trip" on offers
  for select using (
    exists (select 1 from trips t where t.id = offers.trip_id and t.rider_id = auth.uid())
  );

create policy "driver writes own location" on driver_locations
  for all using (driver_id = auth.uid()) with check (driver_id = auth.uid());
create policy "rider reads driver location while assigned" on driver_locations
  for select using (
    exists (
      select 1 from trips t
      where t.driver_id = driver_locations.driver_id
        and t.rider_id = auth.uid()
        and t.state in ('matched','arriving','ongoing')
    )
  );

create policy "own payments" on payments
  for select using (payer_id = auth.uid());
create policy "own payouts" on payouts
  for select using (driver_id = auth.uid());
create policy "own ledger" on ledger_entries
  for select using (driver_id = auth.uid());
create policy "own ratings" on ratings
  for select using (rater_id = auth.uid() or ratee_id = auth.uid());
create policy "read active promos" on promos
  for select using (active);
create policy "trip chat read" on chat_messages
  for select using (
    exists (
      select 1 from trips t
      where t.id = chat_messages.trip_id
        and (t.rider_id = auth.uid() or t.driver_id = auth.uid())
    )
  );
create policy "trip chat insert" on chat_messages
  for insert with check (sender_id = auth.uid());
create policy "own sos events" on sos_events
  for select using (raised_by = auth.uid());

alter publication supabase_realtime add table trips, offers, driver_locations, chat_messages;
