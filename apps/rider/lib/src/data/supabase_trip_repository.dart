import 'package:geolocator/geolocator.dart';
import 'package:mng_core/mng_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'function_failure.dart';
import 'trip_repository.dart';

class SupabaseTripRepository implements TripRepository {
  SupabaseTripRepository(this._client);
  final SupabaseClient _client;

  @override
  Future<Trip?> activeTrip() async {
    // No `rider_id` filter on purpose: the `rider reads own trips` RLS policy
    // is `using (rider_id = auth.uid())`, so the anon key cannot widen this to
    // another rider's trip even with the filter removed.
    //
    // `rows` is the row list itself, not a `PostgrestResponse`: awaiting a
    // postgrest builder yields `T`, and `T` is `PostgrestList` for a `select`
    // (`postgrest_builder.dart:150`, and the `return converted as T` at
    // `:549`). A failed read therefore throws `PostgrestException` instead of
    // handing back an error field, so there is nothing to check here.
    final rows = await _client
        .from('trips')
        .select()
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
  Future<GeoPoint?> currentLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return null;
    }
    final pos = await Geolocator.getCurrentPosition();
    return GeoPoint(pos.latitude, pos.longitude);
  }

  @override
  Future<void> raiseSos(String tripId, String note) async {
    final here = await currentLocation();
    // Same shape as `activeTrip`: the insert yields the written rows and a
    // refused write throws, so the failure arrives as `PostgrestException` and
    // not as an error field on a response.
    try {
      await _client.from('sos_events').insert({
        'trip_id': tripId,
        'raised_by': _client.auth.currentUser!.id,
        'note': note,
        if (here != null) 'point': 'POINT(${here.lng} ${here.lat})',
      });
    } on PostgrestException catch (e) {
      throw TripRequestFailure(e.message);
    }
  }
}
