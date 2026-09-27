-- Two real backends, one lock at a time.
--
-- Finding: accept_offer used to lock its own offer row first and the trip row
-- second, while the winner's sibling-release UPDATE also needed every losing
-- offer row. Two accepts on two different offers of the same trip therefore took
-- locks in opposite orders and Postgres aborted one of them with SQLSTATE 40P01,
-- so the loser saw a PostgREST 500 rather than `false`.
--
-- reasoning about lock order is not evidence. This file uses dblink to get two
-- genuinely concurrent sessions and measures two things:
--
--   A. The contract. Two sessions accept two different offers of the same trip
--      at the same time. Exactly one is accepted, the other returns false, the
--      trip is matched to the winner alone, and neither session reports 40P01.
--
--   B. What a blocked accept_offer is actually waiting on. The main session
--      takes the trip row lock, so the far-side call blocks. pg_stat_activity
--      and pg_locks say it is queued on another transaction's row rather than
--      on a table, and that the only row it has engaged with is the trip.
--
--   C. That holding the offer row instead does not break the call.
--
-- Section A is the proof of the ordering, and it is a real race rather than a
-- staged one. Reinstalling the old lock order and re-running this file
-- reproduces `ERROR: deadlock detected` with SQLSTATE 40P01 in the sibling
-- release, which is the defect the fix removes. The intermediate lock state
-- where the two orders differ is not observable from outside a backend, so no
-- probe here claims to have measured it.
--
-- The fixtures here are committed rather than rolled back, because a dblink
-- backend is a separate session and cannot see another session's uncommitted
-- rows. Every row this file creates is deleted at the end, so a clean run leaves
-- nothing behind. A run that dies part way leaves rows that the next
-- `harness.sql` run clears with `drop schema public cascade`.
--
-- Usage:
--   sudo -u postgres psql -d mng_test -v ON_ERROR_STOP=1 \
--     -f supabase/tests/verify_concurrency.sql

\set ON_ERROR_STOP on
\pset pager off

\echo ''
\echo '== accept_offer under two concurrent sessions =='
\echo ''

create temporary table t_conc (
  seq         int primary key,
  probe       text not null,
  expectation text not null,
  observed    text not null,
  passed      boolean
);

-- ---------------------------------------------------------------------------
-- Committed fixtures
-- ---------------------------------------------------------------------------
\echo '-- committed fixtures: one requested trip, two competing pending offers --'
-- Clear anything a previous run left, in foreign key order, so the file is
-- re-runnable after a failure part way through.
delete from offers           where id::text like 'c0c0c0c0-%';
delete from trips            where id::text like 'c0c0c0c0-%';
delete from driver_locations where driver_id::text like 'c0c0c0c0-%';
delete from vehicles         where id::text like 'c0c0c0c0-%';
delete from profiles         where id::text like 'c0c0c0c0-%';
delete from auth.users       where id::text like 'c0c0c0c0-%';

insert into auth.users (id, email, raw_user_meta_data) values
  ('c0c0c0c0-0000-4000-8000-000000000001', 'conc.rider@example.com',  '{"role":"rider"}'),
  ('c0c0c0c0-0000-4000-8000-000000000002', 'conc.d1@example.com',   '{"role":"driver"}'),
  ('c0c0c0c0-0000-4000-8000-000000000003', 'conc.d2@example.com',   '{"role":"driver"}');

-- handle_new_user has already created these three profiles from the signup
-- metadata above, so they are updated rather than inserted.
update profiles set full_name = 'Concurrency Rider', phone = '+233200000101'
 where id = 'c0c0c0c0-0000-4000-8000-000000000001';
update profiles set full_name = 'Concurrent One', phone = '+233200000102',
                    kyc_status = 'approved', availability = 'online'
 where id = 'c0c0c0c0-0000-4000-8000-000000000002';
update profiles set full_name = 'Concurrent Two', phone = '+233200000103',
                    kyc_status = 'approved', availability = 'online'
 where id = 'c0c0c0c0-0000-4000-8000-000000000003';

