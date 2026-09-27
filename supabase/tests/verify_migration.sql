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
\set trip_live a0000000-0000-4000-8000-000000000004
\set trip_gone a0000000-0000-4000-8000-000000000005
\set trip_arr  a0000000-0000-4000-8000-000000000006
\set trip_ong  a0000000-0000-4000-8000-000000000007
\set trip_mtc  a0000000-0000-4000-8000-000000000008
\set offer_c   c0000000-0000-4000-8000-000000000001
\set offer_d   c0000000-0000-4000-8000-000000000002
\set offer_b   c0000000-0000-4000-8000-000000000003
\set offer_e   c0000000-0000-4000-8000-000000000004
\set payment_a d0000000-0000-4000-8000-000000000001
\set payout_a  e0000000-0000-4000-8000-000000000001
\set ledger_a  f0000000-0000-4000-8000-000000000001
\set signup_x  77777777-7777-4777-8777-777777777777
\set signup_d  88888888-8888-4888-8888-888888888888
\set signup_k  55555555-5555-4555-8555-555555555555

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

-- Beyond the four required areas, kept because accept_offer did not compile
-- into a callable function until its WHERE clause was column-qualified. Run
-- with request.jwt.claim.sub set to the calling driver, which is how the offers
-- Edge Function calls it, and not as service_role: the ownership check the RPC
-- now performs is the thing under test.
create temporary table t_rpc (
  seq         int primary key,
  probe       text not null,
  expectation text not null,
  observed    text not null,
  passed      boolean
) on commit drop;

-- Section 6 covers the client write paths the migration gates with policies,
-- column grants and triggers: trip state advance, SOS, chat, profile edits and
-- vehicle approval.
create temporary table t_write (
  seq         int primary key,
  probe       text not null,
  expectation text not null,
  observed    text not null,
  passed      boolean
) on commit drop;

-- The RLS probes run as `authenticated` and `anon`, and the RPC probes as the
-- calling driver, so all three need to write their measurement into a result
-- table. The temp schema is session-private, so its real name has to be
-- resolved before the role switch.
do $$
declare
  v_schema text;
begin
  select nspname into v_schema
    from pg_namespace
   where oid = pg_my_temp_schema();
  execute format('grant usage on schema %I to anon, authenticated, service_role', v_schema);
  execute format('grant insert on pg_temp.t_rls, pg_temp.t_rpc, pg_temp.t_write'
                 ' to anon, authenticated, service_role');
end
$$;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  (:'rider_a',  'rider.a@example.com',  '{"role":"rider"}'),
  (:'rider_b',  'rider.b@example.com',  '{"role":"rider"}'),
  (:'machine',  'machine@example.com',  '{"role":"rider"}'),
  (:'driver_c', 'driver.c@example.com', '{"role":"driver"}'),
  (:'driver_d', 'driver.d@example.com', '{"role":"driver"}'),
  (:'driver_x', 'driver.nolocation@example.com', '{"role":"driver"}'),
  -- signup_x asks for role admin in its metadata; handle_new_user must clamp
  -- it to rider. signup_d asks for driver, which is allowed.
  (:'signup_x', 'signup.x@example.com', '{"role":"admin"}'),
  (:'signup_d', 'signup.d@example.com', '{"role":"driver"}'),
  -- signup_k is the pristine driver the KYC probes mutate, so the probe that
  -- reports what signup created still sees untouched defaults.
  (:'signup_k', 'signup.k@example.com', '{"role":"driver"}');

-- handle_new_user has already created a profiles row for every one of those
-- auth.users rows. Assert that happened, then bring the ones the other sections
-- need up to the state they expect.
\echo '-- handle_new_user: signup creates the profile row --'
select 'profiles created by handle_new_user' as probe,
       count(*)::text as observed,
       (count(*) = 9)::text as expectation
  from profiles;

update profiles set full_name = 'Ama Rider', phone = '+233200000001'
 where id = :'rider_a';
update profiles set full_name = 'Kofi Rider', phone = '+233200000002'
 where id = :'rider_b';
update profiles set full_name = 'Machine Rider', phone = '+233200000009'
 where id = :'machine';
update profiles set kyc_status = 'approved', availability = 'online',
                   full_name = 'Yaa Driver', phone = '+233200000003'
 where id = :'driver_c';
update profiles set kyc_status = 'approved', availability = 'online',
                   full_name = 'Kofi Driver', phone = '+233200000004'
 where id = :'driver_d';
update profiles set kyc_status = 'approved', availability = 'online',
                   full_name = 'No Location', phone = '+233200000006'
 where id = :'driver_x';

-- The auth.users inserts above fired on_auth_user_created, so every profile
-- already exists with role taken from metadata. The rows below only bring the
-- named fields up to the state the rest of this file assumes; note that
-- kyc_status = 'approved' and availability = 'online' are set as postgres,
-- which is the service_role path guard_profile_update has to keep open.

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

