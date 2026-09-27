-- Authorization facts that the offers Edge Function's comments assert.
--
-- Every probe reports its observation as a row. Nothing depends on RAISE
-- NOTICE, which a remote dblink backend discards anyway, and no probe reads an
-- RPC result inside its own assertion, because `accept_offer` has side effects
-- and calling it twice would corrupt the thing under test. Each accept runs
-- once, inside its own DO block, and the assertion reads the committed state
-- afterwards.
--
-- Fixture map. Offers with an even sequence number belong to driver
-- ...0002 and odd ones to driver ...0003, so every trip carries one offer for
-- each driver. Each probe gets a trip no earlier probe accepted on, because
-- `enforce_trip_transition` refuses every self-transition, so a helper cannot
-- put a trip back to `requested` and no trip can be reused after a win.
--
--   trip 1 offer ...0001 (driver 3)   probes 1, 2   anon and service_role, both refused
--   trip 2 offer ...0002 (driver 2)   probe 3       the offer's own driver wins
--   trip 3 offer ...0003 (driver 3)   probe 4       the other driver (driver 2) is refused
--   trip 4 offer ...0004 (driver 2)   probe 5       the trip's own rider is refused
--   trip 5 offer ...0005 (driver 3)   probes 6-8    the decline write
--   trip 6 offer ...0006 (driver 2)   probe 9       the expiry boundary
--
-- Usage:
--   sudo -u postgres psql -d mng_test -v ON_ERROR_STOP=1 \
--     -f supabase/tests/verify_offer_authz.sql

\set ON_ERROR_STOP on
\pset pager off

\echo ''
\echo '== offers function: who may accept, who may decline =='
\echo ''

drop table if exists t_authz;
create temporary table t_authz (
  seq         int primary key,
  probe       text not null,
  expectation text not null,
  observed    text not null,
  passed      boolean
);

create or replace function pg_temp.fresh_offers(p_trip int)
returns void language plpgsql as $$
begin
  update offers set state = 'pending',
       expires_at = case when p_trip = 6 then now() else now() + interval '20 seconds' end
   where trip_id = ('d7d7d7d7-0000-4000-8000-00000000000' || p_trip::text)::uuid;
end $$;

-- ---------------------------------------------------------------------------
-- Committed fixtures
-- ---------------------------------------------------------------------------
delete from offers           where id::text like 'd7d7d7d7-%';
delete from trips            where id::text like 'd7d7d7d7-%';
delete from driver_locations where driver_id::text like 'd7d7d7d7-%';
delete from vehicles         where id::text like 'd7d7d7d7-%';
delete from profiles         where id::text like 'd7d7d7d7-%';
delete from auth.users       where id::text like 'd7d7d7d7-%';

insert into auth.users (id, email, raw_user_meta_data) values
  ('d7d7d7d7-0000-4000-8000-000000000001', 'authz.rider@example.com', '{"role":"rider"}'),
  ('d7d7d7d7-0000-4000-8000-000000000002', 'authz.d1@example.com',   '{"role":"driver"}'),
  ('d7d7d7d7-0000-4000-8000-000000000003', 'authz.d2@example.com',   '{"role":"driver"}');

update profiles set full_name = 'Authz Rider', phone = '+233200000201'
 where id = 'd7d7d7d7-0000-4000-8000-000000000001';
update profiles set full_name = 'Authz Driver One', phone = '+233200000202',
                    kyc_status = 'approved', availability = 'online'
 where id = 'd7d7d7d7-0000-4000-8000-000000000002';
update profiles set full_name = 'Authz Driver Two', phone = '+233200000203',
                    kyc_status = 'approved', availability = 'online'
 where id = 'd7d7d7d7-0000-4000-8000-000000000003';

insert into vehicles (id, owner_id, vehicle_category, ride_category, make, model, plate, seats, approved) values
  ('d7d7d7d7-0000-4000-8000-0000000000a1', 'd7d7d7d7-0000-4000-8000-000000000002', 'sedan', 'standard', 'Toyota', 'Corolla', 'GH-7001-24', 4, true),
  ('d7d7d7d7-0000-4000-8000-0000000000a2', 'd7d7d7d7-0000-4000-8000-000000000003', 'sedan', 'standard', 'Toyota', 'Corolla', 'GH-7002-24', 4, true);