insert into vehicles (id, owner_id, vehicle_category, ride_category, make, model, plate, seats, approved) values
  ('c0c0c0c0-0000-4000-8000-0000000000a1', 'c0c0c0c0-0000-4000-8000-000000000002', 'sedan', 'standard', 'Toyota', 'Corolla', 'GH-2001-24', 4, true),
  ('c0c0c0c0-0000-4000-8000-0000000000a2', 'c0c0c0c0-0000-4000-8000-000000000003', 'sedan', 'standard', 'Toyota', 'Corolla', 'GH-2002-24', 4, true);

insert into driver_locations (driver_id, point) values
  ('c0c0c0c0-0000-4000-8000-000000000002', 'SRID=4326;POINT(-0.187 5.6037)'::geography),
  ('c0c0c0c0-0000-4000-8000-000000000003', 'SRID=4326;POINT(-0.188 5.604)'::geography);

-- Trip 4 is for the concurrency contract, trip 5 for the blocked-call evidence,
-- trip 6 for the held-offer-row section. Three trips because each section's
-- accept_offer changes the state the next one starts from.
insert into trips (id, rider_id, category, state, pickup, dropoff, pickup_point, dropoff_point, distance_km, surge, fare_ghs) values
  ('c0c0c0c0-0000-4000-8000-000000000004', 'c0c0c0c0-0000-4000-8000-000000000001', 'standard', 'requested',
   '{"label":"Osu","point":{"lat":5.6037,"lng":-0.1870},"address":"Osu, Accra"}',
   '{"label":"Airport Residential","point":{"lat":5.6052,"lng":-0.1660},"address":"Airport Residential, Accra"}',
   'SRID=4326;POINT(-0.187 5.6037)'::geography, 'SRID=4326;POINT(-0.166 5.6052)'::geography,
   2.33, 1.00, 12.00),
  ('c0c0c0c0-0000-4000-8000-000000000005', 'c0c0c0c0-0000-4000-8000-000000000001', 'standard', 'requested',
   '{"label":"Osu","point":{"lat":5.6037,"lng":-0.1870},"address":"Osu, Accra"}',
   '{"label":"Airport Residential","point":{"lat":5.6052,"lng":-0.1660},"address":"Airport Residential, Accra"}',
   'SRID=4326;POINT(-0.187 5.6037)'::geography, 'SRID=4326;POINT(-0.166 5.6052)'::geography,
   2.33, 1.00, 12.00),
  ('c0c0c0c0-0000-4000-8000-000000000006', 'c0c0c0c0-0000-4000-8000-000000000001', 'standard', 'requested',
   '{"label":"Osu","point":{"lat":5.6037,"lng":-0.1870},"address":"Osu, Accra"}',
   '{"label":"Airport Residential","point":{"lat":5.6052,"lng":-0.1660},"address":"Airport Residential, Accra"}',
   'SRID=4326;POINT(-0.187 5.6037)'::geography, 'SRID=4326;POINT(-0.166 5.6052)'::geography,
   2.33, 1.00, 12.00);

insert into offers (id, trip_id, driver_id, fare_ghs, pickup_distance_km, state, expires_at) values
  ('c0c0c0c0-0000-4000-8000-00000000000a', 'c0c0c0c0-0000-4000-8000-000000000004', 'c0c0c0c0-0000-4000-8000-000000000002', 12.00, 0.40, 'pending', now() + interval '20 seconds'),
  ('c0c0c0c0-0000-4000-8000-00000000000b', 'c0c0c0c0-0000-4000-8000-000000000004', 'c0c0c0c0-0000-4000-8000-000000000003', 12.00, 0.50, 'pending', now() + interval '20 seconds'),
  ('c0c0c0c0-0000-4000-8000-00000000000c', 'c0c0c0c0-0000-4000-8000-000000000005', 'c0c0c0c0-0000-4000-8000-000000000002', 12.00, 0.40, 'pending', now() + interval '20 seconds'),
  ('c0c0c0c0-0000-4000-8000-00000000000d', 'c0c0c0c0-0000-4000-8000-000000000005', 'c0c0c0c0-0000-4000-8000-000000000003', 12.00, 0.50, 'pending', now() + interval '20 seconds'),
  ('c0c0c0c0-0000-4000-8000-00000000000e', 'c0c0c0c0-0000-4000-8000-000000000006', 'c0c0c0c0-0000-4000-8000-000000000003', 12.00, 0.60, 'pending', now() + interval '20 seconds');