-- A cancelled trip owned by rider_b. The SOS policy must accept this state too,
-- which is what closes the last hole in the state coverage: matched (probe 7),
-- requested (probe 9), completed (probe 37) and cancelled (probe 38). Owned by
-- rider_b so rider A's visible trip set in section 3 does not change.
insert into trips (id, rider_id, category, state, pickup, dropoff, pickup_point,
                   dropoff_point, distance_km, surge, fare_ghs, eta_minutes,
                   created_at, cancelled_at)
values (:'trip_gone', :'rider_b', 'standard', 'cancelled',
   '{"label":"Osu","point":{"lat":5.6037,"lng":-0.1870},"address":"Osu, Accra"}',
   '{"label":"Airport Residential","point":{"lat":5.6052,"lng":-0.1660},"address":"Airport Residential, Accra"}',
   st_setsrid(st_makepoint(-0.1870, 5.6037), 4326)::geography,
   st_setsrid(st_makepoint(-0.1660, 5.6052), 4326)::geography,
   2.33, 1.00, 12.00, 9, now() - interval '40 minutes', now() - interval '39 minutes');

-- An in-flight trip assigned to driver_c. Section 6 needs a trip that the
-- driver client is allowed to touch, and a trip that is neither requested nor
-- terminal.
insert into trips (id, rider_id, driver_id, category, state, pickup, dropoff,
                   pickup_point, dropoff_point, distance_km, surge, fare_ghs,
                   eta_minutes, matched_at, pickup_otp)
values (:'trip_live', :'rider_a', :'driver_c', 'standard', 'matched',
   '{"label":"Osu","point":{"lat":5.6037,"lng":-0.1870},"address":"Osu, Accra"}',
   '{"label":"Airport Residential","point":{"lat":5.6052,"lng":-0.1660},"address":"Airport Residential, Accra"}',
   st_setsrid(st_makepoint(-0.1870, 5.6037), 4326)::geography,
   st_setsrid(st_makepoint(-0.1660, 5.6052), 4326)::geography,
   2.33, 1.00, 12.00, 9, now() - interval '3 minutes', '4417');

-- One trip per remaining trip_state value, so the SOS insert policy has an
-- allowed-state probe for all six: requested (9), matched (40), arriving (41),
-- ongoing (42), completed (37) and cancelled (38).
--
-- All three start life as `requested` and are walked to their target state
-- through enforce_trip_transition rather than being inserted into it, so the
-- fixture itself goes through the guard: requested -> matched, and on to
-- arriving and ongoing. Staging a state by insert would leave the trigger
-- untested on exactly the states the state machine cares about.
--
-- They are dedicated fixtures rather than reusing trip_live, because write probe
-- 1 below advances trip_live to `arriving` before the SOS probes run, so a probe
-- on trip_live pins `arriving` and not `matched` depending on section ordering.
-- Owned by `machine`, the rider that had no trip of its own until now, so no
-- section 3 trip listing changes.
insert into trips (id, rider_id, category, state, pickup, dropoff, pickup_point,
                   dropoff_point, distance_km, surge, fare_ghs, eta_minutes)
values (:'trip_mtc', :'machine', 'standard', 'requested',
   '{"label":"Osu","point":{"lat":5.6037,"lng":-0.1870},"address":"Osu, Accra"}',
   '{"label":"Airport Residential","point":{"lat":5.6052,"lng":-0.1660},"address":"Airport Residential, Accra"}',
   st_setsrid(st_makepoint(-0.1870, 5.6037), 4326)::geography,
   st_setsrid(st_makepoint(-0.1660, 5.6052), 4326)::geography,
   2.33, 1.00, 12.00, 9),
 (:'trip_arr', :'machine', 'standard', 'requested',
   '{"label":"Osu","point":{"lat":5.6037,"lng":-0.1870},"address":"Osu, Accra"}',
   '{"label":"Airport Residential","point":{"lat":5.6052,"lng":-0.1660},"address":"Airport Residential, Accra"}',
   st_setsrid(st_makepoint(-0.1870, 5.6037), 4326)::geography,
   st_setsrid(st_makepoint(-0.1660, 5.6052), 4326)::geography,
   2.33, 1.00, 12.00, 9),
 (:'trip_ong', :'machine', 'standard', 'requested',
   '{"label":"Osu","point":{"lat":5.6037,"lng":-0.1870},"address":"Osu, Accra"}',
   '{"label":"Airport Residential","point":{"lat":5.6052,"lng":-0.1660},"address":"Airport Residential, Accra"}',
   st_setsrid(st_makepoint(-0.1870, 5.6037), 4326)::geography,
   st_setsrid(st_makepoint(-0.1660, 5.6052), 4326)::geography,
   2.33, 1.00, 12.00, 9);

update trips set state = 'matched', driver_id = :'driver_c', matched_at = now()
 where id in (:'trip_mtc', :'trip_arr', :'trip_ong');
