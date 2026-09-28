import 'package:mng_core/mng_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'booked_trip.dart';
import 'function_failure.dart';
import 'location_service.dart';
import 'trip_repository.dart';

class SupabaseTripRepository implements TripRepository {
  SupabaseTripRepository(this._client, {LocationService? locations})
      : _locations = locations ?? const GeolocatorLocationService();

  final SupabaseClient _client;
  final LocationService _locations;

  @override
  Future<Trip?> activeTrip() async {
    final user = _client.auth.currentUser;
    if (user == null) return null;
    // The `rider_id` filter is load-bearing, and it is here because `trips`
    // carries **two** SELECT policies, not one: `rider reads own trips`
    // (`init.sql:518-519`) and `driver reads assigned trips` (`:520-521`).
    // RLS ORs permissive policies, so the row set for one signed-in user is
    // `rider_id = me OR driver_id = me`. Dropping this filter let a rider who
    // is also the assigned driver of a live trip match both arms, and
    // `.order('created_at', ...).limit(1)` then picks by recency rather than by
    // role, so the driver-side row could come back from a method whose name
    // promises the rider's own trip. Both arms are self-scoped, so the old
    // version was never an authorisation hole — the filter is here because the
    // name is a claim and the claim has to be exact. The driver app's
    // counterpart filters `.eq('driver_id', _uid)`, so this is the symmetric
    // shape.
    //
    // `rows` is the row list itself, not a `PostgrestResponse`: awaiting a
    // postgrest builder yields `T`, and `T` is `PostgrestList` for a `select`
    // (`postgrest_builder.dart:150`, and the `return converted as T` at
    // `:549`). A failed read therefore throws `PostgrestException` instead of
    // handing back an error field, so there is nothing to check here.
    final rows = await _client
        .from('trips')
        .select()
        .eq('rider_id', user.id)
        // `inFilter`, not `in`: `in` is a reserved word, so `.in(...)` does not
        // parse, and postgrest 2.9.1 spells the filter `inFilter`
        // (`postgrest_filter_builder.dart:239`).
        .inFilter('state', ['requested', 'matched', 'arriving', 'ongoing'])
        .order('created_at', ascending: false)
        .limit(1);
    if (rows.isEmpty) return null;
    return Trip.fromJson(rows.first);
  }

  @override
  Stream<Trip> watchTrip(String tripId) => _client
      .from('trips')
      .stream(primaryKey: ['id'])
      .eq('id', tripId)
      .map((rows) => Trip.fromJson(rows.first));

  @override
  Future<List<BookedTrip>> history({int limit = 50}) async {
    final user = _client.auth.currentUser;
    if (user == null) return const [];
    // Same two-arm RLS problem `activeTrip` documents, and the same fix. The
    // `rider_id` filter is what makes the name true: without it a rider who is
    // also the assigned driver on someone else's trip matches the driver arm
    // and that trip sorts into their history by recency.
    //
    // `limit` is bound by the caller-supplied value, so it is clamped rather
    // than passed through: an unbounded `.select()` on a rider with a long
    // history is a response the phone cannot hold, and this is a list view.
    final rows = await _client
        .from('trips')
        .select()
        .eq('rider_id', user.id)
        .order('created_at', ascending: false)
        .limit(limit.clamp(1, 200));
    return rows.map(BookedTrip.fromRow).toList();
  }

  @override
  Future<Trip> requestRide({
    required TripStop pickup,
    required TripStop dropoff,
    required RideCategory category,
    String? promoCode,
  }) async {
    // The flattened `lat`/`lng` are what `parseRideRequest` reads; the nested
    // `point` rides along for free and `request-ride` normalises the stored
    // jsonb to `{label, address, point: {lat, lng}}`, which is the only shape
    // `TripStop.fromJson` can parse.
    dynamic data;
    try {
      final res = await _client.functions.invoke('request-ride', body: {
        'category': category.name,
        'promoCode': promoCode,
        'pickup': {...pickup.toJson(), ...pickup.point.toJson()},
        'dropoff': {...dropoff.toJson(), ...dropoff.point.toJson()},
      });
      data = res.data;
    } on FunctionException catch (e) {
      throw TripRequestFailure(describeFunctionFailure(e));
    }
    if (data is! Map) {
      throw const TripRequestFailure('The ride service returned nothing');
    }
    final trip = data['trip'];
    if (trip is! Map) {
      throw const TripRequestFailure('The ride service returned no trip');
    }
    return Trip.fromJson(trip.cast<String, dynamic>());
  }

  @override
  Future<void> cancelTrip(String tripId) async {
    try {
      await _client.functions.invoke(
        'cancel-trip',
        body: {'tripId': tripId},
      );
    } on FunctionException catch (e) {
      throw TripRequestFailure(describeFunctionFailure(e));
    }
  }

  @override
  Future<DeviceLocation> locate() => _locations.current();

  @override
  Future<GeoPoint?> currentLocation() async {
    final reading = await _locations.current();
    return reading.point;
  }

  @override
  Future<void> raiseSos(String tripId, String note) async {
    // Read the user first and refuse with a message. The insert needs
    // `raised_by`, and the null-assertion that used to supply it threw
    // `Null check operator used on a null value` *before* the row was written.
    // The `on PostgrestException` below cannot catch a `TypeError`, so the SOS
    // disappeared with no error the rider could read and nothing in
    // `sos_events` to answer a question with — the exact outcome the
    // migration's own comment at `init.sql:585-592` says the insert policy
    // exists to prevent. Checking here also keeps a signed-out call off the
    // geolocator platform channel, so it fails the same way whether or not
    // location is available.
    final user = _client.auth.currentUser;
    if (user == null) {
      throw const TripRequestFailure('Not signed in');
    }
    final here = await currentLocation();
    // Same shape as `activeTrip`: the insert yields the written rows and a
    // refused write throws, so the failure arrives as `PostgrestException` and
    // not as an error field on a response.
    try {
      await _client.from('sos_events').insert({
        'trip_id': tripId,
        'raised_by': user.id,
        'note': note,
        if (here != null) 'point': 'POINT(${here.lng} ${here.lat})',
      });
    } on PostgrestException catch (e) {
      throw TripRequestFailure(e.message);
    }
  }
}