select 'concurrency trip 4 offers' as probe, count(*)::text as pending_offers
  from offers where trip_id = 'c0c0c0c0-0000-4000-8000-000000000004' and state = 'pending';

-- ---------------------------------------------------------------------------
-- A. Two sessions, two offers, one trip, at the same time
-- ---------------------------------------------------------------------------
\echo ''
\echo '-- A. two backends accept two different offers of trip 4 simultaneously --'

-- One connection per query, and a third for section B. This dblink build
-- refuses dblink_send_query on a connection that has already returned a result
-- set, so nothing is reused.
select dblink_connect('w1', 'dbname=mng_test');
select dblink_connect('w2', 'dbname=mng_test');
select dblink_connect('w3', 'dbname=mng_test');

-- Each connection is the driver whose own JWT a real request would carry, so
-- auth.uid() is that driver and the ownership check inside accept_offer passes.
select dblink_exec('w1', $$set request.jwt.claim.sub = 'c0c0c0c0-0000-4000-8000-000000000002'$$);
select dblink_exec('w2', $$set request.jwt.claim.sub = 'c0c0c0c0-0000-4000-8000-000000000003'$$);

select a as w1_pid, b as w2_pid, c as w3_pid from (
  select (select pid from dblink('w1', 'select pg_backend_pid()') as t(pid int)) as a,
         (select pid from dblink('w2', 'select pg_backend_pid()') as t(pid int)) as b,
         (select pid from dblink('w3', 'select pg_backend_pid()') as t(pid int)) as c
) p \gset

-- dblink_send_query returns before the remote statement finishes, so both of
-- these are in flight at the same moment and contend for the trip row.
select dblink_send_query('w1', $$select * from accept_offer('c0c0c0c0-0000-4000-8000-00000000000a')$$);
select dblink_send_query('w2', $$select * from accept_offer('c0c0c0c0-0000-4000-8000-00000000000b')$$);

-- dblink_get_result blocks until that session finishes.
select accepted::text                        as conc1_accepted,
       coalesce(trip_id::text, '-')          as conc1_trip_id,
       coalesce(driver_id::text, '-')        as conc1_driver_id
  from dblink_get_result('w1') as r(accepted boolean, trip_id uuid, driver_id uuid) \gset

select accepted::text                        as conc2_accepted,
       coalesce(trip_id::text, '-')          as conc2_trip_id,
       coalesce(driver_id::text, '-')        as conc2_driver_id
  from dblink_get_result('w2') as r(accepted boolean, trip_id uuid, driver_id uuid) \gset

-- Which session wins is a race, so nothing here assumes an order. What has to
-- hold is that exactly one of them wins, that the loser is told which trip it
-- lost and is not credited as the driver, and that the sibling offer is
-- released rather than left pending.
insert into t_conc (seq, probe, expectation, observed) values
  (1, 'exactly one of the two concurrent accepts wins', '1',
   (select count(*)::text
      from (values (:'conc1_accepted'), (:'conc2_accepted')) as v(accepted)
     where accepted = 'true')),
  (2, 'the loser is told which trip it lost', 'c0c0c0c0-0000-4000-8000-000000000004',
   case when :'conc1_accepted' = 'true' then :'conc2_trip_id' else :'conc1_trip_id' end),
  (3, 'the loser is not credited as the driver', '-',
   case when :'conc1_accepted' = 'true' then :'conc2_driver_id' else :'conc1_driver_id' end),
  (4, 'exactly one offer row is accepted', '1',
   (select count(*)::text from offers
     where trip_id = 'c0c0c0c0-0000-4000-8000-000000000004' and state = 'accepted')),
  (5, 'the trip is matched to the winning driver and nobody else',
   case when :'conc1_accepted' = 'true'
        then 'matched|c0c0c0c0-0000-4000-8000-000000000002'
        else 'matched|c0c0c0c0-0000-4000-8000-000000000003' end,
   (select state::text || '|' || coalesce(driver_id::text, '-')
      from trips where id = 'c0c0c0c0-0000-4000-8000-000000000004')),
  (6, 'the losing sibling offer is released, not left pending', 'released',
   case when :'conc1_accepted' = 'true'
        then (select state::text from offers where id = 'c0c0c0c0-0000-4000-8000-00000000000b')
        else (select state::text from offers where id = 'c0c0c0c0-0000-4000-8000-00000000000a')
        end),
  (7, 'neither backend is left waiting on a lock', '0',
   (select count(*)::text from pg_stat_activity
     where pid in (:w1_pid, :w2_pid) and wait_event_type = 'Lock'));

