-- Assertions for supabase/migrations/20260927000001_init.sql.
--
-- Applying the migration without error proves nothing. This file executes it
-- against real PostGIS geography data and asserts the four load-bearing
-- properties the rest of the build depends on:
--
--   1. The trip state machine. All 7 legal ordered pairs update cleanly and all
--      29 illegal ones raise `illegal trip transition <from> -> <to>`. The 29
--      include all 6 self-transitions, because `trips_transition_guard` is
--      `before update of state` with no `new.state = old.state` short circuit.
--      `ongoing -> cancelled` is illegal: the Dart `_legal` map sends `ongoing`
--      only to `completed`, so the database must agree pair for pair.
--   2. The demo-only money guard. `is_demo = false` is rejected by a CHECK
--      constraint on trips, payments, payouts and ledger_entries.
--   3. RLS. A rider cannot read another rider's trip; a driver cannot read
--      another driver's offers or location row.
--   4. The geometry helpers return sane kilometre values for real Accra points
--      (Osu 5.6037,-0.1870 to Airport Residential 5.6052,-0.1660, about 2.4 km).
--
-- RLS is exercised the way Supabase does it, with the transaction-scoped GUCs
-- a real request populates from the JWT:
--
--   set local role authenticated;
--   set local request.jwt.claim.sub = '<uuid>';
--
-- Every check writes a row into a result table, every result table is printed
-- with a PASS/FAIL column, and the file raises at the end if any row failed, so
-- a green run is a real pass and a red run exits non-zero.
--
-- Usage (after harness.sql and the migration):
--   sudo -u postgres psql -d mng_test -v ON_ERROR_STOP=1 \
--     -f supabase/tests/verify_migration.sql

\set ON_ERROR_STOP on
\pset pager off
\pset null '(null)'

-- Fixed fixture ids so every expected value below is a literal a reviewer can
-- check by eye.
\set rider_a   11111111-1111-4111-8111-111111111111
\set rider_b   22222222-2222-4222-8222-222222222222
\set machine   99999999-9999-4999-8999-999999999999
\set driver_c  33333333-3333-4333-8333-333333333333
\set driver_d  44444444-4444-4444-8444-444444444444
\set driver_x  66666666-6666-4666-8666-666666666666
\set trip_a    a0000000-0000-4000-8000-000000000001
\set trip_b    a0000000-0000-4000-8000-000000000002
\set trip_geo  a0000000-0000-4000-8000-000000000003
\set offer_c   c0000000-0000-4000-8000-000000000001
\set offer_d   c0000000-0000-4000-8000-000000000002
\set offer_b   c0000000-0000-4000-8000-000000000003
\set payment_a d0000000-0000-4000-8000-000000000001
\set payout_a  e0000000-0000-4000-8000-000000000001
\set ledger_a  f0000000-0000-4000-8000-000000000001

\echo ''
\echo '== Meet N Go: migration verification =='
\echo ''

begin;

-- ---------------------------------------------------------------------------
-- Result tables
-- ---------------------------------------------------------------------------
create temporary table t_transition (
  seq           int primary key,
  from_state    trip_state not null,
  to_state      trip_state not null,
  pair_kind     text not null,
  expectation   text not null,
  observed      text not null,
  sqlstate      text,
  message       text,
  passed        boolean
) on commit drop;

create temporary table t_demo (
  seq             int primary key,
  table_name      text not null,
  attempt         text not null,
  expectation     text not null,
  observed        text not null,
  sqlstate        text,
  constraint_name text,
  passed          boolean
) on commit drop;

create temporary table t_rls (
  seq         int primary key,
  probe       text not null,
  actor       text not null,
  expectation text not null,
  observed    text not null,
  passed      boolean
) on commit drop;

create temporary table t_geo (
  seq         int primary key,
  probe       text not null,
  expectation text not null,
  observed    text not null,
  passed      boolean
) on commit drop;

