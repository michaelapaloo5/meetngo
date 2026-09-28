-- Promotes one existing auth user to an approved, drivable pilot driver.
--
-- Run it in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- It is idempotent, so re-running after changing the email is safe.
--
-- Why this exists at all
-- ---------------------
-- Three of the four things a driver needs are refused to a client on purpose,
-- so a client cannot self-declare any of them:
--
--   * `profiles.role` is not in the UPDATE grant, and `profiles_update_guard`
--     raises on a client changing it.
--   * `profiles.kyc_status` is writable to `pending` only.
--   * `vehicles.approved` is `false` in both the insert and the update WITH
--     CHECK clauses, and `match_offers_for_trip` joins on `v.approved`.
--   * `match_offers_for_trip` is executable by `service_role` only, and it
--     also requires `availability = 'online'` plus a row in
--     `driver_locations`. A driver who has never published a position does not
--     exist as far as the matcher is concerned.
--
-- So without this script no driver is matchable and no ride can ever happen.
-- This is a pilot shortcut, not a production onboarding path: it approves
-- without the Ghana Card OCR, the selfie, or the vehicle documents that
-- `KycScreen` collects in the app.
--
-- Before you run it
-- -----------------
-- 1. Create BOTH accounts first, in Dashboard -> Authentication -> Users -> Add
--    user, with "Auto Confirm User" ticked so you do not have to click a
--    confirmation email. **Neither app has a sign-up screen** -- the rider app
--    has Google and password sign-in only, the driver app has password
--    sign-in only -- so the dashboard is the only way an account comes into
--    existence. One account for the phone running the rider app, one for the
--    phone (or emulator) running the driver app. They must be two different
--    accounts: a single account cannot be both parties to one trip.
-- 2. Change `v_email` and `r_email` below to those addresses.
-- 3. Sign in once in each app so a wrong key or URL surfaces early, then sign
--    out.

do $$
declare
  -- >>> change this to the address you created in Authentication -> Users <<<
  v_email   text := 'pilot.driver@example.com';
  v_name    text := 'Ama Boateng';
  v_phone   text := '+233201234567';
  v_plate   text := 'GH-1234-A';
  -- >>> change this to the rider's address <<<
  r_email   text := 'rider@example.com';
  r_name    text := 'Kwame Mensah';
  v_uid     uuid;
  v_profile profiles%rowtype;
  v_vehicle uuid;
begin
  select id into v_uid from auth.users where email = v_email;
  if v_uid is null then
    raise exception
      'No auth user with email %. Create one in Dashboard -> Authentication -> Users first, then change v_email and re-run.',
      v_email;
  end if;

  -- handle_new_user creates the profile row on signup, so this is a straight
  -- update. If it is missing the account was created without the trigger
  -- firing, and the insert below is the repair.
  select * into v_profile from profiles where id = v_uid;

  if v_profile.id is null then
    insert into profiles (id, role, full_name, phone)
    values (v_uid, 'driver', v_name, v_phone);
  else
    -- `role`, `kyc_status`, `rating` and `trip_count` are server-owned for a
    -- client. This runs as the SQL editor's postgres role, which is not a
    -- client, so the trigger's guard does not fire and the columns are
    -- genuinely writable here.
    update profiles
       set role        = 'driver',
           kyc_status  = 'approved',
           full_name   = v_name,
           phone       = v_phone,
           -- Offline, not online: the driver taps Go online in the app, which
           -- is also what proves the toggle writes through.
           availability = 'offline'
     where id = v_uid;
  end if;

  -- One vehicle per driver: `vehicles.owner_id` is UNIQUE, so this has to be an
  -- upsert on the owner rather than a plain insert, or a second run collides.
  insert into vehicles (owner_id, vehicle_category, ride_category, make, model, plate, seats, approved)
  values (v_uid, 'sedan', 'standard', 'Toyota', 'Corolla', v_plate, 4, true)
  on conflict (owner_id) do update
    set vehicle_category = excluded.vehicle_category,
        ride_category    = excluded.ride_category,
        make             = excluded.make,
        model            = excluded.model,
        plate            = excluded.plate,
        seats            = excluded.seats,
        approved         = true
  returning id into v_vehicle;

  update profiles set vehicle_id = v_vehicle where id = v_uid;

  -- Parked at Osu, which is the rider app's default pickup pin
  -- (apps/rider/lib/src/app/rider_flow.dart), so the pickup distance is ~0 and
  -- a ride booked anywhere in the demo resolves to this driver. The matcher's
  -- radius is 5 km, so a real pickup elsewhere in Accra also matches.
  insert into driver_locations (driver_id, point, heading)
  values (v_uid, st_setsrid(st_makepoint(-0.1870, 5.6037), 4326)::geography, 0)
  on conflict (driver_id) do update
    set point = excluded.point,
        heading = excluded.heading,
        updated_at = now();

  raise notice
    'Pilot driver ready: % (%) vehicle % %. Sign in with that email in the driver app, tap Go online, and book a ride from the rider app.',
    v_name, v_email, v_plate, v_vehicle;

  -- The rider. A rider needs nothing but a profile row, which the signup
  -- trigger already made; this only fills in a name for the app to show. It is
  -- here so the whole pilot is one script rather than two accounts and a manual
  -- second step.
  if not exists (select 1 from auth.users where email = r_email) then
    raise exception
      'No auth user with email %. Create the rider account in Dashboard -> Authentication -> Users, then change r_email and re-run.',
      r_email;
  end if;

  update profiles p
     set full_name = r_name
    from auth.users a
   where a.id = p.id
     and a.email = r_email
     and p.role = 'rider';

  raise notice 'Pilot rider ready: % (%).', r_name, r_email;
end $$;

-- What you should see afterwards
-- ------------------------------
--   select p.email, p.role, p.kyc_status, p.availability, p.vehicle_id,
--          v.make, v.model, v.plate, v.approved
--     from auth.users a
--     join profiles p on p.id = a.id
--     left join vehicles v on v.id = p.vehicle_id
--    where a.email = 'pilot.driver@example.com';
--
-- Expected: role `driver`, kyc_status `approved`, availability `offline`,
-- Toyota Corolla, approved `t`. Change `offline` to `online` in the app, not
-- here, so the toggle gets exercised.

-- Resetting between test rides
-- ----------------------------
-- A finished trip leaves the driver `offline` and the ledger holding a payout,
-- both of which is what you want. To clear a trip a rider abandoned mid-way:
--
--   update trips set state = 'cancelled', cancelled_at = now()
--    where state in ('requested','matched','arriving');
--   update offers set state = 'released' where state = 'pending';
--   update profiles set availability = 'offline'
--    where id = (select id from auth.users where email = 'pilot.driver@example.com');
--
-- A rider stuck on a trip they cannot see is pinned by `activeTrip()`, which
-- selects the active states; the first statement is what frees them.
