-- Who approved a driver, and when.
--
-- The admin page at `supabase/functions/admin-drivers` writes `approved_by` and
-- `approved_at` alongside `kyc_status`. Without them an approval is an
-- anonymous change of state: nothing records who flipped it or when, so "why is
-- this driver online" has no answer after the fact, and a wrongly approved
-- driver cannot be traced to a decision.
--
-- The point is the audit trail, not the data model. `kyc_status` already
-- existed and the only writer was SQL run by hand; what is missing is the
-- question "who approved this", and that is what these two columns answer.
--
-- Nullable, deliberately, and with no backfill. The rows approved before this
-- migration were approved by a person running SQL in the Dashboard, and there
-- is no way to know retroactively who. A placeholder like `'unknown'` would
-- look like an answer and be read as one. Null means "before the audit trail
-- existed", which is true.

alter table profiles
  add column approved_by uuid references auth.users (id) on delete set null,
  add column approved_at timestamptz;

comment on column profiles.approved_by is
  'The auth user who approved or rejected this driver. Null for a decision made '
  'before this column existed -- there is no way to know who, and a placeholder '
  'would read as an answer.';

comment on column profiles.approved_at is
  'When kyc_status was last set by an admin. Null for the same reason as '
  'approved_by.';

-- An index for the one query the admin page makes on load: the list of drivers
-- waiting on a decision. Without it this is a sequential scan of every profile
-- row, which is fine at pilot size and is the wrong shape to grow into, and the
-- query is the first thing that runs when an admin opens the page.
create index profiles_kyc_pending_idx
  on profiles (kyc_status, created_at desc)
  where role = 'driver';