-- Section 5 covers accept_offer and match_offers_for_trip, which sit outside
-- the four areas above. They are here because accept_offer was uncallable as
-- written (see the comment in the migration) and a fix with no regression guard
-- is a fix that comes back.
create temporary table t_rpc (
  seq         int primary key,
  probe       text not null,
  expectation text not null,
  observed    text not null,
  passed      boolean
) on commit drop;

-- The RLS probes run as `authenticated` and `anon`, and the RPC probes run as
-- `service_role`, which is what the Edge Functions hold. All three need to
-- write their measurement into a result table. The temp schema is
-- session-private, so its real name has to be resolved before the role switch.
do $$
declare
  v_schema text;
begin
  select nspname into v_schema
    from pg_namespace
   where oid = pg_my_temp_schema();
  execute format('grant usage on schema %I to anon, authenticated, service_role', v_schema);
  execute format('grant insert on pg_temp.t_rls, pg_temp.t_rpc to anon, authenticated, service_role');
end
$$;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  (:'rider_a',  'rider.a@example.com'),
  (:'rider_b',  'rider.b@example.com'),
  (:'machine',  'machine@example.com'),
  (:'driver_c', 'driver.c@example.com'),
  (:'driver_d', 'driver.d@example.com'),
  (:'driver_x', 'driver.nolocation@example.com');

insert into profiles (id, role, full_name, phone, kyc_status, availability) values
  (:'rider_a',  'rider',  'Ama Rider',    '+233200000001', 'notStarted', 'offline'),
  (:'rider_b',  'rider',  'Kofi Rider',   '+233200000002', 'notStarted', 'offline'),
  (:'machine',  'rider',  'Machine Rider','+233200000009', 'notStarted', 'offline'),
  (:'driver_c', 'driver', 'Yaa Driver',   '+233200000003', 'approved',   'online'),
  (:'driver_d', 'driver', 'Kofi Driver',  '+233200000004', 'approved',   'online'),
  (:'driver_x', 'driver', 'No Location',  '+233200000006', 'approved',   'online');

insert into vehicles (id, owner_id, vehicle_category, ride_category, make, model, plate, seats, approved) values
  ('10000000-0000-4000-8000-000000000001', :'driver_c', 'sedan', 'standard', 'Toyota', 'Corolla', 'GH-1001-21', 4, true),
  ('10000000-0000-4000-8000-000000000002', :'driver_d', 'suv',   'premium',  'Nissan', 'X-Trail', 'GH-1002-22', 5, true);

update profiles set vehicle_id = '10000000-0000-4000-8000-000000000001' where id = :'driver_c';
update profiles set vehicle_id = '10000000-0000-4000-8000-000000000002' where id = :'driver_d';

-- driver_c sits in Osu, driver_d sits in Kumasi. driver_x has no location row.
insert into driver_locations (driver_id, point) values
  (:'driver_c', st_setsrid(st_makepoint(-0.1870, 5.6037), 4326)::geography),
  (:'driver_d', st_setsrid(st_makepoint(-1.6163, 6.6665), 4326)::geography);

-- `pickup` and `dropoff` use the nested shape TripStop.toJson() produces:
-- {"label", "point": {"lat", "lng"}, "address"}.
insert into trips (id, rider_id, category, state, pickup, dropoff, pickup_point, dropoff_point, distance_km, surge, fare_ghs, eta_minutes) values
  (:'trip_a', :'rider_a', 'standard', 'requested',
   '{"label":"Osu","point":{"lat":5.6037,"lng":-0.1870},"address":"Osu, Accra"}',
   '{"label":"Airport Residential","point":{"lat":5.6052,"lng":-0.1660},"address":"Airport Residential, Accra"}',
   st_setsrid(st_makepoint(-0.1870, 5.6037), 4326)::geography,
   st_setsrid(st_makepoint(-0.1660, 5.6052), 4326)::geography,
   2.33, 1.00, 12.00, 9),
  (:'trip_b', :'rider_b', 'standard', 'requested',
   '{"label":"Osu","point":{"lat":5.6037,"lng":-0.1870},"address":"Osu, Accra"}',
   '{"label":"Airport Residential","point":{"lat":5.6052,"lng":-0.1660},"address":"Airport Residential, Accra"}',
   st_setsrid(st_makepoint(-0.1870, 5.6037), 4326)::geography,
   st_setsrid(st_makepoint(-0.1660, 5.6052), 4326)::geography,
   2.33, 1.00, 12.00, 9),
  (:'trip_geo', :'rider_a', 'standard', 'completed',
   '{"label":"Airport Residential","point":{"lat":5.6052,"lng":-0.1660},"address":"Airport Residential, Accra"}',
   '{"label":"Osu","point":{"lat":5.6037,"lng":-0.1870},"address":"Osu, Accra"}',
   st_setsrid(st_makepoint(-0.1660, 5.6052), 4326)::geography,
   st_setsrid(st_makepoint(-0.1870, 5.6037), 4326)::geography,
   2.33, 1.00, 12.00, 9);

