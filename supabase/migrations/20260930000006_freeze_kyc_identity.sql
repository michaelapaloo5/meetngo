-- Freeze the identity evidence once a decision has been made about it.
--
-- The gap this closes, measured rather than assumed. `who-actually-writes.mjs`
-- signs in as a real driver and writes each column of `profiles` in turn. Before
-- this migration:
--
--   ghana_card_number   ALLOWED
--   ghana_card_dob      ALLOWED
--   ghana_card_expiry   ALLOWED
--   kyc_status          refused   <- guard_profile_update() caught this one
--
-- So the approval workflow itself was sound: `guard_profile_update()` pins
-- `role`, `rating`, `trip_count` and the direction of `kyc_status`, and a driver
-- cannot mark themselves verified. What was missing is that the *data an
-- employee approved* could be rewritten afterwards.
--
-- `20260930000003_ghana_card_fields.sql` explains why these columns are writable
-- at all, and its reasoning is sound:
--
--   "these are columns the driver is the authority on, about themselves, read by
--    an employee against a photograph of the same card"
--
-- That holds exactly while the decision is pending. The employee reads the card,
-- the driver reads the same card, and they agree. Once an employee has pressed
-- Approve, the column stops being what the driver says about themselves and
-- becomes the record of what was verified -- and a record that can be rewritten
-- by the person it describes is not a record. The requirement that employees
-- press a button and never hold database access only means something if what
-- they pressed on stays put.
--
-- ## What is frozen, and what is not
--
-- Frozen once `kyc_status` has left `pending`:
--
--   ghana_card_number, ghana_card_dob, ghana_card_expiry, ghana_card_issued,
--   ghana_card_sex, ghana_card_nationality, ghana_card_last4, selfie_url
--
-- Deliberately still writable, because freezing them would break working
-- features or freeze something that is not evidence:
--
--   phone          the phone gate. An approved driver with no number must be
--                  able to add one, and that write is the whole feature.
--   full_name      a typo in your own name is a normal thing to fix, and it is
--                  not what an employee checked against a card photo.
--   photo_url      an avatar, not evidence. Drivers change it whenever they
--                  like and nothing is verified against it.
--   availability   operational; going online and offline is the app working.
--   vehicle_id     operational; swapping vehicles is a normal thing to do.
--
-- `selfie_url` is in the frozen set and `photo_url` is not, which is the whole
-- distinction: the selfie is the liveness artefact a decision was made about, and
-- the photo is decoration.
--
-- ## Why `old.kyc_status`, not `new.kyc_status`
--
-- The test is on the value *before* the write. That makes the rule "once a
-- decision exists, the evidence is settled", and it leaves resubmission working:
-- a rejected driver may set `kyc_status` back to `pending`, correct the card, and
-- go back for review. The existing guard already permits a client to move
-- `kyc_status` to `pending`, and that permission is what this depends on.
--
-- Using `new.kyc_status` instead would close the resubmission loop as a side
-- effect, which is not what this is for.
--
-- It also means an approved driver cannot unlock the columns and rewrite them.
-- They can set themselves back to `pending`, but then they are unapproved again
-- and a member of staff has to press Approve a second time -- against whatever
-- the card says at that moment, which is the review working as intended.

create or replace function guard_profile_update()
returns trigger
language plpgsql
as $$
begin
  -- service_role holds BYPASSRLS, so privileged writes to these columns are
  -- already possible; admin KYC approval goes through it.
  if current_user in ('service_role', 'postgres', 'supabase_auth_admin') then
    return new;
  end if;

  if new.role is distinct from old.role then
    -- rider -> driver only, and only once. See 20260930000002_driver_role.sql.
    if not (old.role = 'rider' and new.role = 'driver') then
      raise exception
        'role may only move rider -> driver from a client; % -> % needs service_role',
        old.role, new.role;
    end if;
  end if;
  if new.rating is distinct from old.rating then
    raise exception 'rating is not user-writable';
  end if;
  if new.trip_count is distinct from old.trip_count then
    raise exception 'trip_count is not user-writable';
  end if;
  if new.kyc_status is distinct from old.kyc_status and new.kyc_status <> 'pending' then
    raise exception 'kyc_status may only move to pending from a client; % needs service_role', new.kyc_status;
  end if;

  -- The identity evidence, frozen once a decision exists. Same `old` test as the
  -- `kyc_status` rule above, and for the same reason: it reads "was this already
  -- decided?" rather than "is this being decided now?".
  if old.kyc_status is distinct from 'pending' and (
       new.ghana_card_number   is distinct from old.ghana_card_number
    or new.ghana_card_dob      is distinct from old.ghana_card_dob
    or new.ghana_card_expiry   is distinct from old.ghana_card_expiry
    or new.ghana_card_issued   is distinct from old.ghana_card_issued
    or new.ghana_card_sex      is distinct from old.ghana_card_sex
    or new.ghana_card_nationality is distinct from old.ghana_card_nationality
    or new.ghana_card_last4    is distinct from old.ghana_card_last4
    or new.selfie_url          is distinct from old.selfie_url
  ) then
    raise exception
      'Your Ghana Card and selfie are locked because your verification was already %; ask staff to reopen your review if they are wrong',
      old.kyc_status;
  end if;

  return new;
end;
$$;

-- The grants are NOT changed, and that is deliberate.
--
-- Revoking UPDATE on these columns would be the shorter fix and it would be
-- wrong twice over. It would break onboarding outright: a pending driver writes
-- `ghana_card_number` through PostgREST, and removing the grant turns that into
-- PGRST204 on every scan. And a grant is not conditional -- PostgreSQL column
-- grants cannot express "unless another column already has this value" -- so
-- revoking would freeze the fields from the very first scan, which is the point
-- where the driver is the only authority on them.
--
-- The trigger is the only mechanism here that can see two columns at once, which
-- is exactly the condition being enforced.
--
-- Asserted rather than re-issued, for the same reason as
-- 20260930000003_ghana_card_fields.sql: two definitions of one function means one
-- can silently fall behind the other, which is how `role` came to be immutable
-- while the plan said otherwise.
do $$
begin
  if not exists (
    select 1 from pg_trigger
     where tgrelid = 'public.profiles'::regclass
       and tgname   = 'profiles_update_guard'
       and not tgisinternal
       and tgenabled = 'O'
  ) then
    raise exception
      'profiles_update_guard is missing or disabled. The KYC freeze in this migration would be dead code without it.';
  end if;
end;
$$;