-- Hands a position to the server, and to nothing else.
--
-- ## Why this exists
--
-- The Locations page must show a place name and never a coordinate. That rules
-- out geocoding in the browser: to call a reverse geocoder the page would need
-- the latitude and longitude, which puts them in a JSON payload on a page that is
-- served from shared hosting and could be logged, screenshotted or read by
-- anyone holding the phone.
--
-- So the point stays in the database. This function is the only way out of it, it
-- returns one string, and the only caller is the Edge Function, which geocodes
-- the result and writes back a place name. A coordinate reaches exactly one
-- process and is never rendered.
--
-- ## Why not a PostgREST computed column
--
-- Because `select st_y(point::geometry)` is not something PostgREST will do. A
-- `security definer` SQL function is the supported way to ask the database a
-- question its REST surface cannot express.
--
-- ## Who may call it
--
-- Granted to `service_role` only, and revoked from `anon` and `authenticated`.
-- The rider and driver apps must not be able to ask this for each other; they
-- already have their own RLS-policied route to their own position, and this one
-- has no policy because it is only ever called on the service role.

create or replace function public.location_point(
  who text,
  profile_id uuid
)
returns text
language sql
stable
security definer
set search_path = public
as $$
  -- Fully qualified throughout, because `search_path` is pinned to public and
  -- PostGIS lives in `extensions` on Supabase.
  --
  -- Two dead ends recorded so they are not walked again. `st_y(point)` does not
  -- exist: PostGIS has no st_y for geography, only for geometry. And
  -- `st_y(point::geometry)` fails with "type geometry does not exist" under that
  -- search_path. The cast target has to be named as `extensions.geometry`.
  --
  -- On a geography point st_y is latitude and st_x is longitude.
  select case
    when who = 'rider' then (
      select extensions.st_y(point::extensions.geometry)::text
             || ',' || extensions.st_x(point::extensions.geometry)::text
        from public.rider_locations where rider_id = profile_id
    )
    when who = 'driver' then (
      select extensions.st_y(point::extensions.geometry)::text
             || ',' || extensions.st_x(point::extensions.geometry)::text
        from public.driver_locations where driver_id = profile_id
    )
    else null
  end;
$$;

comment on function public.location_point(text, uuid) is
  'Returns "lat,lon" for one position, for server-side reverse geocoding only. Never returned to a page.';

revoke all on function public.location_point(text, uuid) from public, anon, authenticated;
grant execute on function public.location_point(text, uuid) to service_role;
