-- Report an item left behind in a car.
--
-- ## What this is for
--
-- A rider leaves a phone in the back of a car, or a driver leaves a bag in a
-- rider's car, and neither has anywhere to say so. Both are real, both are
-- time-sensitive -- a phone left in a car at a kerb is a phone somebody will
-- take -- and neither has a home in the current schema. There is no reports
-- table, and `sos_events` is not it: SOS is a safety escalation with a location
-- and an open/resolved flag, and putting a lost wallet in it would make the
-- emergency queue unreadable.
--
-- ## Who reports, and about whom
--
-- The driver reports an item the *rider* left in *their* car, which is why this
-- is in the driver app. That direction is the one with a clock on it: the driver
-- finds the item when they clean out, and the rider is the person who needs to
-- be told. It is also the direction that cannot be turned into a way to annoy
-- somebody -- the driver is reporting against their own vehicle and their own
-- rating is what a staff member reads next to it.
--
-- `reporter_id` is the driver. There is no `reported_driver_id`, because the
-- driver is the one whose car it is and they are the one writing the report;
-- storing a second reference to the same person would be a second place for the
-- two to disagree.
--
-- ## One report per trip per driver
--
-- `unique (trip_id, reporter_id)`. A driver who realises they left something in
-- their own car should be able to correct the description, not accumulate five
-- rows for one lost pair of sunglasses. It also stops the report button being a
-- way to write anything at all against somebody's name, which matters because a
-- report is read by a person who will take it seriously.
--
-- The upsert in the client sends the *latest* description, so the correction
-- replaces the first account rather than being lost in a queue.
--
-- ## The status is deliberately two values
--
-- `open` and `returned`. Not `investigating`: a lost phone is either in the car
-- or it is not, and a three-value workflow on something a driver resolves by
-- saying "yes, they have it" is a workflow that exists to look organised. There
-- is no `rejected` because a report of "somebody left a phone in my car" is not
-- an accusation; there is nothing to reject.
--
-- `staff_note` is the employee's own words and is deliberately not writable by
-- the reporter -- see the policies below.

create table if not exists left_item_reports (
  id uuid primary key default uuid_generate_v4(),

  -- `on delete cascade`: a report is a statement about a trip, so a trip that is
  -- deleted takes its reports with it. The alternative leaves reports naming a
  -- trip nobody can read, which is a queue of unusable work.
  trip_id uuid not null references trips on delete cascade,

  reporter_id uuid not null references profiles on delete cascade,

  -- Free text rather than an enum of "phone, wallet, keys". An enum is a
  -- migration every time somebody reports a bag nobody predicted, and the staff
  -- member reading a queue learns more from the driver's own words than from a
  -- four-item picklist. Indexable enough at this volume to filter in SQL if it
  -- ever needs to be.
  item text not null check (char_length(btrim(item)) between 1 and 200),

  -- The driver's own account of it. Optional: "her blue bag" is a complete
  -- report and forcing a second sentence would only produce "yes".
  description text not null default '' check (char_length(description) <= 1000),

  status text not null default 'open' check (status in ('open','returned')),

  -- The employee's note. Never written by the reporter, and not readable by
  -- them either: see the SELECT policy.
  staff_note text not null default '',

  -- When the item was handed back, if it has been. Distinct from `created_at`,
  -- which is when it was reported, because a report open for six days is normal
  -- and a query for "resolved this week" needs the other one.
  returned_at timestamptz,

  created_at timestamptz not null default now()
);

create index if not exists left_item_reports_open_idx
  on left_item_reports (created_at)
  where status = 'open';

-- The one-report rule, as a constraint rather than as client behaviour. A
-- constraint is the only version of it that holds when two phones send at once.
alter table left_item_reports
  drop constraint if exists left_item_reports_one_per_trip;
alter table left_item_reports
  add constraint left_item_reports_one_per_trip unique (trip_id, reporter_id);