-- ---------------------------------------------------------------------------
-- B. The lock ordering, measured rather than argued
-- ---------------------------------------------------------------------------
\echo ''
\echo '-- B. accept_offer blocks on the trip row and holds no offers row lock --'

-- Take the trip row lock from this session and hold it. accept_offer on the far
-- side must now block, and the question is what it is holding while it waits.
begin;
select 'main session holds the trip row' as probe,
       pg_backend_pid() as main_pid,
       true as holding
  from trips where id = 'c0c0c0c0-0000-4000-8000-000000000005' for update;

-- w3 has to carry an identity too, or accept_offer refuses it on the ownership
-- check and returns without ever reaching the trip lock.
select dblink_exec('w3', $$set request.jwt.claim.sub = 'c0c0c0c0-0000-4000-8000-000000000002'$$);
select dblink_send_query('w3', $$select * from accept_offer('c0c0c0c0-0000-4000-8000-00000000000c')$$);

-- Give the remote backend time to reach the blocking lock.
select pg_sleep(1.5);

insert into t_conc (seq, probe, expectation, observed) values
  (10, 'accept_offer is blocked while the trip row is locked elsewhere', 'Lock',
   (select coalesce(wait_event_type, 'not waiting')
      from pg_stat_activity where pid = :w3_pid)),
  -- wait_event 'transactionid' is the signature of being queued behind another
  -- backend's row lock. A table-level wait would report a relation lock instead.
  (11, 'the wait is on another transactions row, not on a table', 'transactionid',
   (select coalesce(wait_event, 'none')
      from pg_stat_activity
     where pid = :w3_pid and wait_event_type = 'Lock')),
  -- A row lock is a pg_locks row with locktype = 'tuple'. This says the only
  -- row the blocked backend has engaged with is the trip. It corroborates the
  -- ordering but it does not prove it on its own: with the old order the offer
  -- row lock does not show up in pg_locks at this instant either, because the
  -- `select ... for update` had already released its tuple lock while waiting.
  -- Section C is the part that actually discriminates the two orderings.
  (12, 'the only row it has engaged with is the trip', 'trips',
   (select coalesce(string_agg(distinct relation::regclass::text, ','), '<none>')
      from pg_locks
     where pid = :w3_pid and locktype = 'tuple' and relation is not null));

commit;

-- Releasing the trip lock lets the blocked call finish. It must now succeed,
-- because nothing else took the trip.
--
-- Note the separate connection. This dblink build leaves a connection with an
-- unfinished command after dblink_get_result has returned the last row set, so
-- dblink_send_query on the same connection answers "another command is already
-- in progress". Using a fresh connection per query is clearer than draining.
select accepted::text                 as conc3_accepted,
       coalesce(trip_id::text, '-')   as conc3_trip_id,
       coalesce(driver_id::text, '-') as conc3_driver_id
  from dblink_get_result('w3') as r(accepted boolean, trip_id uuid, driver_id uuid) \gset

insert into t_conc (seq, probe, expectation, observed) values
  (13, 'the call that was blocked succeeds once the trip lock is released', 'true',
   :'conc3_accepted'),
  (14, 'and it matched the trip to that driver', 'c0c0c0c0-0000-4000-8000-000000000002',
   (select coalesce(driver_id::text, '-')
      from trips where id = 'c0c0c0c0-0000-4000-8000-000000000005')),
  (15, 'and it released its sibling offer rather than deadlocking on it', 'released',
   (select state::text from offers where id = 'c0c0c0c0-0000-4000-8000-00000000000d'));

-- ---------------------------------------------------------------------------
-- C. Robustness of the order
--
-- Hold the OFFER row lock instead of the trip row and the call still completes
-- and elects its caller. It is waiting, so the observable is what it is waiting
-- on, not that it is not waiting: with either lock order this backend ends up
-- queueing on the offer row, and pg_locks represents that as an ungranted
-- ShareLock on the holder's transactionid plus a granted tuple lock on the row
-- it wants. The intermediate state, which is where the two orders actually
-- differ, is not visible from outside, so section A is what proves the ordering
-- and this section only shows the call is not fragile about it.
-- ---------------------------------------------------------------------------
\echo ''
\echo '-- C. holding only the offer row lock does not break the call --'