update trips set state = 'arriving', eta_minutes = 4
 where id in (:'trip_arr', :'trip_ong');
update trips set state = 'ongoing', started_at = now()
 where id = :'trip_ong';

insert into offers (id, trip_id, driver_id, fare_ghs, pickup_distance_km, state, expires_at) values
  (:'offer_c', :'trip_a', :'driver_c', 12.00, 0.40, 'pending',  now() + interval '20 seconds'),
  (:'offer_d', :'trip_a', :'driver_d', 12.00, 0.90, 'pending',  now() + interval '20 seconds'),
  (:'offer_b', :'trip_b', :'driver_c', 12.00, 1.10, 'pending',  now() + interval '20 seconds'),
  (:'offer_e', :'trip_b', :'driver_d', 12.00, 1.20, 'pending',  now() + interval '20 seconds');

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
   :'trip_a' || ',' || :'trip_geo' || ',' || :'trip_live',
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
   :'trip_b' || ',' || :'trip_gone',
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
   :'offer_d' || ',' || :'offer_e',
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
-- into a callable function until its WHERE clause was column-qualified, and
-- because its ownership check is the control for a security finding.
--
-- Every probe sets request.jwt.claim.sub to the calling driver, which is how
-- the offers Edge Function calls it: the client sends the rider's or driver's
-- own JWT, so auth.uid() is that user and the SECURITY DEFINER function has a
-- real identity to check. Running these as service_role with no sub proves the
-- RPC works for a superuser, which no client ever is.
-- ---------------------------------------------------------------------------
\echo ''
\echo '-- 5. match_offers_for_trip and the single-winner accept_offer --'

-- match_offers_for_trip is revoked from anon and authenticated, so it is called
-- here as service_role, which is exactly how Task 6's request-ride Edge Function
-- calls it. The refusal for a signed-in caller is section 6 probe 36, because
-- that probe has to catch the error rather than let it abort the statement.
set local role service_role;
insert into t_rpc (seq, probe, expectation, observed) values
  (1, 'match_offers_for_trip is still callable by service_role, the Task 6 path', :'driver_c',
   (select coalesce(string_agg(driver_id::text, ',' order by driver_id::text), '<none>')
      from match_offers_for_trip(:'trip_a')));
reset role;

-- Probe 2 must run before probe 3: it proves a non-owner is refused while the
-- offer is still pending, not after it has already been accepted.
set local role authenticated;
set local request.jwt.claim.sub = :'rider_a';
insert into t_rpc (seq, probe, expectation, observed) values
  (2, 'the trip owner cannot accept a driver offer on their own trip', 'false',
   (select coalesce(accepted::text, '<no row>') from accept_offer(:'offer_c')));
reset role;

set local role authenticated;
set local request.jwt.claim.sub = :'driver_c';
insert into t_rpc (seq, probe, expectation, observed) values
  (3, 'accept_offer elects the winner', 'true|' || :'trip_a' || '|' || :'driver_c',
   (select coalesce(string_agg(
             accepted::text || '|' || coalesce(trip_id::text, '-') || '|' || coalesce(driver_id::text, '-'),
             ';'), '<no row>')
      from accept_offer(:'offer_c'))),
  (4, 're-accepting the already accepted offer loses', 'false',
   (select coalesce(accepted::text, '<no row>') from accept_offer(:'offer_c'))),
  (7, 'accept_offer on an unknown id returns false instead of raising', 'false',
   (select coalesce(accepted::text, '<no row>')
      from accept_offer('c0000000-0000-4000-8000-0000000000ff')));
reset role;

-- Probes 5 and 6 read state the probes above just wrote, so they need their own
-- statements. Every VALUES expression in one INSERT is evaluated against the
-- snapshot that statement started with, which is a lesson worth writing down.
insert into t_rpc (seq, probe, expectation, observed) values
  (5, 'the trip is now matched to the winning driver with a vehicle attached',
   'matched|' || :'driver_c' || '|10000000-0000-4000-8000-000000000001',
   (select state::text || '|' || coalesce(driver_id::text, '-') || '|' || coalesce(vehicle_id::text, '-')
      from trips where id = :'trip_a')),
  (6, 'the losing sibling offer is released', 'released',
   (select state::text from offers where id = :'offer_d'));

set local role authenticated;
set local request.jwt.claim.sub = :'driver_d';
insert into t_rpc (seq, probe, expectation, observed) values
  (8, 'the losing driver retrying the released offer loses', 'false',
   (select coalesce(accepted::text, '<no row>') from accept_offer(:'offer_d')));
reset role;

-- An offer past its 20 second TTL must lose and must be flipped to `expired`.
update offers set expires_at = now() - interval '1 minute' where id = :'offer_b';
set local role authenticated;
set local request.jwt.claim.sub = :'driver_c';
insert into t_rpc (seq, probe, expectation, observed) values
  (9, 'an offer past its 20s TTL loses', 'false',
   (select coalesce(accepted::text, '<no row>') from accept_offer(:'offer_b')));
