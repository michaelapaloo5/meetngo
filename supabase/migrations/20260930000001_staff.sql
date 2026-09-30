-- Staff accounts for driver approvals, and a decision log.
--
-- Why this exists
-- ---------------
-- The admin page originally signed people in with a Supabase email and password
-- against `profiles.role = 'admin'`. That is workable for one person -- the
-- founder -- and unusable for the people this is actually for.
--
-- To give an employee access under the old scheme the owner had to create a
-- Supabase user in the Dashboard, set a password that satisfies Supabase's
-- rules, set `profiles.role = 'admin'` by hand in the SQL editor, and then
-- explain to a non-technical colleague how to sign in to a long edge-function
-- URL with an account they did not create and would never otherwise use. Worse,
-- the deploy notes said a driver's own account was fine, which destroys the one
-- thing an approval log has to be: who made the decision.
--
-- So staff are rows here, identified by a name and a short PIN, and every
-- decision names one. The founder keeps the Supabase path for anything the staff
-- path deliberately cannot do, which is creating staff and revoking them.
--
-- The PIN
-- -------
-- Four digits is a deliberate choice, not an oversight. This is not defending
-- against an attacker with a GPU; it is a shop-floor tool for a handful of named
-- people who each know their own PIN. What it IS defending against is the
-- realistic failure: a shared password everybody knows, an ex-employee who still
-- has it, and a decision nobody can attribute.
--
-- So the PIN is per person and revocable, every decision is attributed, wrong
-- PINs lock the account for a while, and the PIN is stored as a bcrypt hash so a
-- database dump does not hand over every staff account at once.
--
-- Supabase has pgcrypto enabled, so `crypt`/`gen_salt` are available.
--
-- Sessions
-- --------
-- A random token in `staff_sessions`, stored hashed, with an expiry. Chosen over
-- a JWT because a JWT for this would need a signing secret the function would
-- have to hold, and a row can be deleted in one statement to end somebody's
-- access immediately -- which is the thing an employer actually needs when
-- somebody leaves.
--
-- A note on formatting, because it cost three attempts
-- ---------------------------------------------------
-- Every `comment on ...` below is a single string literal on a single line.
-- PostgreSQL concatenates adjacent string constants only when at least one
-- NEWLINE separates them: separated by a space, `'a' 'b'` is a syntax error.
-- The original version wrapped these comments across several lines, which reads
-- better in a file and is a syntax error in a database. toolchain
-- /apply-migration.ps1 also learned the same lesson the hard way -- it splits
-- this file into statements and it has to track dollar-quoted bodies, line
-- comments and single-quoted strings, or it cuts a sentence in half and posts
-- the middle of it as SQL.

create extension if not exists pgcrypto;

-- One person who can approve or decline a driver.
create table if not exists public.staff (
  id uuid primary key default uuid_generate_v4(),
  name text not null,
  pin_hash text not null,
  active boolean not null default true,
  failed_attempts integer not null default 0,
  locked_until timestamptz,
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);

comment on table public.staff is 'People who may approve or decline driver verifications. Authenticated by a short PIN rather than a Supabase account, because the people using this are not technical and should not have to hold a database identity to press a button. Created by the founder in the SQL editor; there is deliberately no self-service path, because a self-service path is a signup form.';
comment on column public.staff.name is 'Shown on every decision this person makes, so "who approved this" has an answer a human can read without a database query.';
comment on column public.staff.pin_hash is 'bcrypt of the staff PIN via crypt(). The PIN itself is never stored and never logged.';

