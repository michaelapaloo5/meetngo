-- Releases the offers left pending on cancelled trips.
--
-- ## The bug this cleans up after
--
-- `cancel-trip` released a trip's pending offers from inside
-- `if (row.driver_id)`. A rider cancelling before any driver had accepted is the
-- common case and the only case where offers are still pending -- so it was the
-- one case that never released them. Those offers then sat `pending` on a
-- cancelled trip permanently, because the only code that releases an offer runs
-- after the trip is already cancelled and nothing ever revisits it.
--
-- Seventeen were found in that state, all on cancelled trips, all invisible to
-- whoever cancelled them and visible to every driver who opened the app: a list
-- of ride offers for rides that no longer existed.
--
-- The function is fixed as well -- see `cancel-trip/handler.ts`, where
-- `releaseOffers` moved out of the driver branch -- but that only helps trips
-- cancelled from now on. This is the backlog.
--
-- ## Why it is safe to run twice
--
-- Idempotent. Re-running it finds nothing, because the first run has already set
-- every such offer to `released`. `released` and `declined` rows are kept: they
-- are the record that the offer existed and was answered, and `offers` is
-- append-only history for the driver's own view.

update public.offers o
   set state = 'released'
  from public.trips t
 where t.id = o.trip_id
   and o.state = 'pending'
   and t.state <> 'requested';

-- Trips that no driver ever took and that are still open, with nothing pending
-- against them.
--
-- These pin the rider. `TripState.isActive` counts `requested` as active and
-- `activeTrip()` selects it, so one of these left behind makes the app believe a
-- ride is in progress and stops a new one being requested. Three were found,
-- which is the whole reason the rider could not book.
--
-- Only where there is no live offer, so a trip somebody could still accept is
-- never deleted out from under them.
delete from public.trips t
 where t.state = 'requested'
   and not exists (
     select 1 from public.offers o
      where o.trip_id = t.id and o.state = 'pending'
   );

-- Stops the same thing accumulating. A trip that has been sitting in `requested`
-- with no live offer for a day has been abandoned, and leaving it pins the rider
-- until somebody notices.
create or replace function public.expire_stale_trip_requests()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  removed integer;
begin
  delete from public.trips t
   where t.state = 'requested'
     and t.created_at < now() - interval '1 day'
     and not exists (
       select 1 from public.offers o
        where o.trip_id = t.id and o.state = 'pending'
     );
  get diagnostics removed = row_count;

  -- Offers on trips the delete above just removed go with them by cascade, but
  -- this covers trips cancelled by any other route since the last run.
  update public.offers o
     set state = 'released'
    from public.trips t
   where t.id = o.trip_id
     and o.state = 'pending'
     and t.state <> 'requested';

  return removed;
end;
$$;

comment on function public.expire_stale_trip_requests() is
  'Releases orphaned offers and deletes requested trips nobody took after a day. Returns the trips deleted.';

select cron.schedule(
  'expire-stale-trip-requests',
  '43 4 * * *',
  $$select public.expire_stale_trip_requests()$$
)
where not exists (select 1 from cron.job where jobname = 'expire-stale-trip-requests');