reset role;
insert into t_rpc (seq, probe, expectation, observed) values
  (10, 'the expired offer is flipped to state expired', 'expired',
   (select state::text from offers where id = :'offer_b'));

-- A second driver reaching for an offer that is not his.
set local role authenticated;
set local request.jwt.claim.sub = :'driver_c';
insert into t_rpc (seq, probe, expectation, observed) values
  (11, 'one driver cannot accept another driver offer', 'false',
   (select coalesce(accepted::text, '<no row>') from accept_offer(:'offer_e')));
reset role;

-- No caller identity at all. auth.uid() is null, and offers.driver_id is NOT
-- NULL, so the ownership check at migration:324 fires on `null is distinct from
-- <uuid>` and every one of these three probes is stopped there or one step
-- earlier. Probe 12 below names an offer that exists, so the ownership check is
-- what refuses it. Probes 14 and 15 name an offer id that does not exist, so
-- step 1's `if not found` at migration:304 refuses those before the locked
-- re-read is ever reached, which is why they return both ids NULL rather than
-- the trip id. None of the three reaches the re-read's IF NOT FOUND; a caller
-- matrix over owner, stranger, no-subject, anon and service_role is in the task
-- report and the re-read branch is never the exit point in it.
set local role authenticated;
set local request.jwt.claim.sub = '';
insert into t_rpc (seq, probe, expectation, observed) values
  (12, 'accept_offer with no caller identity loses', 'false',
   (select coalesce(accepted::text, '<no row>') from accept_offer(:'offer_e'))),
  (14, 'a NULL-uid caller naming an offer id that does not exist loses', 'false|-|-',
   (select coalesce(string_agg(
             accepted::text || '|' || coalesce(trip_id::text, '-') || '|' || coalesce(driver_id::text, '-'),
             ';'), '<no row>')
      from accept_offer('c0000000-0000-4000-8000-0000000000ee')));
reset role;
set local role anon;
insert into t_rpc (seq, probe, expectation, observed) values
  (15, 'the anon role, with no subject claim, naming a missing offer id loses', 'false|-|-',
   (select coalesce(string_agg(
             accepted::text || '|' || coalesce(trip_id::text, '-') || '|' || coalesce(driver_id::text, '-'),
             ';'), '<no row>')
      from accept_offer('c0000000-0000-4000-8000-0000000000ef')));
reset role;
insert into t_rpc (seq, probe, expectation, observed) values
  (13, 'the refused offer is still pending, so nobody was force-matched', 'requested|pending',
   (select (select state::text from trips where id = :'trip_b') || '|' || state::text
      from offers where id = :'offer_e'));

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
-- 6. Client write paths
--
-- Beyond the four required areas. These are the statements the Flutter
-- repositories actually issue with the signed-in user's own client, run here
-- with the same GUC pair a real request populates. The controls under test are
-- a policy predicate, a column grant and a trigger, often in combination, so
-- each probe states which one is expected to fire.
--
-- Outcomes are recorded as one of:
--   allowed          the statement wrote rows
--   no rows          the statement was permitted but matched nothing, which is
--                    what PostgREST reports as 200 with an empty body and a null
--                    error, the failure mode a driver app reports as success
--   blocked 42501    permission denied, or new row violates row-level policy
--   blocked P0001    raised by guard_profile_update
--   blocked 23514    raised by a CHECK constraint
-- ---------------------------------------------------------------------------
\echo ''
\echo '-- 6. client write paths: trip advance, SOS, chat, profile, vehicle --'

-- The probes are data, not code, so the role each one runs as travels with it.
-- widen_grant means "grant the whole table to authenticated before running this
-- row", which is how probes 22-26 show guard_profile_update holding even when
-- the column grant is not in the way. The grant is inside the transaction the
-- final rollback undoes.
create temporary table write_probe (
  ord         int primary key,
  seq         int not null,
  as_role     text not null,
  as_sub      text not null,
  widen_grant boolean not null default false,
  probe       text not null,
  expectation text not null,
  stmt        text not null
) on commit drop;

