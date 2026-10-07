-- Triage columns on `trip_reports`, so a report can be worked rather than only read.
--
-- ## Why these are here
--
-- The rider app writes a row: `reason`, `detail`, `created_at`. That is everything
-- the *rider* needs and everything the database currently holds, which means a
-- report can be read and then nothing more can be done with it. "Dismiss" and
-- "contact the rider" were both asked for, and neither has anywhere to be
-- recorded, so an employee doing triage all afternoon would have no way to answer
-- "did I already handle this one?" -- which is the question the KYC page already
-- answers with `mydecisions`.
--
-- Additive only. Nothing is rewritten, nothing is dropped, and every rider query
-- keeps working exactly as it did: a rider's own report still reads back
-- unchanged, and the new columns are simply null.
--
-- ## Why the attribution is the staff *name* and not a foreign key
--
-- `dismissed_by` and `contacted_by` store the name as it was typed at the time,
-- not a reference to `staff`.
--
-- A foreign key is the tidier shape and it is the wrong one here. Deleting a
-- staff row -- which is how somebody who has left is removed, and the sign-out
-- code says so in as many words -- would then either delete the audit trail with
-- them or cascade it away. "Who dismissed this" is a record of a past event, and
-- a past event does not change because a person was later deactivated. A name
-- written once and never re-read is the honest form of that fact.
--
-- ## No staff RLS policy
--
-- Deliberately absent, and deliberately *not* an oversight. Every other rider
-- policy on this table stays exactly as it is. Staff read and write these columns
-- through the `admin-drivers` Edge Function on the service role, which is already
-- the only path that can see anybody else's report. Adding a policy here would put
-- a second, direct route to the same rows, and a second route is a second thing
-- to get wrong.

alter table public.trip_reports
  add column if not exists dismissed_at timestamptz,
  add column if not exists dismissed_by text,
  add column if not exists dismiss_note text not null default '',
  add column if not exists contacted_at timestamptz,
  add column if not exists contacted_by text;

comment on column public.trip_reports.dismissed_at is
  'When staff marked this report handled. Null while it is still open.';
comment on column public.trip_reports.dismissed_by is
  'Staff name as typed at the time, not a reference: see the migration header.';
comment on column public.trip_reports.dismiss_note is
  'Optional note on why it was handled. Shown to the rider.';
comment on column public.trip_reports.contacted_at is
  'When staff contacted the rider about this report.';
comment on column public.trip_reports.contacted_by is
  'Staff name as typed at the time. See the migration header.';

-- ## Triage order
--
-- The queue a support inbox actually asks for: everything still open, newest
-- first. Partial, because once a report is dismissed it should stop competing for
-- attention with one nobody has looked at, and an index that still carries closed
-- rows makes the open ones slower for no benefit.
--
-- `created_at` rather than `dismissed_at`: the question is "how long has this
-- been waiting", which is the age of the report, not the age of the decision.
create index if not exists trip_reports_open_recent_idx
  on public.trip_reports (created_at desc)
  where dismissed_at is null;