insert into trips (id, rider_id, category, state, pickup, dropoff, pickup_point, dropoff_point, distance_km, surge, fare_ghs)
select ('d7d7d7d7-0000-4000-8000-00000000000' || g::text)::uuid,
       'd7d7d7d7-0000-4000-8000-000000000001', 'standard', 'requested',
       '{"label":"Osu","point":{"lat":5.6037,"lng":-0.1870},"address":"Osu, Accra"}',
       '{"label":"Airport Residential","point":{"lat":5.6052,"lng":-0.1660},"address":"Airport Residential, Accra"}',
       'SRID=4326;POINT(-0.187 5.6037)'::geography, 'SRID=4326;POINT(-0.166 5.6052)'::geography,
       2.33, 1.00, 12.00
from generate_series(1, 6) g;

insert into offers (id, trip_id, driver_id, fare_ghs, pickup_distance_km, state, expires_at)
select ('d7d7d7d7-0000-4000-8000-0000000000' || lpad(g::text, 2, '0'))::uuid,
       ('d7d7d7d7-0000-4000-8000-00000000000' || g::text)::uuid,
       case when g % 2 = 0 then 'd7d7d7d7-0000-4000-8000-000000000002'::uuid
            else 'd7d7d7d7-0000-4000-8000-000000000003'::uuid end,
       12.00, 0.40, 'pending', now() + interval '20 seconds'
from generate_series(1, 6) g;

-- A second, competing offer on trip 2 so probe 3 can measure the sibling
-- release rather than assert it.
insert into offers (id, trip_id, driver_id, fare_ghs, pickup_distance_km, state, expires_at) values
  ('d7d7d7d7-0000-4000-8000-0000000000f2', 'd7d7d7d7-0000-4000-8000-000000000002',
   'd7d7d7d7-0000-4000-8000-000000000003', 12.00, 0.55, 'pending', now() + interval '20 seconds');

\echo '-- fixture shape --'
select trip_id::text as trip, id::text as offer, driver_id::text as driver, state::text
  from offers order by trip_id;

-- ---------------------------------------------------------------------------
-- 1 and 2. A request with no `sub` claim has no identity, and is refused
-- ---------------------------------------------------------------------------
\echo ''
\echo '-- 1/2. no sub claim: anon and service_role are both refused --'

do $$
declare v_uid text; v_res text; v_trip text; v_state text;
begin
  perform pg_temp.fresh_offers(1);
  set local role anon;
  select coalesce(auth.uid()::text, 'NULL') into v_uid;
  select accepted::text || ' / ' || coalesce(trip_id::text, 'NULL') || ' / ' || coalesce(driver_id::text, 'NULL')
    into v_res from accept_offer('d7d7d7d7-0000-4000-8000-000000000001');
  reset role;
  select state::text into v_trip from trips where id = 'd7d7d7d7-0000-4000-8000-000000000001';
  select state::text into v_state from offers where id = 'd7d7d7d7-0000-4000-8000-000000000001';
  insert into t_authz values (1, 'anon (no sub claim) is refused by accept_offer',
    'uid NULL, accepted false, both ids null, nothing written',
    'uid=' || v_uid || ' result=' || v_res || ' trip=' || v_trip || ' offer=' || v_state,
    v_uid = 'NULL' and v_res = 'false / NULL / NULL' and v_trip = 'requested' and v_state = 'pending');
end $$;

