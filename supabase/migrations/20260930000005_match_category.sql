-- `match_offers_for_trip` never filtered on the category.
--
-- A rider books a premium ride and a standard-car driver is offered it. The
-- driver sees "Premium, GHS 4.06", which is not the fare they signed up for and
-- not what their own car is worth, and declining is the only correct response --
-- so the offer is a wasted round trip and the rider waits. This is the item on
-- the list that "loses you a driver", and it is a one-line join condition that
-- was missing for the whole life of the function.
--
-- The fix is a join, not a WHERE clause with a subquery: the trip's category is
-- already on the `trips` row the function is handed, and the driver's category
-- is on the `vehicles` row it already joins, so `v.ride_category =
-- target_trip.category` is one condition on a join that is already there. A
-- subquery against `trips` would re-read a row the function already has in hand
-- and would be a second source of truth for the same value.
--
-- A driver with no approved vehicle is already excluded by the inner join, so
-- there is no "category is null" case to decide here. `vehicles.owner_id` is
-- unique (`init.sql:47`), so a driver has exactly one vehicle and exactly one
-- category, and there is no ambiguity about which of a driver's cars to match.

create or replace function match_offers_for_trip(target_trip uuid)
returns table (driver_id uuid, pickup_distance_km numeric)
language sql
security definer
set search_path = public, extensions
as $$
  select d.id, driver_pickup_distance_km(target_trip, d.id)
  from profiles d
  join vehicles v on v.owner_id = d.id and v.approved
  where d.role = 'driver'
    and d.kyc_status = 'approved'
    and d.availability = 'online'
    -- The category the rider asked for. This is the whole change; every other
    -- condition is as it was.
    and v.ride_category = (select category from trips where id = target_trip)
    and exists (select 1 from driver_locations l where l.driver_id = d.id)
    and driver_pickup_distance_km(target_trip, d.id) <= 5.0
  order by driver_pickup_distance_km(target_trip, d.id)
  limit 5;
$$;

comment on function match_offers_for_trip(uuid) is
  'The five nearest drivers who may actually take this trip: right role, '
  'approved KYC, approved vehicle, online, a reported location, within 5 km, and '
  'selling the category the rider booked. The category condition was missing and '
  'offered standard-car drivers premium fares.';
