-- Persist the name a rider typed at sign-up.
--
-- `handle_new_user` inserted the profile with `role` only, and `profiles.full_name`
-- has a `default ''`, so every self-registered account landed with an empty name
-- and the app had nothing to greet them with. `signUp` already sends
-- `data: {'full_name': ...}`, so the value was being sent and then dropped.
--
-- This reads only the person's own name, so it is safe in the same way `role`
-- is: taken from client-supplied metadata but constrained to a text column that
-- authorises nothing. The `role` clamp stays exactly as it was.
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  insert into public.profiles (id, role, full_name)
  values (
    new.id,
    case when new.raw_user_meta_data ->> 'role' = 'driver'
         then 'driver' else 'rider' end,
    coalesce(new.raw_user_meta_data ->> 'full_name', '')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

-- Backfill accounts that signed up before this change, so the pilot's existing
-- users are not left with blank names. `full_name` is a granted update column
-- and this runs as the migration owner, so it is not blocked by
-- `profiles_update_guard`.
update public.profiles p
set full_name = coalesce(u.raw_user_meta_data ->> 'full_name', '')
from auth.users u
where u.id = p.id
  and p.full_name = ''
  and coalesce(u.raw_user_meta_data ->> 'full_name', '') <> '';