select dblink_connect('w4', 'dbname=mng_test');
select a as w4_pid from (
  select (select pid from dblink('w4', 'select pg_backend_pid()') as t(pid int)) as a
) p \gset
select dblink_exec('w4', $$set request.jwt.claim.sub = 'c0c0c0c0-0000-4000-8000-000000000003'$$);

begin;
select 'main session holds the offer row' as probe,
       pg_backend_pid() as main_pid,
       true as holding
  from offers where id = 'c0c0c0c0-0000-4000-8000-00000000000e' for update;

select dblink_send_query('w4', $$select * from accept_offer('c0c0c0c0-0000-4000-8000-00000000000e')$$);
select pg_sleep(1.5);

insert into t_conc (seq, probe, expectation, observed) values
  (16, 'holding the offer row does not wedge the backend on anything but a lock', 'Lock',
   (select coalesce(wait_event_type, 'not waiting')
      from pg_stat_activity where pid = :w4_pid));
commit;

select accepted::text as conc4_accepted,
       coalesce(trip_id::text, '-') as conc4_trip_id
  from dblink_get_result('w4') as r(accepted boolean, trip_id uuid, driver_id uuid) \gset

insert into t_conc (seq, probe, expectation, observed) values
  (17, 'the call completes and elects its caller', 'true',
   :'conc4_accepted'),
  (18, 'and it matched trip 6 to that caller', 'c0c0c0c0-0000-4000-8000-000000000003',
   (select coalesce(driver_id::text, '-')
      from trips where id = 'c0c0c0c0-0000-4000-8000-000000000006'));

select dblink_disconnect('w4');
select dblink_disconnect('w1');
select dblink_disconnect('w2');
select dblink_disconnect('w3');

-- ---------------------------------------------------------------------------
-- Verdict
-- ---------------------------------------------------------------------------
update t_conc set passed = (observed = expectation);

\echo ''
select seq, probe, expectation, observed,
       case when passed then 'PASS' else 'FAIL' end as verdict
  from t_conc
 order by seq;

\echo ''
select count(*) as assertions,
       count(*) filter (where passed) as passed,
       count(*) filter (where not passed) as failed
  from t_conc;

do $$
declare v_failed int;
begin
  select count(*) into v_failed from t_conc where not passed;
  if v_failed > 0 then
    raise exception '% of % concurrency assertions failed', v_failed, (select count(*) from t_conc);
  end if;
  raise notice 'all % concurrency assertions passed', (select count(*) from t_conc);
end
$$;

-- ---------------------------------------------------------------------------
-- Cleanup. A clean run leaves the database as it found it.
-- ---------------------------------------------------------------------------
begin;
delete from offers where trip_id in ('c0c0c0c0-0000-4000-8000-000000000004',
                                     'c0c0c0c0-0000-4000-8000-000000000005',
                                     'c0c0c0c0-0000-4000-8000-000000000006');
delete from trips where id in ('c0c0c0c0-0000-4000-8000-000000000004',
                               'c0c0c0c0-0000-4000-8000-000000000005',
                               'c0c0c0c0-0000-4000-8000-000000000006');
delete from driver_locations where driver_id in ('c0c0c0c0-0000-4000-8000-000000000002',
                                                'c0c0c0c0-0000-4000-8000-000000000003');
delete from vehicles where id in ('c0c0c0c0-0000-4000-8000-0000000000a1',
                                 'c0c0c0c0-0000-4000-8000-0000000000a2');
delete from profiles where id in ('c0c0c0c0-0000-4000-8000-000000000001',
                                 'c0c0c0c0-0000-4000-8000-000000000002',
                                 'c0c0c0c0-0000-4000-8000-000000000003');
delete from auth.users where id in ('c0c0c0c0-0000-4000-8000-000000000001',
                                   'c0c0c0c0-0000-4000-8000-000000000002',
                                   'c0c0c0c0-0000-4000-8000-000000000003');
commit;

\echo ''
\echo 'Concurrency fixtures removed.'
