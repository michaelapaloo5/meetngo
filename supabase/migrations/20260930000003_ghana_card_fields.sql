-- The rest of the Ghana Card, so the review screen is not three fields and a shrug.
--
-- ## What the app knows today
--
-- Three fields: the name, the card number and the expiry. The database kept even
-- less -- `ghana_card_last4` holds the *first four digits* of the number, not the
-- last four, because `supabase_driver_repository.dart` writes
-- `digits.substring(0, 4)`. The code says so where it does it, and the admin page
-- reports the value as stored rather than quietly correcting it.
--
-- That was a defensible choice: a national ID number is the single most
-- identifying string a person owns, and storing four digits of it plus an expiry
-- keeps the database from being a place a leaked dump identifies people from. It
-- also meant an employee reading the approval screen could not see most of what
-- was on the card the driver had photographed, and had nothing to check the
-- photograph against but a name.
--
-- The decision has been made to store the card properly, so this adds the fields
-- the front of a Ghana Card actually carries, minus height and issuing district.
--
-- ## Why these are `text` and not `date`
--
-- A `date` column rejects a typo, and a rejected value fails the *whole* UPDATE.
-- So a driver who mistypes one digit of their date of birth -- on a phone
-- keyboard, or from an OCR read that got a `3` for an `8` -- loses the entire card
-- submission, and the error names a date they cannot see. Text also preserves
-- exactly what was entered, which is the point: the employee is checking the
-- stored value against the photograph, and a silently reformatted date is one more
-- thing to trust. Age is computed where it is displayed rather than stored, since
-- a stored age is a second answer to a question that changes on its own.
--
-- `ghana_card_number` is added rather than widening `ghana_card_last4`. The old
-- column stays, still written, because it is what existing rows have and because
-- dropping a column is not a thing to do in the same migration as adding one.
-- Readers prefer `ghana_card_number` and fall back to `ghana_card_last4`, so a row
-- written by an older build still renders.

alter table public.profiles
  add column if not exists ghana_card_dob text,
  add column if not exists ghana_card_sex text,
  add column if not exists ghana_card_nationality text,
  add column if not exists ghana_card_number text,
  add column if not exists ghana_card_issued text;

comment on column public.profiles.ghana_card_dob is
  'Date of birth as the driver entered or read it, dd/mm/yyyy. Text, not date: a rejected date fails the whole card submission.';
comment on column public.profiles.ghana_card_sex is
  'Sex as printed on the Ghana Card.';
comment on column public.profiles.ghana_card_nationality is
  'Nationality as printed on the Ghana Card.';
comment on column public.profiles.ghana_card_number is
  'The full Ghana Card number, GHA-XXXXXXXXX-X. ghana_card_last4 holds the first four digits and is still written for older rows.';
comment on column public.profiles.ghana_card_issued is
  'Date of issue as printed on the Ghana Card, dd/mm/yyyy.';

-- The grant, or PostgREST rejects the whole update with PGRST204 before any of
-- these reach the table. Same class of break as the missing `ghana_card_expiry`
-- column in the init migration, and the missing `role` in the previous one.
revoke update on profiles from anon, authenticated;
grant update (full_name, phone, photo_url, ghana_card_last4, ghana_card_expiry,
              ghana_card_dob, ghana_card_sex, ghana_card_nationality,
              ghana_card_number, ghana_card_issued,
              selfie_url, vehicle_id, availability, kyc_status, role)
  on profiles to authenticated;

-- `guard_profile_update` is deliberately not touched. It pins `role`, `rating`,
-- `trip_count` and the direction of `kyc_status`, and nothing here is one of
-- those: these are columns the driver is the authority on, about themselves,
-- read by an employee against a photograph of the same card. The guard is
-- re-created rather than assumed present so that this migration fails loudly if a
-- future one drops it, instead of silently leaving the new columns unguarded.
--
-- Asserted rather than recreated, deliberately. Re-creating it here would mean
-- the authoritative definition lives in two files and the second copy could fall
-- behind the first without anyone noticing -- which is how `role` came to be
-- immutable while the plan said otherwise.
do $$
begin
  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where p.proname = 'guard_profile_update'
      and n.nspname = 'public'
  ) then
    raise exception 'guard_profile_update is missing; the new Ghana Card columns would be unguarded';
  end if;
end
$$;