insert into write_probe (ord, seq, as_role, as_sub, widen_grant, probe, expectation, stmt) values
  -- 1-6: the driver's trip state advance, the path that silently did nothing
  -- before trips had an UPDATE policy.
  (1, 1, 'authenticated', '33333333-3333-4333-8333-333333333333', false,
   'driver advances their own matched trip to arriving', 'allowed 1 row',
   $$update trips set state = 'arriving' where id = 'a0000000-0000-4000-8000-000000000004'$$),
  (2, 2, 'authenticated', '33333333-3333-4333-8333-333333333333', false,
   'driver skipping arriving to completed hits the transition guard', 'blocked P0001',
   $$update trips set state = 'completed' where id = 'a0000000-0000-4000-8000-000000000004'$$),
  (3, 3, 'authenticated', '33333333-3333-4333-8333-333333333333', false,
   'driver advances a trip assigned to somebody else', 'no rows',
   $$update trips set state = 'arriving' where id = 'a0000000-0000-4000-8000-000000000002'$$),
  (4, 4, 'authenticated', '33333333-3333-4333-8333-333333333333', false,
   'driver rewrites fare_ghs on their own trip', 'blocked 42501',
   $$update trips set fare_ghs = 1.00 where id = 'a0000000-0000-4000-8000-000000000004'$$),
  (5, 5, 'authenticated', '33333333-3333-4333-8333-333333333333', false,
   'driver reassigns rider_id on their own trip', 'blocked 42501',
   $$update trips set rider_id = '22222222-2222-4222-8222-222222222222'
      where id = 'a0000000-0000-4000-8000-000000000004'$$),
  (6, 6, 'authenticated', '33333333-3333-4333-8333-333333333333', false,
   'driver reads and rewrites eta_minutes on their own trip', 'allowed 1 row',
   $$update trips set eta_minutes = eta_minutes
      where id = 'a0000000-0000-4000-8000-000000000004' and pickup_otp = '4417'$$),

  -- 7-10: SOS, as the rider who is party to the live trip.
  (7, 7, 'authenticated', '11111111-1111-4111-8111-111111111111', false,
   'rider raises SOS on their own in-flight trip', 'allowed 1 row',
   $$insert into sos_events (trip_id, raised_by, point, note)
      values ('a0000000-0000-4000-8000-000000000004',
              '11111111-1111-4111-8111-111111111111',
              'SRID=4326;POINT(-0.187 5.6037)'::geography, 'rider pressed SOS')$$),
  (8, 8, 'authenticated', '11111111-1111-4111-8111-111111111111', false,
   'rider raises SOS on a trip they are not party to', 'blocked 42501',
   $$insert into sos_events (trip_id, raised_by, note)
      values ('a0000000-0000-4000-8000-000000000002',
              '11111111-1111-4111-8111-111111111111', 'not my trip')$$),
  -- The rider is still waiting for a driver here: trip_b is `requested`, and
  -- TrackingController.activeTrip() includes `requested` while raiseSos fires
  -- whenever the trip is non-null. This probe used to demand `blocked 42501`,
  -- and that state gate recreated the very defect the SOS policy exists to
  -- remove. A party must be able to raise SOS in this state.
  (9, 9, 'authenticated', '22222222-2222-4222-8222-222222222222', false,
   'rider raises SOS while still waiting for a driver, on a requested trip', 'allowed 1 row',
   $$insert into sos_events (trip_id, raised_by, note)
      values ('a0000000-0000-4000-8000-000000000002',
              '22222222-2222-4222-8222-222222222222', 'nobody has accepted yet')$$),
  (10, 10, 'authenticated', '11111111-1111-4111-8111-111111111111', false,
   'rider raises SOS in somebody elses name', 'blocked 42501',
   $$insert into sos_events (trip_id, raised_by, note)
      values ('a0000000-0000-4000-8000-000000000004',
              '22222222-2222-4222-8222-222222222222', 'framed')$$),

  -- 11-12: chat. The INSERT policy used to bind sender_id only.
  (11, 11, 'authenticated', '11111111-1111-4111-8111-111111111111', false,
   'rider posts chat on their own in-flight trip', 'allowed 1 row',
   $$insert into chat_messages (trip_id, sender_id, body)
      values ('a0000000-0000-4000-8000-000000000004',
              '11111111-1111-4111-8111-111111111111', 'I am at the black gate')$$),
  (12, 12, 'authenticated', '22222222-2222-4222-8222-222222222222', false,
   'non-party posts chat into a trip they are not on', 'blocked 42501',
   $$insert into chat_messages (trip_id, sender_id, body)
      values ('a0000000-0000-4000-8000-000000000004',
              '22222222-2222-4222-8222-222222222222', 'hello from nowhere')$$),

  -- 13-14: a rider has no trip UPDATE policy, and cannot edit another profile.
  (13, 13, 'authenticated', '11111111-1111-4111-8111-111111111111', false,
   'rider advances the state of their own trip', 'no rows',
   $$update trips set state = 'cancelled' where id = 'a0000000-0000-4000-8000-000000000001'$$),
  (14, 14, 'authenticated', '11111111-1111-4111-8111-111111111111', false,
   'rider edits another profile row', 'no rows',
   $$update profiles set full_name = 'hijacked'
      where id = '22222222-2222-4222-8222-222222222222'$$),

  -- 15-16: exactly the columns the driver repository is allowed to write.
  (15, 15, 'authenticated', '33333333-3333-4333-8333-333333333333', false,
   'driver updates the columns submitGhanaCard and setAvailability write', 'allowed 1 row',
   $$update profiles
        set full_name = 'Yaa Asantewaa', phone = '+233200000003',
            ghana_card_last4 = '1234', ghana_card_expiry = '09/29',
            selfie_url = 'https://example.test/selfie.jpg', availability = 'online'
      where id = '33333333-3333-4333-8333-333333333333'$$),
  (16, 16, 'authenticated', '55555555-5555-4555-8555-555555555555', false,
   'driver moves their own kyc_status to pending', 'allowed 1 row',
   $$update profiles set kyc_status = 'pending'
      where id = '55555555-5555-4555-8555-555555555555'$$),

  -- 17-19: the escalation chain as a client can attempt it today. The column
  -- grant is the control that fires.
  (17, 17, 'authenticated', '33333333-3333-4333-8333-333333333333', false,
   'self-escalation: set role = admin', 'blocked 42501',
   $$update profiles set role = 'admin'
      where id = '33333333-3333-4333-8333-333333333333'$$),
  -- kyc_status is a granted column, so guard_profile_update is the control that
  -- fires here, not the grant. signup_d starts at notStarted, so this is a real
  -- transition and not a no-op.
  (18, 18, 'authenticated', '88888888-8888-4888-8888-888888888888', false,
   'self-escalation: set kyc_status = approved', 'blocked P0001',
   $$update profiles set kyc_status = 'approved'
      where id = '88888888-8888-4888-8888-888888888888'$$),
  (19, 19, 'authenticated', '33333333-3333-4333-8333-333333333333', false,
   'self-escalation: set rating and trip_count', 'blocked 42501',
   $$update profiles set rating = 5.0, trip_count = 9999
      where id = '33333333-3333-4333-8333-333333333333'$$),

  -- 20-24: the same four columns again, with the column grant removed from the
  -- picture, to show guard_profile_update is a real second control.
  (20, 20, 'authenticated', '55555555-5555-4555-8555-555555555555', true,
   'with a table-level grant, kyc_status = rejected is still blocked', 'blocked P0001',
   $$update profiles set kyc_status = 'rejected'
      where id = '55555555-5555-4555-8555-555555555555'$$),
  (21, 21, 'authenticated', '33333333-3333-4333-8333-333333333333', false,
   'with a table-level grant, role = admin is still blocked', 'blocked P0001',
   $$update profiles set role = 'admin'
      where id = '33333333-3333-4333-8333-333333333333'$$),
  (22, 22, 'authenticated', '33333333-3333-4333-8333-333333333333', false,
   'with a table-level grant, rating is still blocked', 'blocked P0001',
   $$update profiles set rating = 1.0
      where id = '33333333-3333-4333-8333-333333333333'$$),
  (23, 23, 'authenticated', '33333333-3333-4333-8333-333333333333', false,
   'with a table-level grant, trip_count is still blocked', 'blocked P0001',
   $$update profiles set trip_count = 9999
      where id = '33333333-3333-4333-8333-333333333333'$$),
  (24, 24, 'authenticated', '33333333-3333-4333-8333-333333333333', false,
   'with a table-level grant the allowed columns still write', 'allowed 1 row',
   $$update profiles set full_name = 'Yaa Asantewaa II'
      where id = '33333333-3333-4333-8333-333333333333'$$),

  -- 25: service_role keeps the admin KYC path open, so the trigger is an
  -- escalation guard and not a blanket refusal.
  (25, 25, 'service_role', '', false,
   'service_role approves KYC and flips availability', 'allowed 1 row',
   $$update profiles set kyc_status = 'approved', availability = 'online'
      where id = '33333333-3333-4333-8333-333333333333'$$),

  -- 26-30: vehicles and locations. approved is pinned false by the policy, so a
  -- driver cannot create or promote the row match_offers_for_trip joins on.
  (26, 26, 'authenticated', '66666666-6666-4666-8666-666666666666', false,
   'driver inserts their own vehicle, honestly unapproved', 'allowed 1 row',
   $$insert into vehicles (id, owner_id, vehicle_category, ride_category, make, model, plate, seats, approved)
      values ('10000000-0000-4000-8000-0000000000c1',
              '66666666-6666-4666-8666-666666666666', 'sedan', 'standard',
              'Toyota', 'Corolla', 'GH-9999-23', 4, false)$$),
  (27, 27, 'authenticated', '66666666-6666-4666-8666-666666666666', false,
   'driver can read the vehicle they just saved, as saveVehicle does', 'allowed 1 row',
   $$update vehicles set seats = 4
      where owner_id = '66666666-6666-4666-8666-666666666666'$$),
  (28, 28, 'authenticated', '33333333-3333-4333-8333-333333333333', false,
   'driver inserts a vehicle pre-approved by themself', 'blocked 42501',
   $$insert into vehicles (id, owner_id, vehicle_category, ride_category, make, model, plate, seats, approved)
      values ('10000000-0000-4000-8000-0000000000c2',
              '33333333-3333-4333-8333-333333333333', 'sedan', 'standard',
              'Toyota', 'Corolla', 'GH-9998-23', 4, true)$$),
  (29, 29, 'authenticated', '33333333-3333-4333-8333-333333333333', false,
   'driver flips their own existing vehicle to approved', 'blocked 42501',
   $$update vehicles set approved = true
      where id = '10000000-0000-4000-8000-000000000001'$$),
  (30, 30, 'authenticated', '33333333-3333-4333-8333-333333333333', false,
   'saveVehicle honest payload re-saves the vehicle unapproved', 'allowed 1 row',
   $$update vehicles set make = 'Toyota', model = 'Corolla', approved = false
      where id = '10000000-0000-4000-8000-000000000001'$$),
  (31, 31, 'authenticated', '44444444-4444-4444-8444-444444444444', false,
   'driver edits a vehicle owned by somebody else', 'no rows',
   $$update vehicles set make = 'stolen' where id = '10000000-0000-4000-8000-0000000000c1'$$),
  -- The vehicle in 0002 is admin-approved, so its owner is visible to the USING
  -- clause but the WITH CHECK refuses any write. That is the review-mandated
  -- predicate, and it means an approved vehicle is read-only from a client.
  (32, 32, 'authenticated', '44444444-4444-4444-8444-444444444444', false,
   'an admin-approved vehicle is immutable from the client', 'blocked 42501',
   $$update vehicles set make = 'Toyota RAV4' where id = '10000000-0000-4000-8000-000000000002'$$),

  -- 31-32: locations.
  (33, 33, 'authenticated', '88888888-8888-4888-8888-888888888888', false,
   'driver writes a location row for themselves', 'allowed 1 row',
   $$insert into driver_locations (driver_id, point, heading)
      values ('88888888-8888-4888-8888-888888888888',
              'SRID=4326;POINT(-1.6 6.6)'::geography, 90.00)$$),
  (34, 34, 'authenticated', '33333333-3333-4333-8333-333333333333', false,
   'driver writes a location row for somebody else', 'blocked 42501',
   $$insert into driver_locations (driver_id, point)
      values ('22222222-2222-4222-8222-222222222222',
              'SRID=4326;POINT(-0.187 5.6037)'::geography)$$),

  -- 33: the anon key that ships in the APK has no UPDATE on trips at all.
  (35, 35, 'anon', '', false,
   'anon key updates a trip', 'blocked 42501',
   $$update trips set state = 'completed' where id = 'a0000000-0000-4000-8000-000000000004'$$),
  -- The last unguarded SECURITY DEFINER surface. A signed-in caller with a real
  -- subject must be refused outright, not quietly given an empty candidate list,
  -- so the expected outcome is the permission error itself and the runner records
  -- the SQLSTATE rather than swallowing it. The service-role half of this pair is
  -- section 5 probe 1.
  (36, 36, 'authenticated', '11111111-1111-4111-8111-111111111111', false,
   'a signed-in rider cannot read the driver candidate list for a trip', 'blocked 42501',
   $$select * from match_offers_for_trip('a0000000-0000-4000-8000-000000000001')$$),
  -- The SOS policy carries no state clause at all, matching the ungated read
  -- policy on the same table. There is one allowed-state SOS probe per
  -- trip_state value, each on a fixture dedicated to that state so the coverage
  -- does not depend on the order this section runs in: requested (9), matched
  -- (40), arriving (41), ongoing (42), completed (37) and cancelled (38). A
  -- variant that adds a state clause excluding any one of the six turns that
  -- state's probe red.
  (37, 37, 'authenticated', '11111111-1111-4111-8111-111111111111', false,
   'the SOS policy carries no state gate, so a completed trip is allowed too', 'allowed 1 row',
   $$insert into sos_events (trip_id, raised_by, note)
      values ('a0000000-0000-4000-8000-000000000003',
              '11111111-1111-4111-8111-111111111111', 'that trip is over')$$),
  (38, 38, 'authenticated', '22222222-2222-4222-8222-222222222222', false,
   'the sixth state, cancelled, is allowed too, so no state clause can hide', 'allowed 1 row',
   $$insert into sos_events (trip_id, raised_by, note)
      values ('a0000000-0000-4000-8000-000000000005',
              '22222222-2222-4222-8222-222222222222', 'reporting after cancelling')$$),
  -- Every other SOS probe runs as a rider, so the policy's
  -- `or t.driver_id = auth.uid()` branch had no coverage at all. driver_c is the
  -- driver on trip_live, so this is the driver side of that disjunction.
  (39, 39, 'authenticated', '33333333-3333-4333-8333-333333333333', false,
   'the driver side of the SOS party check is allowed, not only the rider side', 'allowed 1 row',
   $$insert into sos_events (trip_id, raised_by, point, note)
      values ('a0000000-0000-4000-8000-000000000004',
              '33333333-3333-4333-8333-333333333333',
              'SRID=4326;POINT(-0.187 5.6037)'::geography, 'driver pressed SOS')$$),
  -- The three states no SOS probe pinned before these existed: `ongoing` had no
  -- fixture at all, and `matched` and `arriving` were covered only by accident,
  -- through trip_live before and after write probe 1 advances it to `arriving`,
  -- so the coverage depended on the order this section runs in. A dedicated
  -- fixture per state is what removes that dependency. All three trips reached
  -- their state through enforce_trip_transition in the fixture setup above.
  (40, 40, 'authenticated', '99999999-9999-4999-8999-999999999999', false,
   'a matched trip is allowed, so a state clause cannot exclude matched', 'allowed 1 row',
   $$insert into sos_events (trip_id, raised_by, note)
      values ('a0000000-0000-4000-8000-000000000008',
              '99999999-9999-4999-8999-999999999999', 'driver assigned, not yet arrived')$$),
  (41, 41, 'authenticated', '99999999-9999-4999-8999-999999999999', false,
   'an arriving trip is allowed, so a state clause cannot exclude arriving', 'allowed 1 row',
   $$insert into sos_events (trip_id, raised_by, note)
      values ('a0000000-0000-4000-8000-000000000006',
              '99999999-9999-4999-8999-999999999999', 'driver on the way')$$),
  (42, 42, 'authenticated', '99999999-9999-4999-8999-999999999999', false,
   'an ongoing trip is allowed, so a state clause cannot exclude ongoing', 'allowed 1 row',
   $$insert into sos_events (trip_id, raised_by, note)
      values ('a0000000-0000-4000-8000-000000000007',
              '99999999-9999-4999-8999-999999999999', 'in the middle of the trip')$$);