-- Live staff sessions. A row here is a signed-in employee.
create table if not exists public.staff_sessions (
  token_hash text primary key,
  staff_id uuid not null references public.staff (id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);

create index if not exists staff_sessions_expiry_idx on public.staff_sessions (expires_at);

comment on table public.staff_sessions is 'One row per signed-in staff member. The token is stored as a sha256 hash, so this table is not itself a set of usable credentials if it is ever read by something it should not be. Deleting a row ends that session immediately; deleting the staff row ends all of them by cascade.';

-- Every decision made through the page, whoever made it.
--
-- `profiles.approved_by` already records a Supabase user id and stays, because
-- it is the right column for a founder-made decision and the row is already
-- written. A staff member has no auth user, so their decision leaves that column
-- null -- the column is a foreign key to `auth.users` -- and lands here instead.
-- This table is the one that is cheap to read: it carries a name, so "which
-- employees approved drivers last week" is a question a person can answer
-- without a join and without a query tool.
create table if not exists public.kyc_decisions (
  id uuid primary key default uuid_generate_v4(),
  driver_id uuid not null references public.profiles (id) on delete cascade,
  decision text not null check (decision in ('approved', 'rejected')),
  staff_id uuid references public.staff (id) on delete set null,
  staff_name text,
  reason text,
  created_at timestamptz not null default now()
);

create index if not exists kyc_decisions_created_idx on public.kyc_decisions (created_at desc);
create index if not exists kyc_decisions_staff_idx on public.kyc_decisions (staff_id, created_at desc);

comment on table public.kyc_decisions is 'Who decided each application, when, and why if it was turned down. Append-only in practice: nothing in the app updates or deletes a row here, so this is the record that survives a mistaken approval.';
comment on column public.kyc_decisions.staff_name is 'Kept beside staff_id on purpose. A staff row is deleted when somebody leaves, and on delete set null would then erase the fact that they approved thirty drivers. The name is what makes the log readable after the person is gone.';
comment on column public.kyc_decisions.reason is 'Why a driver was turned away, from the fixed list the page offers. Null for an approval, which needs no justification. Not null in practice for a rejection: the page refuses to send one without it, because a driver told no with no reason cannot do anything about it.';

-- The PIN rules, in Postgres.
--
-- These are functions rather than queries in the edge function for two reasons,
-- and both are about the hash never leaving the database.
--
-- The comparison is bcrypt. Comparing it in JavaScript would mean reading
-- `pin_hash` out of `staff` and holding it in the function's memory, where it
-- could end up in an error message or a log line. Here it never crosses the
-- wire.
--
-- The lockout arithmetic is here for the same reason a constraint is: one writer
-- of those two columns. A function that incremented the counter and a function
-- that cleared it, in two places in two languages, is two places for the rule
-- to drift.
create or replace function public.staff_pin_matches(p_staff_id uuid, p_pin text)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  select exists (select 1 from public.staff where id = p_staff_id and pin_hash = crypt(p_pin, pin_hash));
$fn$;

comment on function public.staff_pin_matches(uuid, text) is 'Constant-time bcrypt comparison done by Postgres, so the hash never leaves it. security definer because staff has RLS on with no policies; search_path is pinned so a tampered schema cannot redirect crypt().';

-- A correct PIN: clear the counter, clear the lock, stamp the last use.
create or replace function public.staff_pin_used(p_staff_id uuid)
returns void
language sql
security definer
set search_path = public, extensions
as $fn$
  update public.staff set failed_attempts = 0, locked_until = null, last_used_at = now() where id = p_staff_id;
$fn$;

-- A wrong PIN: count it, and lock the account at the threshold.
--
-- The threshold and the window are literal here and mirrored as named constants
-- in staff.ts, which the tests check against this file. Duplicated rather than
-- shared because a migration and an edge function are two deployments and a
-- cross-dependency between them is how a schema change silently breaks a
-- deployed function.
create or replace function public.staff_pin_failed(p_staff_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  attempts integer;
begin
  update public.staff set failed_attempts = failed_attempts + 1 where id = p_staff_id returning failed_attempts into attempts;
  if attempts >= 20 then
    update public.staff set locked_until = now() + interval '15 minutes' where id = p_staff_id;
  end if;
end;
$fn$;

comment on function public.staff_pin_failed(uuid) is 'Increments the wrong-PIN counter and locks the account for 15 minutes at 20 attempts. The lock is on the account because a four-digit PIN has no address to rate-limit and ten thousand values.';

-- Locked down, not merely unused.
--
-- RLS on with no policies means only the service role -- which lives in the edge
-- function and never reaches a browser -- can read or write these. A driver
-- authenticated as themselves would otherwise be able to read every staff name
-- and PIN hash over the public API, using the anon key that ships in both apps.
alter table public.staff enable row level security;
alter table public.staff_sessions enable row level security;
alter table public.kyc_decisions enable row level security;

-- How to add somebody, once this migration is applied:
--
--   insert into public.staff (name, pin_hash)
--   values ('Ama', crypt('4821', gen_salt('bf')));
--
-- To change a PIN or revoke somebody:
--
--   update public.staff set pin_hash = crypt('9137', gen_salt('bf')) where name = 'Ama';
--   update public.staff set active = false where name = 'Ama';
--
-- active = false refuses new sign-ins and leaves existing sessions alone until
-- they expire; deleting the row ends the sessions immediately by cascade.