do $$
declare v_uid text; v_res text; v_trip text; v_state text;
begin
  perform pg_temp.fresh_offers(1);
  set local role service_role;
  select coalesce(auth.uid()::text, 'NULL') into v_uid;
  select accepted::text || ' / ' || coalesce(trip_id::text, 'NULL') || ' / ' || coalesce(driver_id::text, 'NULL')
    into v_res from accept_offer('d7d7d7d7-0000-4000-8000-000000000001');
  reset role;
  select state::text into v_trip from trips where id = 'd7d7d7d7-0000-4000-8000-000000000001';
  select state::text into v_state from offers where id = 'd7d7d7d7-0000-4000-8000-000000000001';
  insert into t_authz values (2, 'service_role (no sub claim) is refused by accept_offer',
    'uid NULL, accepted false, both ids null, nothing written',
    'uid=' || v_uid || ' result=' || v_res || ' trip=' || v_trip || ' offer=' || v_state,
    v_uid = 'NULL' and v_res = 'false / NULL / NULL' and v_trip = 'requested' and v_state = 'pending');
end $$;

-- ---------------------------------------------------------------------------
-- 3. The offer's own driver wins; the trip matches to them; siblings release
-- ---------------------------------------------------------------------------
\echo ''
\echo '-- 3. the offer''s own driver --'
do $$
declare v_res text;
begin
  perform pg_temp.fresh_offers(2);
  set local role authenticated;
  set local request.jwt.claim.sub = 'd7d7d7d7-0000-4000-8000-000000000002';
  select accepted::text || ' / ' || coalesce(trip_id::text, 'NULL') || ' / ' || coalesce(driver_id::text, 'NULL')
    into v_res from accept_offer('d7d7d7d7-0000-4000-8000-000000000002');
  reset role;
  insert into t_authz values (3, 'the offer''s own driver wins',
    'accepted true, trip matched to that driver, offers split 1 accepted + 1 released',
    'result=' || v_res
      || ' trip=' || (select state::text || ' driver=' || coalesce(driver_id::text,'NULL') from trips where id = 'd7d7d7d7-0000-4000-8000-000000000002')
      || ' offers=' || (select string_agg(state::text || '=' || c, ',' order by state::text)
                           from (select state, count(*) c from offers
                                 where trip_id = 'd7d7d7d7-0000-4000-8000-000000000002' group by state) s),
    v_res = 'true / d7d7d7d7-0000-4000-8000-000000000002 / d7d7d7d7-0000-4000-8000-000000000002'
      and (select state = 'matched' and driver_id = 'd7d7d7d7-0000-4000-8000-000000000002'
             from trips where id = 'd7d7d7d7-0000-4000-8000-000000000002')
      and 1 = (select count(*) from offers where trip_id = 'd7d7d7d7-0000-4000-8000-000000000002' and state = 'accepted')
      and 1 = (select count(*) from offers where trip_id = 'd7d7d7d7-0000-4000-8000-000000000002' and state = 'released')
      and 0 = (select count(*) from offers where trip_id = 'd7d7d7d7-0000-4000-8000-000000000002' and state = 'pending'));
end $$;

-- ---------------------------------------------------------------------------
-- 4. A different driver is refused
-- ---------------------------------------------------------------------------
\echo ''
\echo '-- 4. a different driver --'
do $$
declare v_res text; v_trip text; v_state text;
begin
  perform pg_temp.fresh_offers(3);
  set local role authenticated;
  set local request.jwt.claim.sub = 'd7d7d7d7-0000-4000-8000-000000000002';
  select accepted::text || ' / ' || coalesce(trip_id::text, 'NULL') || ' / ' || coalesce(driver_id::text, 'NULL')
    into v_res from accept_offer('d7d7d7d7-0000-4000-8000-000000000003');
  reset role;
  select state::text into v_trip from trips where id = 'd7d7d7d7-0000-4000-8000-000000000003';
  select state::text into v_state from offers where id = 'd7d7d7d7-0000-4000-8000-000000000003';
  insert into t_authz values (4, 'the other driver is refused their colleague''s offer',
    'accepted false, both ids null, offer still pending, trip still requested',
    'result=' || v_res || ' trip=' || v_trip || ' offer=' || v_state,
    v_res = 'false / NULL / NULL' and v_trip = 'requested' and v_state = 'pending');
end $$;

