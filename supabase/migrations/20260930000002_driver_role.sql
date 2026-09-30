-- Let a person who signed up as a rider become a driver, because otherwise they
-- can never drive.
--
-- ## The bug this fixes
--
-- `handle_new_user` reads `raw_user_meta_data ->> 'role'` once, at signup, and
-- `guard_profile_update` then made `role` permanently immutable. So the role was
-- decided by which app you happened to install first and could never be changed
-- afterwards.
--
-- That is not a theoretical problem. Someone who installs the rider app, signs
-- up, and later installs the driver app and signs in with the same address is a
-- rider forever. They can upload all seven documents, an employee can approve
-- every one, and they will never appear in the driver queue -- and, worse,
-- `match_offers_for_trip` filters on `d.role = 'driver'`, so they could never be
-- matched to a trip even after approval. They would be approved, visible and
-- permanently unable to work. One of the real pilot accounts was in exactly this
-- state: seven documents uploaded, all of them good, and stored as a rider.
--
-- ## Why a user may set this for themselves
--
-- Setting `role = 'driver'` grants nothing. It is a category, not a capability.
-- Reaching the point where it matters takes three things, and every one of them
-- is a service-role write that no client can make:
--
--   * `kyc_status = 'approved'` -- set by the admin function after a person
--     compares seven documents by eye. A client may only move it *to* pending.
--   * `vehicles.approved` -- the insert policy forces `approved = false` and the
--     update policy has `with check (approved = false)`, so a driver cannot
--     approve their own vehicle.
--   * A row in `driver_locations`, plus `availability = 'online'`.
--
-- So the worst a person can do by calling this a driver is to appear in the
-- approval queue. That is the entire effect. There is also no public driver
-- directory to pollute: `profiles` has no `role = 'driver'` SELECT policy, and
-- the only client-side read is `.eq('id', _uid)`.
--
-- ## What is still refused
--
-- One direction only. `driver -> rider` stays blocked, because a driver must not
-- be able to shed their obligations on a live trip, and nothing in the product
-- ever needs it. Any other value is blocked. `rating` and `trip_count` remain
-- fully server-owned, and `kyc_status` still may only move to `pending`.

-- The trigger, unchanged in every other respect.
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
    -- The single exception, and it is deliberately narrow: a person may call
    -- themselves a driver exactly once, and only from rider. Not the reverse --
    -- see above -- and not to any other value, which the `in` check also catches
    -- if the role column's own constraint is ever relaxed.
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

  return new;
end;
$$;

-- `role` joins the writable column list. Without it PostgREST rejects the whole
-- update with PGRST204 before the trigger is ever reached, so the trigger change
-- above would be dead code on its own -- the same class of break as the missing
-- `ghana_card_expiry` column noted in the init migration.
--
-- `full_name` and `phone` were not in the original list and are not added here.
-- They are writable through the signup-name path, and widening that list is a
-- separate question from this one.
revoke update on profiles from anon, authenticated;
grant update (full_name, phone, photo_url, ghana_card_last4, ghana_card_expiry,
              selfie_url, vehicle_id, availability, kyc_status, role)
  on profiles to authenticated;

-- `handle_new_user` already reads the role from signup metadata, so a driver who
-- installs the driver app first never needs the transition at all. It is left
-- alone here on purpose: re-creating it in a later migration would mean the
-- authoritative definition of that trigger lives in two files, and this change
-- does not need to touch it.