insert into offers (id, trip_id, driver_id, fare_ghs, pickup_distance_km, state, expires_at) values
  (:'offer_c', :'trip_a', :'driver_c', 12.00, 0.40, 'pending',  now() + interval '20 seconds'),
  (:'offer_d', :'trip_a', :'driver_d', 12.00, 0.90, 'pending',  now() + interval '20 seconds'),
  (:'offer_b', :'trip_b', :'driver_c', 12.00, 1.10, 'pending',  now() + interval '20 seconds');

insert into payments (id, trip_id, payer_id, amount_ghs, method) values
  (:'payment_a', :'trip_a', :'rider_a', 12.00, 'momo');
insert into payouts (id, driver_id, trip_id, amount_ghs) values
  (:'payout_a', :'driver_c', :'trip_a', 9.60);
insert into ledger_entries (id, driver_id, trip_id, amount_ghs, kind) values
  (:'ledger_a', :'driver_c', :'trip_a', 2.40, 'commission');

\echo '-- fixtures --'
select 'profiles' as table_name, count(*) as rows from profiles
union all select 'vehicles', count(*) from vehicles
union all select 'trips', count(*) from trips
union all select 'offers', count(*) from offers
union all select 'driver_locations', count(*) from driver_locations
union all select 'payments', count(*) from payments
union all select 'payouts', count(*) from payouts
union all select 'ledger_entries', count(*) from ledger_entries
order by 1;

-- ---------------------------------------------------------------------------
-- 1. Trip state machine: 7 legal pairs update, 29 illegal pairs raise
-- ---------------------------------------------------------------------------
\echo ''
\echo '-- 1. enforce_trip_transition: 7 legal pairs vs 29 illegal pairs --'

do $$
declare
  v_states  constant trip_state[] :=
    array['requested','matched','arriving','ongoing','completed','cancelled']::trip_state[];
  v_legal   constant text[] := array[
    'requested->matched',    'requested->cancelled',
    'matched->arriving',     'matched->cancelled',
    'arriving->ongoing',     'arriving->cancelled',
    'ongoing->completed'
  ];
  v_from      trip_state;
  v_to        trip_state;
  v_legal_pair boolean;
  v_trip_id    uuid;
  v_rejected  boolean;
  v_sqlstate  text;
  v_message   text;
  v_seq       int := 0;
begin
  foreach v_from in array v_states loop
    foreach v_to in array v_states loop
      v_seq := v_seq + 1;
      v_legal_pair := (v_from::text || '->' || v_to::text) = any(v_legal);

      -- A fresh row per pair: the guard is `before update of state`, so the only
      -- way to stage a starting state is to insert it, never to update into it.
      insert into trips (rider_id, category, state, pickup, dropoff,
                         pickup_point, dropoff_point, distance_km, fare_ghs)
      values ('99999999-9999-4999-8999-999999999999', 'standard', v_from,
              '{"label":"Osu","point":{"lat":5.6037,"lng":-0.1870},"address":"Osu, Accra"}',
              '{"label":"Airport Residential","point":{"lat":5.6052,"lng":-0.1660},"address":"Airport Residential, Accra"}',
              st_setsrid(st_makepoint(-0.1870, 5.6037), 4326)::geography,
              st_setsrid(st_makepoint(-0.1660, 5.6052), 4326)::geography,
              2.33, 12.00)
      returning id into v_trip_id;

      v_rejected := false;
      v_sqlstate := null;
      v_message  := null;
      begin
        update trips set state = v_to where id = v_trip_id;
      exception when others then
        v_rejected := true;
        v_sqlstate := sqlstate;
        v_message  := sqlerrm;
      end;

      insert into t_transition
        (seq, from_state, to_state, pair_kind, expectation, observed, sqlstate, message, passed)
      values (
        v_seq, v_from, v_to,
        case when v_from = v_to then 'self' else 'cross' end,
        case when v_legal_pair then 'allowed' else 'rejected' end,
        case when v_rejected then 'rejected' else 'allowed' end,
        v_sqlstate, v_message,
        (v_rejected = not v_legal_pair)
        and (v_legal_pair or v_message = format('illegal trip transition %s -> %s', v_from, v_to))
      );
    end loop;
  end loop;