do $$
declare
  r         record;
  v_rows    int;
  v_out     text;
  v_widened boolean := false;
begin
  for r in select * from write_probe order by ord loop
    if r.widen_grant and not v_widened then
      perform set_config('role', 'postgres', true);
      grant update on profiles to authenticated;
      v_widened := true;
    end if;

    perform set_config('role', r.as_role, true);
    perform set_config('request.jwt.claim.sub', r.as_sub, true);

    v_rows := 0;
    v_out  := 'no statement ran';
    begin
      execute r.stmt;
      get diagnostics v_rows = row_count;
      v_out := case when v_rows = 0 then 'no rows'
                    else 'allowed ' || v_rows || ' row' end;
    exception when others then
      v_out := 'blocked ' || sqlstate;
    end;

    insert into t_write (seq, probe, expectation, observed) values
      (r.seq, r.probe, r.expectation, v_out);
  end loop;

  perform set_config('role', 'postgres', true);
end
$$;

-- 43-45: reads the removed driver directory policy used to expose. With no
-- role = 'driver' SELECT policy, a signed-in rider sees exactly one profiles
-- row, their own, and the anon key that ships in the APK sees none.
set local role authenticated;
set local request.jwt.claim.sub = :'rider_a';
insert into t_write (seq, probe, expectation, observed) values
  (43, 'a rider sees no driver rows through the profiles table', '0',
   (select count(*)::text from profiles where role = 'driver')),
  (44, 'a rider sees only their own profiles row', '1',
   (select count(*)::text from profiles));
