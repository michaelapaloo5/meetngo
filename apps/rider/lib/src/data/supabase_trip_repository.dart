import 'package:flutter/foundation.dart' show visibleForTesting;
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
      final res = await _client.functions.invoke(
        'request-ride',
        body: {
          'category': category.name,
          'promoCode': promoCode,
          'pickup': {...pickup.toJson(), ...pickup.point.toJson()},
          'dropoff': {...dropoff.toJson(), ...dropoff.point.toJson()},
        },
      );
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
      await _client.functions.invoke('cancel-trip', body: {'tripId': tripId});
    } on FunctionException catch (e) {
      throw TripRequestFailure(describeFunctionFailure(e));
    }
  }

  @override
  Future<DriverContact> driverContact(String tripId) async {
    final Map<String, dynamic> body;
    try {
      final res = await _client.functions.invoke(
        'contact',
        body: {'tripId': tripId},
      );
      // `.data`, not the response itself. `functions_client` 2.7.1 hands back a
      // `FunctionResponse`, and reading it as if it were the payload gives a
      // map whose `data` key is the answer -- so `body['name']` is null and the
      // card renders blank with no error anywhere. This is the second time this
      // file has been bitten by that shape; the first is `requestRide` above.
      final data = res.data;
      if (data is! Map) {
        throw const TripRequestFailure(
          'We could not get your driver\'s details just now.',
        );
      }
      body = data.cast<String, dynamic>();
    } on TripRequestFailure {
      rethrow;
    } on FunctionException catch (e) {
      throw TripRequestFailure(describeFunctionFailure(e));
    }

    final vehicle = body['vehicle'];
    final car = vehicle is Map ? vehicle.cast<String, dynamic>() : null;

    return DriverContact(
      name: _text(body['name']),
      phone: _text(body['phone']),
      // Checked here rather than trusted from the payload. `callable` on the
      // server is "the number is non-empty"; whether it is *dialable* is a
      // question about Ghanaian numbering, and `isCallableGhanaPhone` is the
      // rule this project has already agreed on in both apps.
      callable:
          body['callable'] == true &&
          isCallableGhanaPhone(body['phone'] as String?),
      carMake: _text(car?['make']),
      carModel: _text(car?['model']),
      plate: _text(car?['plate']),
      photoUrl: _text(body['photoUrl']),
      rating: (body['rating'] as num?)?.toDouble(),
    );
  }

  /// A string field, or empty.
  ///
  /// Every field of `contact` is optional in practice -- a driver who has never
  /// set a phone has none, and the vehicle sub-object is absent entirely when
  /// the trip has no vehicle on it -- and a cast that throws on a missing key
  /// would turn "this driver has no plate" into a failed screen.
  static String _text(Object? value) => value is String ? value : '';

  @override
  Future<DeviceLocation> locate() => _locations.current();

  @override
  Future<GeoPoint?> currentLocation() async {
    final reading = await _locations.current();
    return reading.point;
  }

  @override
  Future<VehicleFix?> assignedDriverLocation(String? driverId) async {
    // No driver yet means there is nothing to look up, and asking anyway would
    // spend a round trip to be told the same thing by the policy.
    if (driverId == null || driverId.isEmpty) return null;
    final List<dynamic> rows;
    try {
      rows = await _client
          .from('driver_locations')
          // `heading` is selected alongside `point` because the map draws the
          // driver as a car pointed the way they are driving. The column is
          // nullable in the schema -- a driver app that never published one
          // writes null -- which is why the return type carries a null bearing
          // rather than defaulting to north: a car quietly pointing the wrong
          // way is worse than one pointing an arbitrary way.
          .select('point, heading')
          .eq('driver_id', driverId)
          // `limit(1)` and never `single()`: a driver who has gone offline
          // mid-trip has no row, and `.single()` throws on a zero-row read --
          // which would turn "the driver has no position right now" into a
          // thrown error on a screen that has a perfectly good way to render
          // that. The TripRepository README says the same about trip reads.
          .limit(1);
    } on PostgrestException {
      // A refused read is not a crash: the policy denies it before a driver is
      // assigned and after the trip ends, and that is the answer, not a fault.
      return null;
    }
    if (rows.isEmpty) return null;
    final row = rows.first as Map<String, dynamic>;
    final point = _geographyToPoint(row['point']);
    // A row with a point this build cannot parse is not a vehicle, and
    // returning null is what lets the caller keep the last good one rather
    // than blanking the car.
    if (point == null) return null;
    return VehicleFix(point, normaliseBearing(row['heading']));
  }

  /// A PostGIS `geography(Point,4326)` as PostgREST hands it back.
  ///
  /// GeoJSON, and in GeoJSON's order: `{"type":"Point","coordinates":[lng,lat]}`.
  /// `GeoPoint.fromJson` is the wrong tool here and fails on it -- it expects
  /// `{"lat":..,"lng":..}`, which is the shape `request-ride` normalises the
  /// trip's own stops into. Two different shapes for the same idea in the same
  /// app, so it is worth saying which is which: trip stops are `{lat,lng}`,
  /// anything read straight out of a geography column is `[lng,lat]`.
  ///
  /// Returns null for anything it does not recognise rather than throwing. A
  /// malformed point should leave the car off the map, not take the tracking
  /// screen down with it.
  /// Exposed for the tests only.
  ///
  /// The `[lng, lat]` ordering is the single most breakable thing in this file
  /// -- it is the reverse of every other coordinate shape in the app, so a
  /// "cleanup" that swaps it produces a driver in the Atlantic rather than an
  /// error. Asserting on it through a public method is the only way the test
  /// suite can notice.
  @visibleForTesting
  static GeoPoint? geographyToPointForTest(Object? value) =>
      _geographyToPoint(value);

  static GeoPoint? _geographyToPoint(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    if (value['type'] != 'Point') return null;
    final coords = value['coordinates'];
    if (coords is! List || coords.length < 2) return null;
    final lng = coords[0];
    final lat = coords[1];
    if (lng is! num || lat is! num) return null;
    final point = GeoPoint(lat.toDouble(), lng.toDouble());
    if (point.lat.abs() > 90 || point.lng.abs() > 180) return null;
    return point;
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