end
$$;

select seq,
       from_state,
       to_state,
       pair_kind,
       expectation,
       observed,
       coalesce(sqlstate, '-') as sqlstate,
       passed
  from t_transition
 order by seq;

\echo ''
\echo '-- 1b. all 36 ordered pairs in one line each, with the raised message --'
select from_state || ' -> ' || to_state as transition,
       pair_kind,
       expectation,
       observed,
       coalesce(message, '(no exception)') as message,
       passed
  from t_transition
 order by seq;

\echo ''
\echo '-- 1c. transition tallies --'
select count(*)                                              as pairs,
       count(*) filter (where pair_kind = 'self')            as self_pairs,
       count(*) filter (where expectation = 'allowed')       as legal_expected,
       count(*) filter (where expectation = 'allowed' and passed)  as legal_passed,
       count(*) filter (where expectation = 'rejected')      as illegal_expected,
       count(*) filter (where expectation = 'rejected' and passed) as illegal_passed,
       count(*) filter (where pair_kind = 'self' and passed) as self_passed,
       count(*) filter (where not passed)                    as failed
  from t_transition;

\echo ''
\echo '-- 1d. the pairs most likely to be got wrong, called out --'
select from_state || ' -> ' || to_state as transition,
       expectation, observed, passed
  from t_transition
 where (from_state, to_state) in (('ongoing','cancelled'),
                                  ('completed','cancelled'),
                                  ('matched','ongoing'),
                                  ('arriving','completed'),
                                  ('requested','arriving'),
                                  ('ongoing','arriving'))
    or from_state = to_state
 order by seq;

-- ---------------------------------------------------------------------------
-- 2. Demo-only money guard
-- ---------------------------------------------------------------------------
\echo ''
\echo '-- 2. CHECK (is_demo) on every money table --'

create temporary table demo_targets (
  seq    int primary key,
  tbl    text not null,
  row_id uuid not null
) on commit drop;

insert into demo_targets values
  (1, 'trips',         :'trip_a'),
  (2, 'payments',      :'payment_a'),
  (3, 'payouts',       :'payout_a'),
  (4, 'ledger_entries', :'ledger_a');

do $$
declare
  r record;
  v_rejected boolean;
  v_sqlstate text;
  v_message  text;
  v_seq      int := 0;
