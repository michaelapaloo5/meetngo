-- Approves a driver who has finished onboarding in the app.
--
-- This is the answer to "how do I accept a driver's verification", written down
-- because the answer otherwise lives only in a seed file for promoting an
-- account that never onboarded. There is no admin screen in this build and no
-- Edge Function for it: `guard_profile_update` raises on any `kyc_status` a
-- client writes, `vehicles.approved` is pinned false by both vehicle policies,
-- and `match_offers_for_trip` joins on `v.approved`. So the only writer is SQL
-- running as a role that is not a client -- the Dashboard's SQL editor, or the
-- service role.
--
-- Usage: change the email at the top and run it. It is idempotent, so it is safe
-- to run twice.

do $$
declare
  v_email text := 'driver@example.com';   -- <-- the driver's sign-in email
  v_uid   uuid;
  v_vehicle uuid;
begin
  select id into v_uid
    from auth.users
   where lower(email) = lower(v_email);

  if v_uid is null then
    raise exception
      'No auth user with email %. Check the spelling, and create the account in Dashboard -> Authentication -> Users if it does not exist.',
      v_email;
  end if;

  -- 1. The profile. `kyc_status = 'pending'` is what the app wrote when the
  --    driver submitted their Ghana Card; this is the step that turns it into
  --    an answer. `role` is set too because an account that signed up as a rider
  --    and then onboarded as a driver is a real case, and `match_offers_for_trip`
  --    filters on it.
  update profiles
     set kyc_status  = 'approved',
         role        = 'driver',
         availability = 'offline'   -- they tap Go online themselves
   where id = v_uid;

  -- 2. The vehicle. This is the part that is easy to miss: approving the profile
  --    is not enough. `match_offers_for_trip` joins `vehicles v on v.owner_id =
  --    d.id and v.approved`, so a driver with an approved profile and an
  --    unapproved vehicle is invisible to the matcher however online they are,
  --    and the app will show them as ready.
  update vehicles
     set approved = true
   where owner_id = v_uid;

  -- 3. Point the profile at the vehicle, if the onboarding wrote the row but
  --    never linked it. `save_vehicle` does this, so this is normally a no-op and
  --    is here for an account that was interrupted mid-onboarding.
  select id into v_vehicle from vehicles where owner_id = v_uid;
  if v_vehicle is not null then
    update profiles set vehicle_id = v_vehicle where id = v_uid;
  end if;

  if v_vehicle is null then
    raise warning
      'Profile approved, but this driver has no vehicle row. They will not be offered any trips until one exists. Check whether the vehicle step was completed.';
  end if;

  raise notice
    'Approved %. They can now tap Go online and be matched. Have them re-open the app so the approval is picked up.', v_email;
end $$;