-- ---------------------------------------------------------------------------
-- 5. The trip's own rider can READ the offers, and still cannot accept
-- ---------------------------------------------------------------------------
\echo ''
\echo '-- 5. the trip''s own rider --'
do $$
declare v_reads int; v_res text; v_trip text;
begin
  perform pg_temp.fresh_offers(4);
  set local role authenticated;
  set local request.jwt.claim.sub = 'd7d7d7d7-0000-4000-8000-000000000001';
  select count(*) into v_reads from offers where trip_id = 'd7d7d7d7-0000-4000-8000-000000000004';
  select accepted::text || ' / ' || coalesce(trip_id::text, 'NULL') || ' / ' || coalesce(driver_id::text, 'NULL')
    into v_res from accept_offer('d7d7d7d7-0000-4000-8000-000000000004');
  reset role;
  select state::text into v_trip from trips where id = 'd7d7d7d7-0000-4000-8000-000000000004';
  insert into t_authz values (5, 'the trip''s own rider can READ the offers and is still refused',
    'rider reads 1 offer, accept_offer answers false with both ids null, trip untouched',
    'rider_reads=' || v_reads || ' result=' || v_res || ' trip=' || v_trip,
    v_reads = 1 and v_res = 'false / NULL / NULL' and v_trip = 'requested');
end $$;

-- ---------------------------------------------------------------------------
-- 6, 7, 8. The decline write
-- ---------------------------------------------------------------------------
\echo ''
\echo '-- 6/7/8. the decline UPDATE --'

do $$
declare v_reads int; v_updated int; v_state text;
begin
  perform pg_temp.fresh_offers(5);
  set local role authenticated;
  set local request.jwt.claim.sub = 'd7d7d7d7-0000-4000-8000-000000000003';
  select count(*) into v_reads from offers where id = 'd7d7d7d7-0000-4000-8000-000000000003';
  update offers set state = 'declined'
   where id = 'd7d7d7d7-0000-4000-8000-000000000003' and driver_id = 'd7d7d7d7-0000-4000-8000-000000000003';
  get diagnostics v_updated = row_count;
  reset role;
  select state::text into v_state from offers where id = 'd7d7d7d7-0000-4000-8000-000000000003';
  insert into t_authz values (6, 'the decline UPDATE as authenticated matches zero rows',
    'the same driver SELECTs 1 row, UPDATEs 0, and the offer is untouched',
    'selects=' || v_reads || ' updated=' || v_updated || ' state_after=' || v_state,
    v_reads = 1 and v_updated = 0 and v_state = 'pending');
end $$;

do $$
declare v_updated int; v_reads int;
begin
  perform pg_temp.fresh_offers(5);
  set local role service_role;
  update offers set state = 'declined'
   where id = 'd7d7d7d7-0000-4000-8000-000000000003' and driver_id = 'd7d7d7d7-0000-4000-8000-000000000003';
  get diagnostics v_updated = row_count;
  reset role;
  set local role authenticated;
  set local request.jwt.claim.sub = 'd7d7d7d7-0000-4000-8000-000000000003';
  select count(*) into v_reads from offers where id = 'd7d7d7d7-0000-4000-8000-000000000003' and state = 'declined';
  reset role;
  insert into t_authz values (7, 'the identical decline UPDATE as service_role matches one row',
    'updated 1, and the driver then reads it back as declined',
    'updated=' || v_updated || ' driver_sees_declined=' || v_reads,
    v_updated = 1 and v_reads = 1);
end $$;