begin
  for r in select * from demo_targets order by seq loop
    -- Negative case: is_demo = false must be refused.
    v_rejected := false;
    v_sqlstate := null;
    v_message  := null;
    begin
      execute format('update %I set is_demo = false where id = $1', r.tbl)
        using r.row_id;
    exception when others then
      v_rejected := true;
      v_sqlstate := sqlstate;
      v_message  := sqlerrm;
    end;
    v_seq := v_seq + 1;
    insert into t_demo
      (seq, table_name, attempt, expectation, observed, sqlstate, constraint_name, passed)
    values (
      v_seq, r.tbl, 'set is_demo = false', 'rejected',
      case when v_rejected then 'rejected' else 'allowed' end,
      v_sqlstate,
      (select conname from pg_constraint
        where conrelid = r.tbl::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%is_demo%'),
      v_rejected and v_sqlstate = '23514'
    );

    -- Positive case: is_demo = true must still be accepted, so the constraint
    -- is a guard on the value and not a blanket refusal of the column.
    v_rejected := false;
    v_sqlstate := null;
    begin
      execute format('update %I set is_demo = true where id = $1', r.tbl)
        using r.row_id;
    exception when others then
      v_rejected := true;
      v_sqlstate := sqlstate;
    end;
    v_seq := v_seq + 1;
    insert into t_demo
      (seq, table_name, attempt, expectation, observed, sqlstate, constraint_name, passed)
    values (
      v_seq, r.tbl, 'set is_demo = true', 'allowed',
      case when v_rejected then 'rejected' else 'allowed' end,
      v_sqlstate, '-', not v_rejected
    );
  end loop;
end
$$;

select table_name, attempt, expectation, observed,
       coalesce(sqlstate, '-') as sqlstate,
       constraint_name, passed
  from t_demo
 order by seq;

\echo ''
\echo '-- 2b. is_demo is still true everywhere after the negative attempts --'
select 'trips' as table_name, count(*) filter (where is_demo) as demo_true, count(*) as total from trips
union all select 'payments', count(*) filter (where is_demo), count(*) from payments
union all select 'payouts', count(*) filter (where is_demo), count(*) from payouts
union all select 'ledger_entries', count(*) filter (where is_demo), count(*) from ledger_entries
order by 1;

-- ---------------------------------------------------------------------------
-- 3. RLS
-- ---------------------------------------------------------------------------
\echo ''
\echo '-- 3. row level security: cross-rider and cross-driver reads --'

set local role anon;
insert into t_rls (seq, probe, actor, expectation, observed) values
  (1, 'anon key reads trips', 'anon (no jwt)',
   '<none>',
   (select coalesce(string_agg(id::text, ',' order by id::text), '<none>') from trips));
reset role;

set local role authenticated;
insert into t_rls (seq, probe, actor, expectation, observed) values
  (2, 'authenticated with no sub claim reads trips', 'authenticated (no sub)',
   '<none>',
   (select coalesce(string_agg(id::text, ',' order by id::text), '<none>') from trips));
reset role;

set local role authenticated;
set local request.jwt.claim.sub = :'rider_a';
insert into t_rls (seq, probe, actor, expectation, observed) values
  (3, 'rider A lists trips', 'authenticated ' || :'rider_a',
   :'trip_a' || ',' || :'trip_geo',
   (select coalesce(string_agg(id::text, ',' order by id::text), '<none>') from trips)),
  (4, 'rider A reads rider B trip by id', 'authenticated ' || :'rider_a',
   '<none>',
   (select coalesce(string_agg(id::text, ',' order by id::text), '<none>')
      from trips where id = :'trip_b')),
  (5, 'rider A reads offers on own trip', 'authenticated ' || :'rider_a',
   :'offer_c' || ',' || :'offer_d',
   (select coalesce(string_agg(id::text, ',' order by id::text), '<none>') from offers)),
  (6, 'rider A reads offers on rider B trip', 'authenticated ' || :'rider_a',
   '<none>',
   (select coalesce(string_agg(id::text, ',' order by id::text), '<none>')
      from offers where trip_id = :'trip_b'));
reset role;

set local role authenticated;
set local request.jwt.claim.sub = :'rider_b';
insert into t_rls (seq, probe, actor, expectation, observed) values
  (7, 'rider B lists trips', 'authenticated ' || :'rider_b',
   :'trip_b',
   (select coalesce(string_agg(id::text, ',' order by id::text), '<none>') from trips)),
  (8, 'rider B reads rider A trip by id', 'authenticated ' || :'rider_b',
   '<none>',
   (select coalesce(string_agg(id::text, ',' order by id::text), '<none>')
      from trips where id = :'trip_a'));
reset role;

set local role authenticated;
set local request.jwt.claim.sub = :'driver_c';
insert into t_rls (seq, probe, actor, expectation, observed) values
  (9, 'driver C lists own offers only', 'authenticated ' || :'driver_c',
   :'offer_c' || ',' || :'offer_b',
   (select coalesce(string_agg(id::text, ',' order by id::text), '<none>') from offers)),
  (10, 'driver C reads driver D offer by id', 'authenticated ' || :'driver_c',
   '<none>',
   (select coalesce(string_agg(id::text, ',' order by id::text), '<none>')
      from offers where driver_id = :'driver_d')),
  (11, 'driver C reads own location row only', 'authenticated ' || :'driver_c',
   :'driver_c',
   (select coalesce(string_agg(driver_id::text, ',' order by driver_id::text), '<none>')
      from driver_locations)),
  (12, 'driver C reads driver D location row', 'authenticated ' || :'driver_c',
   '<none>',
   (select coalesce(string_agg(driver_id::text, ',' order by driver_id::text), '<none>')
      from driver_locations where driver_id = :'driver_d'));
reset role;

set local role authenticated;
set local request.jwt.claim.sub = :'driver_d';
insert into t_rls (seq, probe, actor, expectation, observed) values
  (13, 'driver D lists own offers only', 'authenticated ' || :'driver_d',
   :'offer_d',
   (select coalesce(string_agg(id::text, ',' order by id::text), '<none>') from offers));
reset role;

update t_rls set passed = (observed = expectation);

select seq, probe, expectation, observed,
       case when passed then 'PASS' else 'FAIL' end as verdict
  from t_rls
 order by seq;

\echo ''
\echo '-- 3b. rls tallies --'
select count(*) as probes,
       count(*) filter (where passed) as passed,
       count(*) filter (where not passed) as failed
  from t_rls;

\echo ''
\echo '-- 3c. row level security is enabled on every exposed table --'
select c.relname as table_name,
       c.relrowsecurity as rls_enabled,
       (select count(*) from pg_policy p where p.polrelid = c.oid) as policies
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public'
   and c.relkind = 'r'
   and c.relname in ('profiles','vehicles','trips','offers','driver_locations',
                     'payments','payouts','ledger_entries','ratings','promos',
                     'chat_messages','sos_events')
 order by c.relname;

-- ---------------------------------------------------------------------------
-- 4. Geometry helpers
-- ---------------------------------------------------------------------------
\echo ''
\echo '-- 4. trip_distance_km / driver_pickup_distance_km over real Accra points --'
\echo '   Osu 5.6037,-0.1870  <->  Airport Residential 5.6052,-0.1660  =  about 2.4 km'

insert into t_geo (seq, probe, expectation, observed, passed) values
  (1, 'trip_distance_km, EWKT text, Osu to Airport Residential', 'between 2.20 and 2.50 km',
   round(trip_distance_km('SRID=4326;POINT(-0.1870 5.6037)',
                          'SRID=4326;POINT(-0.1660 5.6052)')::numeric, 3)::text,
   trip_distance_km('SRID=4326;POINT(-0.1870 5.6037)',
                    'SRID=4326;POINT(-0.1660 5.6052)') between 2.2 and 2.5),
  (2, 'trip_distance_km, plain WKT text, same pair', 'between 2.20 and 2.50 km',
   round(trip_distance_km('POINT(-0.1870 5.6037)',
                          'POINT(-0.1660 5.6052)')::numeric, 3)::text,
   trip_distance_km('POINT(-0.1870 5.6037)',
                    'POINT(-0.1660 5.6052)') between 2.2 and 2.5),
  (3, 'trip_distance_km is symmetric', 'between 2.20 and 2.50 km',
   round(trip_distance_km('SRID=4326;POINT(-0.1660 5.6052)',
                          'SRID=4326;POINT(-0.1870 5.6037)')::numeric, 3)::text,
   trip_distance_km('SRID=4326;POINT(-0.1660 5.6052)',
                    'SRID=4326;POINT(-0.1870 5.6037)') between 2.2 and 2.5),
  (4, 'driver_pickup_distance_km, driver in Osu, trip pickup at Airport Residential',
   'between 2.20 and 2.50 km',
   round(driver_pickup_distance_km(:'trip_geo', :'driver_c')::numeric, 3)::text,
   driver_pickup_distance_km(:'trip_geo', :'driver_c') between 2.2 and 2.5),
  (5, 'driver_pickup_distance_km, driver in Kumasi (far)', 'over 150 km',
   round(driver_pickup_distance_km(:'trip_geo', :'driver_d')::numeric, 3)::text,
   driver_pickup_distance_km(:'trip_geo', :'driver_d') > 150),
  (6, 'driver_pickup_distance_km, driver has no driver_locations row', 'no rows',
   case when driver_pickup_distance_km(:'trip_geo', :'driver_x') is null
        then 'no rows' else 'unexpected row' end,
   driver_pickup_distance_km(:'trip_geo', :'driver_x') is null),
  (7, 'trip_distance_km stored value agrees with the RPC', 'within 0.01 km of 2.33',
   round(abs((select distance_km from trips where id = :'trip_a')
             - trip_distance_km('SRID=4326;POINT(-0.1870 5.6037)',
                                'SRID=4326;POINT(-0.1660 5.6052)'))::numeric, 3)::text,
   abs((select distance_km from trips where id = :'trip_a')
       - trip_distance_km('SRID=4326;POINT(-0.1870 5.6037)',
                          'SRID=4326;POINT(-0.1660 5.6052)')) < 0.01),
  (8, 'trip_distance_km rejects text that is not a point', 'rejected', 'probe:raises',
   true);

-- Probe 8 needs an exception capture of its own; the row above is replaced
-- with the real outcome.
do $$
declare
  v_sqlstate text;
  v_message  text;
  v_rejected boolean := false;
begin
  begin
    perform trip_distance_km('not-a-point', 'SRID=4326;POINT(0 0)');
  exception when others then
    v_rejected := true;
    v_sqlstate := sqlstate;
    v_message  := sqlerrm;
  end;
  update t_geo
     set expectation = 'rejected',
         observed    = case when v_rejected then 'rejected: ' || v_sqlstate
                             else 'accepted' end,
         passed      = v_rejected
   where seq = 8;
end
$$;

-- The jsonb shape TripStop.toJson() produces must survive a round trip, or
-- every later task's Trip.fromJson throws on a cast error.
insert into t_geo (seq, probe, expectation, observed, passed) values
  (9, 'trips.pickup jsonb keeps the nested point key TripStop.fromJson expects',
   'lat=5.6052 lng=-0.1660 label=Airport Residential',
   'lat=' || (select pickup->'point'->>'lat' from trips where id = :'trip_geo')
     || ' lng=' || (select pickup->'point'->>'lng' from trips where id = :'trip_geo')
     || ' label=' || (select pickup->>'label' from trips where id = :'trip_geo'),
   (select pickup->'point'->>'lat' = '5.6052'
       and pickup->'point'->>'lng' = '-0.1660'
       and pickup->>'label' = 'Airport Residential'
    from trips where id = :'trip_geo'));

select seq, probe, expectation, observed,
       case when passed then 'PASS' else 'FAIL' end as verdict
  from t_geo
 order by seq;

\echo ''
\echo '-- 4b. geometry tallies --'
select count(*) as probes,
       count(*) filter (where passed) as passed,
       count(*) filter (where not passed) as failed
  from t_geo;

-- ---------------------------------------------------------------------------
-- 5. Matching and offer acceptance
--
-- Beyond the four required areas, kept because accept_offer did not compile
-- into a callable function until its WHERE clause was column-qualified. Run
-- as service_role, the key the offers Edge Function uses.
-- ---------------------------------------------------------------------------
\echo ''
\echo '-- 5. match_offers_for_trip and the single-winner accept_offer --'

set local role service_role;
insert into t_rpc (seq, probe, expectation, observed) values
  (1, 'match_offers_for_trip keeps only online, approved, located drivers within 5 km',
   :'driver_c',
   (select coalesce(string_agg(driver_id::text, ',' order by driver_id::text), '<none>')
      from match_offers_for_trip(:'trip_a')));

insert into t_rpc (seq, probe, expectation, observed) values
  (2, 'accept_offer elects the winner', 'true|' || :'trip_a' || '|' || :'driver_c',
   (select coalesce(string_agg(
             accepted::text || '|' || coalesce(trip_id::text, '-') || '|' || coalesce(driver_id::text, '-'),
             ';'), '<no row>')
      from accept_offer(:'offer_c')));

insert into t_rpc (seq, probe, expectation, observed) values
  (3, 're-accepting the already accepted offer loses', 'false',
   (select coalesce(accepted::text, '<no row>') from accept_offer(:'offer_c')));

insert into t_rpc (seq, probe, expectation, observed) values
  (4, 'the trip is now matched to the winning driver with a vehicle attached',
   'matched|' || :'driver_c' || '|10000000-0000-4000-8000-000000000001',
   (select state::text || '|' || coalesce(driver_id::text, '-') || '|' || coalesce(vehicle_id::text, '-')
      from trips where id = :'trip_a')),
  (5, 'the losing sibling offer is released', 'released',
   (select state::text from offers where id = :'offer_d'));

insert into t_rpc (seq, probe, expectation, observed) values
  (6, 'the losing driver retrying the released offer loses', 'false',
   (select coalesce(accepted::text, '<no row>') from accept_offer(:'offer_d')));

insert into t_rpc (seq, probe, expectation, observed) values
  (7, 'accept_offer on an unknown id returns false instead of raising', 'false',
   (select coalesce(accepted::text, '<no row>')
      from accept_offer('c0000000-0000-4000-8000-0000000000ff')));
reset role;

-- An offer past its 20 second TTL must lose and must be flipped to `expired`.
update offers set expires_at = now() - interval '1 minute' where id = :'offer_b';
set local role service_role;
insert into t_rpc (seq, probe, expectation, observed) values
  (8, 'an offer past its 20s TTL loses', 'false',
   (select coalesce(accepted::text, '<no row>') from accept_offer(:'offer_b')));
reset role;
insert into t_rpc (seq, probe, expectation, observed) values
  (9, 'the expired offer is flipped to state expired', 'expired',
   (select state::text from offers where id = :'offer_b'));

update t_rpc set passed = (observed = expectation);

select seq, probe, expectation, observed,
       case when passed then 'PASS' else 'FAIL' end as verdict
  from t_rpc
 order by seq;

\echo ''
\echo '-- 5b. rpc tallies --'
select count(*) as probes,
       count(*) filter (where passed) as passed,
       count(*) filter (where not passed) as failed
  from t_rpc;

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------
\echo ''
\echo '== summary =='
select 'trip transition trigger' as area, count(*) as assertions,
       count(*) filter (where passed) as passed,
       count(*) filter (where not passed) as failed from t_transition
union all
select 'demo-only CHECK', count(*), count(*) filter (where passed),
       count(*) filter (where not passed) from t_demo
union all
select 'row level security', count(*), count(*) filter (where passed),
       count(*) filter (where not passed) from t_rls
union all
select 'geometry helpers', count(*), count(*) filter (where passed),
       count(*) filter (where not passed) from t_geo
union all
select 'match and accept RPCs', count(*), count(*) filter (where passed),
       count(*) filter (where not passed) from t_rpc
order by 1;

do $$
declare
  v_failed  int;
  v_total   int;
begin
  select count(*) into v_failed from (
    select passed from t_transition where not passed
    union all
    select passed from t_demo where not passed
    union all
    select passed from t_rls where not passed
    union all
    select passed from t_geo where not passed
    union all
    select passed from t_rpc where not passed
  ) failures;

  select (select count(*) from t_transition)
       + (select count(*) from t_demo)
       + (select count(*) from t_rls)
       + (select count(*) from t_geo)
       + (select count(*) from t_rpc)
    into v_total;

  if v_failed > 0 then
    raise exception '% of % migration assertions failed', v_failed, v_total;
  end if;

  raise notice 'all % migration assertions passed', v_total;
end
$$;

\echo ''
\echo 'OK: every migration assertion passed.'
-- Rollback, not commit: this file must leave no fixture rows behind, or a
-- second run collides with auth.users' primary key.
rollback;