-- ---------------------------------------------------------------------------
-- Row level security.
--
-- Mirrors `sos_events` exactly, and the reasons are the same ones: a person may
-- raise an event on a trip they are party to and may read their own events.
--
-- Note what the SELECT policy does *not* do. The reporter cannot read
-- `staff_note`, because RLS works on rows and not columns -- there is no way to
-- hide one column from a row-level policy. So the reporter can read their own
-- report including the employee's note on it. That is deliberate and it is the
-- right way round: an employee who writes "rider collected, phone was in the
-- boot" has written something the driver needs to be able to read. The thing
-- that must not leak is *other people's* reports, and this policy does not allow
-- those.
--
-- The note is *write*-protected, which is the half that matters, and that is the
-- trigger below rather than the policy: the policy cannot see columns.

alter table left_item_reports enable row level security;

drop policy if exists "report a left item on a trip you are party to" on left_item_reports;
create policy "report a left item on a trip you are party to"
  on left_item_reports
  for insert
  to public
  with check (
    reporter_id = auth.uid()
    and exists (
      select 1 from trips t
       where t.id = left_item_reports.trip_id
         and (t.rider_id = auth.uid() or t.driver_id = auth.uid())
    )
  );

drop policy if exists "read your own left item reports" on left_item_reports;
create policy "read your own left item reports"
  on left_item_reports
  for select
  to public
  using (reporter_id = auth.uid());

-- No UPDATE and no DELETE policy at all, deliberately.
--
-- The reporter cannot delete a report to remove a mistake, which sounds harsh and
-- is the right answer for a row an employee may already have acted on. They can
-- correct it: see the upsert below. What they cannot do is make it stop
-- existing.
--
-- Correction is by re-sending the same row. `on conflict (trip_id, reporter_id)
-- do update` in the client, which is why the unique constraint above is a
-- constraint and not just an index.

-- ---------------------------------------------------------------------------
-- The employee half: `status`, `staff_note` and `returned_at` are not the
-- reporter's to write.
--
-- A trigger, for the same reason `guard_profile_update` is one: the policy on the
-- INSERT already fixes `reporter_id`, and PostgREST answers a write to a column
-- with no grant with PGRST204 before RLS is consulted -- so the grant, not the
-- policy, is the first gate. And a policy cannot express "these three columns
-- but not those four" in a way that distinguishes an employee from a driver,
-- because both arrive as `authenticated` on the wire.
--
-- So the column grants do the narrowing and this trigger does the rest: it
-- refuses a change to the employee-owned columns from anybody who is not acting
-- as the staff role.

create or replace function guard_left_item_report_update()
returns trigger
language plpgsql
as $$
begin
  -- The staff role, by which the employee tooling reads and writes these rows.
  -- Nothing in the driver or rider app ever runs as this.
  if current_user in ('service_role', 'postgres', 'supabase_auth_admin') then
    return new;
  end if;

  if new.status is distinct from old.status
     or new.staff_note is distinct from old.staff_note
     or new.returned_at is distinct from old.returned_at then
    raise exception
      'status, staff_note and returned_at are staff-owned; % cannot change them',
      current_user;
  end if;

  -- And the identity of the report itself is fixed once written. Without this a
  -- client could re-point its own report at a different trip -- a trip it is
  -- party to, so RLS would pass it -- and move a description onto a trip that
  -- had nothing to do with it.
  if new.trip_id is distinct from old.trip_id
     or new.reporter_id is distinct from old.reporter_id then
    raise exception 'a report cannot be re-pointed at another trip or reporter';
  end if;

  return new;
end;
$$;

drop trigger if exists left_item_reports_guard on left_item_reports;
create trigger left_item_reports_guard
  before update on left_item_reports
  for each row execute function guard_left_item_report_update();

-- The grant. Without it the driver's upsert is rejected by PostgREST before the
-- trigger is ever reached, which is the same class of break as the missing
-- `ghana_card_expiry` column in the init migration and the missing `role` in
-- 20260930000002_driver_role.sql.
grant insert, update (item, description), select
  on left_item_reports to authenticated;

-- `anon` gets nothing. An unsigned request cannot insert a report at all, which
-- is worth stating rather than leaving to the absence of a policy: no INSERT
-- policy alone would refuse it too, but a grant would reach the trigger first
-- and the trigger's `current_user` would read `anon`, which is not on the
-- allow-list, so it would refuse for the wrong reason and say so.
revoke insert, update, select on left_item_reports from anon;