-- The three filters the handler puts on the write, and each refusing on its own.
do $$
declare v_a int; v_b int; v_c int; v_state text;
begin
  perform pg_temp.fresh_offers(5);
  set local role service_role;
  update offers set state = 'declined'
   where id = 'd7d7d7d7-0000-4000-8000-000000000099' and driver_id = 'd7d7d7d7-0000-4000-8000-000000000003' and state = 'pending';
  get diagnostics v_a = row_count;
  update offers set state = 'declined'
   where id = 'd7d7d7d7-0000-4000-8000-000000000003' and driver_id = 'd7d7d7d7-0000-4000-8000-000000000099' and state = 'pending';
  get diagnostics v_b = row_count;
  update offers set state = 'expired' where id = 'd7d7d7d7-0000-4000-8000-000000000003';
  update offers set state = 'declined'
   where id = 'd7d7d7d7-0000-4000-8000-000000000003' and driver_id = 'd7d7d7d7-0000-4000-8000-000000000003' and state = 'pending';
  get diagnostics v_c = row_count;
  reset role;
  select state::text into v_state from offers where id = 'd7d7d7d7-0000-4000-8000-000000000003';
  insert into t_authz values (8, 'the id, driver_id and state filters each refuse on their own',
    'unknown id 0, wrong driver 0, non-pending 0, and the state is left alone',
    'unknown_id=' || v_a || ' wrong_driver=' || v_b || ' not_pending=' || v_c || ' state=' || v_state,
    v_a = 0 and v_b = 0 and v_c = 0 and v_state = 'expired');
end $$;

-- ---------------------------------------------------------------------------
-- 9. The expiry boundary is inclusive, matching the RPC's `expires_at <= now()`
-- ---------------------------------------------------------------------------
\echo ''
\echo '-- 9. the expiry boundary --'
do $$
declare v_res text; v_state text; v_exp text;
begin
  perform pg_temp.fresh_offers(6);  -- trip 6's offers get expires_at = now()
  set local role authenticated;
  set local request.jwt.claim.sub = 'd7d7d7d7-0000-4000-8000-000000000002';
  select accepted::text || ' / ' || coalesce(trip_id::text, 'NULL') || ' / ' || coalesce(driver_id::text, 'NULL')
    into v_res from accept_offer('d7d7d7d7-0000-4000-8000-000000000006');
  select state::text into v_state from offers where id = 'd7d7d7d7-0000-4000-8000-000000000006';
  select (expires_at <= now())::text into v_exp from offers where id = 'd7d7d7d7-0000-4000-8000-000000000006';
  reset role;
  insert into t_authz values (9, 'an offer whose expires_at is exactly now() is refused',
    'expires_at <= now() is true, accepted false, trip_id echoed, offer moved to expired',
    'expires_at<=now=' || v_exp || ' result=' || v_res || ' offer_state=' || v_state,
    v_exp = 'true' and v_res = 'false / d7d7d7d7-0000-4000-8000-000000000006 / NULL' and v_state = 'expired');
end $$;

-- ---------------------------------------------------------------------------
-- 10. An offer id that does not exist is refused, not an error
-- ---------------------------------------------------------------------------
\echo ''
\echo '-- 10. an unknown offer id --'
do $$
declare v_res text;
begin
  set local role authenticated;
  set local request.jwt.claim.sub = 'd7d7d7d7-0000-4000-8000-000000000002';
  select accepted::text || ' / ' || coalesce(trip_id::text, 'NULL') || ' / ' || coalesce(driver_id::text, 'NULL')
    into v_res from accept_offer('d7d7d7d7-0000-4000-8000-0000000000ff');
  reset role;
  insert into t_authz values (10, 'an unknown offer id is refused, not an error',
    'accepted false with both ids null, and the call returns rather than raising',
    'result=' || v_res,
    v_res = 'false / NULL / NULL');
end $$;

-- ---------------------------------------------------------------------------
-- Results
-- ---------------------------------------------------------------------------
\echo ''
\echo '== results =='
select seq, passed, probe, expectation, observed from t_authz order by seq;

\echo ''
select count(*) as probes,
       count(*) filter (where passed) as passed,
       count(*) filter (where not passed) as failed
  from t_authz;

-- Clean up, so a clean run leaves nothing behind.
delete from offers           where id::text like 'd7d7d7d7-%';
delete from trips            where id::text like 'd7d7d7d7-%';
delete from driver_locations where driver_id::text like 'd7d7d7d7-%';
delete from vehicles         where id::text like 'd7d7d7d7-%';
delete from profiles         where id::text like 'd7d7d7d7-%';
delete from auth.users       where id::text like 'd7d7d7d7-%';