reset role;
set local role anon;
set local request.jwt.claim.sub = '';
insert into t_write (seq, probe, expectation, observed) values
  (45, 'the anon key reads no profiles row at all, so no KYC PII leaks', '0',
   (select count(*)::text from profiles));
reset role;

-- 46-47: the signup path. handle_new_user ran when the fixture inserted these
-- two auth.users rows, and every other column took its default.
insert into t_write (seq, probe, expectation, observed) values
  (46, 'a signup asking for role admin gets a rider', 'rider',
   (select role::text from profiles where id = :'signup_x')),
  (47, 'a signup asking for role driver gets a driver with default KYC', 'driver|notStarted|5.0|0',
   (select role::text || '|' || kyc_status::text || '|' || rating::text || '|' || trip_count::text
      from profiles where id = :'signup_d'));

update t_write set passed = (observed = expectation);

select seq, probe, expectation, observed,
       case when passed then 'PASS' else 'FAIL' end as verdict
  from t_write
 order by seq;

\echo ''
\echo '-- 6b. write-path tallies --'
select count(*) as probes,
       count(*) filter (where passed) as passed,
       count(*) filter (where not passed) as failed
  from t_write;

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
union all
select 'client write paths', count(*), count(*) filter (where passed),
       count(*) filter (where not passed) from t_write
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
    union all
    select passed from t_write where not passed
  ) failures;

  select (select count(*) from t_transition)
       + (select count(*) from t_demo)
       + (select count(*) from t_rls)
       + (select count(*) from t_geo)
       + (select count(*) from t_rpc)
       + (select count(*) from t_write)
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
