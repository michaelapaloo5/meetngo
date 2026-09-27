-- Supabase-shaped test harness for this repo.
--
-- There is no Docker on this host, so no local Supabase stack. Instead this
-- file reconstructs the parts of a Supabase project the migration actually
-- depends on, inside a plain PostgreSQL 17 + PostGIS 3.5 database, so the
-- migration, its plpgsql trigger and its RLS policies can be executed and
-- asserted against for real.
--
-- Usage:
--   sudo -u postgres psql -v ON_ERROR_STOP=1 -f supabase/tests/harness.sql
--   sudo -u postgres psql -d mng_test -v ON_ERROR_STOP=1 -f supabase/migrations/<file>.sql
--
-- `auth.users` stands in for the table Supabase Auth manages. The `auth.uid`
-- and `auth.role` helpers read the same request-scoped GUCs Supabase populates
-- from the JWT, so `set local role authenticated; set request.jwt.claim.sub =
-- '<uuid>';` reproduces a real request as closely as plain SQL allows.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end
$$;

grant anon, authenticated, service_role to current_user;

create schema if not exists auth;

create table if not exists auth.users (
  id uuid primary key,
  email text
);

-- `raw_user_meta_data` is where a signup puts the requested role, and
-- handle_new_user() reads it. Hosted Supabase's auth.users has it;
-- `create table if not exists` will not add a column to a table that already
-- exists, hence the explicit alter.
alter table auth.users add column if not exists raw_user_meta_data jsonb;

create or replace function auth.uid() returns uuid
language sql stable
as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

create or replace function auth.role() returns text
language sql stable
as $$
  select nullif(current_setting('request.jwt.claim.role', true), '');
$$;

-- Reset the public schema so the documented three-command sequence is
-- repeatable. Dropping it cascades the PostGIS/uuid-ossp extensions and any
-- leftover tables from a previous run; the migration recreates both
-- extensions on its first two lines.
do $$
begin
  drop schema if exists public cascade;
  create schema public;
end
$$;

-- Clear auth.users now that the public schema (and with it profiles) is gone.
-- auth.users is test stand-in data this harness owns, not migration output.
-- handle_new_user() populated profiles for the previous run's users and those
-- rows just went with the drop; leaving the users behind would make the next
-- verify run collide on auth_users_pkey.
truncate table auth.users;

-- dblink backs the two-session concurrency probe in
-- supabase/tests/verify_concurrency.sql, which needs two real backends holding
-- row locks at the same time. It has to come after the drop above, because
-- dblink installs into public and the reset would take it with it. It is here
-- rather than in the migration because hosted Supabase already has dblink
-- available and no application query needs it.
create extension if not exists dblink;

grant usage on schema public to anon, authenticated, service_role;

-- Hosted Supabase creates every table, function and sequence in the public
-- schema already granted to anon, authenticated and service_role, then lets
-- RLS decide what a request may see. Without these default privileges an RLS
-- assertion fails with "permission denied for table" instead of an empty
-- result, which would hide the thing under test. `alter default privileges`
-- only covers objects created after it runs, so it must precede the migration.
alter default privileges in schema public
  grant all on tables to postgres, anon, authenticated, service_role;
alter default privileges in schema public
  grant all on functions to postgres, anon, authenticated, service_role;
alter default privileges in schema public
  grant all on sequences to postgres, anon, authenticated, service_role;

-- The migration's RLS policies call auth.uid(), so the roles need USAGE on the
-- schema hosting it. Hosted Supabase grants this to the exposed roles too.
grant usage on schema auth to anon, authenticated, service_role;

-- The migration adds four tables to this publication. `create publication`
-- errors if it already exists, so make it idempotent.
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end
$$;
