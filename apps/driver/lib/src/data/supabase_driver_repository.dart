import 'dart:io';

import 'package:geolocator/geolocator.dart';
import 'package:mng_core/mng_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'driver_repository.dart';
import 'function_failure.dart';

/// One model per row out of a realtime event.
///
/// A `SupabaseStreamBuilder` yields a whole row list per event
/// (`SupabaseStreamEvent` is `List<Map<String, dynamic>>`,
/// `supabase-2.16.1/lib/src/supabase_stream_builder.dart:31`) and the stream
/// operations on it all fold a future in rather than a stream, so `expand` and
/// `asyncMap` cannot flatten one stream of lists into one stream of rows. An
/// `await for` is the only thing that can.
Stream<DriverProfile> _profilesOf(Stream<List<Map<String, dynamic>>> events) async* {
  await for (final rows in events) {
    for (final row in rows) {
      yield DriverProfile.fromJson(row);
    }
  }
}

Stream<Offer> _offersOf(Stream<List<Map<String, dynamic>>> events) async* {
  await for (final rows in events) {
    for (final row in rows) {
      yield Offer.fromJson(row);
    }
  }
}

class SupabaseDriverRepository implements DriverRepository {
  SupabaseDriverRepository(this._client);
  final SupabaseClient _client;

  /// The signed-in driver's id, or a failure the driver can read.
  ///
  /// Read into a local and checked rather than `_client.auth.currentUser!.id`.
  /// A null assertion throws a `TypeError`, and a `TypeError` is an `Error`, so
  /// the `on PostgrestException` catch around every caller of this would not
  /// catch it: the failure would escape to the framework as an unhandled async
  /// error with nothing on the driver's screen. `raiseSos` in the rider app is
  /// the same fix at
  /// `apps/rider/lib/src/data/supabase_trip_repository.dart:127-130`.
  String get _uid {
    final user = _client.auth.currentUser;
    if (user == null) throw const DriverAuthFailure('Not signed in');
    return user.id;
  }

  @override
  Future<DriverProfile?> me() async {
    final uid = _uid;
    // Awaiting a postgrest builder yields the rows -- `T` is `PostgrestList`
    // for a `select` (`postgrest_builder.dart:150`, and the `return converted
    // as T` at `:549`) -- and a failed read throws `PostgrestException` rather
    // than handing back an error field, so there is nothing to check here and
    // nothing that could make a failure look like a success.
    //
    // `.limit(1)` then `rows.first` rather than `.maybeSingle()`: on a GET
    // `maybeSingle` sends `Accept: application/json` and a zero-row read is a
    // 200 `[]` coerced client-side, so the null branch it depends on is one a
    // GET never takes. This shape depends on no response shape at all.
    final rows = await _client.from('profiles').select().eq('id', uid).limit(1);
    if (rows.isEmpty) return null;
    return DriverProfile.fromJson(rows.first);
  }

  @override
  Stream<DriverProfile> watchMe() {
    final user = _client.auth.currentUser;
    // An empty stream rather than a thrown getter: this is read from `build`,
    // and a synchronous throw out of a stream factory is a crash with no
    // message. Signed out, there is nothing to watch.
    if (user == null) return const Stream<DriverProfile>.empty();
    return _profilesOf(
      _client.from('profiles').stream(primaryKey: ['id']).eq('id', user.id),
    );
  }

  @override
  Future<void> submitGhanaCard({
    required String cardNumber,
    required String expiry,
    required String fullName,
  }) async {
    final uid = _uid;
    final digits = cardNumber.replaceAll(RegExp(r'[^0-9]'), '');
    try {
      final rows = await _client
          .from('profiles')
          .update({
            'kyc_status': 'pending',
            'ghana_card_last4': digits.length >= 4 ? digits.substring(0, 4) : null,
            'ghana_card_expiry': expiry,
            'full_name': fullName,
          })
          .eq('id', uid)
          .select('id')
          .limit(1);
      // A refused write throws, but an UPDATE that matches no row does not: it
      // is a 200 with an empty body. Checking the row count is what stops a
      // "submitted" that nothing accepted.
      if (rows.isEmpty) {
        throw const DriverAuthFailure('That Ghana Card was not saved');
      }
    } on PostgrestException catch (e) {
      throw DriverAuthFailure(e.message);
    }
  }

  @override
  Future<void> submitSelfie(String path) async {
    // There is no `kyc` storage bucket. `20260927000001_init.sql` creates ten
    // tables and no bucket, and `supabase/config.toml` has every
    // `[storage.buckets.*]` block commented out, so an upload here would fail
    // against a project this repo builds.
    //
    // It is left as a read-and-check rather than an upload, on purpose: writing
    // a `selfie_url` the driver never uploaded, or uploading into a bucket that
    // may not exist and reporting success either way, both report a selfie the
    // server does not hold. The capture stays on the device, the KYC screen says
    // so, and when the bucket is provisioned this becomes the three lines the
    // dropped upload was. A path that is not a readable file is refused here so
    // a driver is never told their photo was taken when it was not.
    if (path.isEmpty) {
      throw const DriverAuthFailure('No selfie was captured');
    }
    final file = File(path);
    if (!file.existsSync()) {
      throw const DriverAuthFailure('The selfie could not be read back');
    }
  }

  @override
  Future<void> saveVehicle({
    required String make,
    required String model,
    required String plate,
    required int seats,
    required RideCategory rideCategory,
  }) async {
    final uid = _uid;
    final existing = await _client
        .from('vehicles')
        .select('id, approved')
        .eq('owner_id', uid)
        .limit(1);
    final current = existing.isEmpty ? null : existing.first;

    if (current != null && current['approved'] == true) {
      // `update own vehicle unapproved` has `with check (owner_id = auth.uid()
      // and approved = false)`, so an approved vehicle matches the UPDATE's
      // using-clause and then fails its with-check: PostgREST answers 200 with
      // an empty body. Without this the driver would be told the edit was saved
      // and it was not.
      throw const DriverAuthFailure(
        'This vehicle is already approved and cannot be edited in the app',
      );
    }

    final payload = <String, dynamic>{
      'owner_id': uid,
      'vehicle_category': seats > 4 ? 'van' : 'sedan',
      'ride_category': rideCategory.name,
      'make': make,
      'model': model,
      'plate': plate,
      'seats': seats,
      'approved': false,
    };

    final PostgrestList saved;
    try {
      if (current == null) {
        saved = await _client.from('vehicles').insert(payload).select('id').limit(1);
      } else {
        saved = await _client
            .from('vehicles')
            .update(payload)
            .eq('id', current['id'])
            .select('id')
            .limit(1);
      }
    } on PostgrestException catch (e) {
      throw DriverAuthFailure(e.message);
    }
    if (saved.isEmpty) {
      throw const DriverAuthFailure('That vehicle was not saved');
    }

    try {
      final linked = await _client
          .from('profiles')
          .update({'vehicle_id': saved.first['id']})
          .eq('id', uid)
          .select('id')
          .limit(1);
      if (linked.isEmpty) {
        throw const DriverAuthFailure('The vehicle was saved but not linked');
      }
    } on PostgrestException catch (e) {
      throw DriverAuthFailure(e.message);
    }
  }

  @override
  Future<void> setAvailability(DriverAvailability value) async {
    final uid = _uid;
    try {
      final rows = await _client
          .from('profiles')
          .update({'availability': value.name})
          .eq('id', uid)
          .select('id')
          .limit(1);
      if (rows.isEmpty) {
        throw const DriverAuthFailure('That change was not saved');
      }
    } on PostgrestException catch (e) {
      throw DriverAuthFailure(e.message);
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
    final position = await Geolocator.getCurrentPosition();
    return GeoPoint(position.latitude, position.longitude);
  }

  @override
  Future<void> updateLocation(GeoPoint point) async {
    final uid = _uid;
    try {
      await _client.from('driver_locations').upsert({
        'driver_id': uid,
        'point': 'POINT(${point.lng} ${point.lat})',
        'updated_at': DateTime.now().toIso8601String(),
      });
    } on PostgrestException catch (e) {
      throw DriverAuthFailure(e.message);
    }
  }

  @override
  Future<Trip?> activeTrip() async {
    final uid = _uid;
    // The `driver_id` filter is load-bearing, and it is here because `trips`
    // carries two SELECT policies -- `rider reads own trips` and `driver reads
    // assigned trips` (`init.sql:518-521`) -- and RLS ORs permissive policies.
    // Dropping it let a driver who is also a rider of a live trip match both
    // arms, and the ordering below would then pick by recency rather than by
    // role. Both arms are self-scoped, so the filter is here because the name
    // is a claim and the claim has to be exact.
    final rows = await _client
        .from('trips')
        .select('*')
        .eq('driver_id', uid)
        // `inFilter`, not `in`: `in` is a reserved word, and postgrest 2.9.1
        // spells the filter `inFilter` (`postgrest_filter_builder.dart:239`).
        .inFilter('state', ['requested', 'matched', 'arriving', 'ongoing'])
        .order('created_at', ascending: false)
        .limit(1);
    if (rows.isEmpty) return null;
    return Trip.fromJson(rows.first);
  }

  @override
  Stream<Offer> watchOffers() {
    final user = _client.auth.currentUser;
    if (user == null) return const Stream<Offer>.empty();
    // `offers` is in the realtime publication (`init.sql:632`), and
    // `driver reads own offers` (`init.sql:530`) is what makes each row
    // evidence about this driver. The `state` filter is on the client because
    // the stream fires on every change to a matched row, and a driver does not
    // need to be told their own offer was released.
    return _offersOf(
      _client
          .from('offers')
          .stream(primaryKey: ['id'])
          .eq('driver_id', user.id)
          .eq('state', 'pending'),
    );
  }

  @override
  Future<void> acceptOffer(String offerId) async {
    // `offers` answers a lost race as a 200 with `accepted: false` and a win as
    // a 200 with `accepted: true`; it throws only for the 404/409 refusals it
    // answers itself. So both are read here: the throw for the refusal, and
    // the `accepted` flag for the race the RPC decides.
    dynamic data;
    try {
      final res = await _client.functions.invoke(
        'offers',
        body: {'action': 'accept', 'offerId': offerId},
      );
      data = res.data;
    } on FunctionException catch (e) {
      throw DriverAuthFailure(describeFunctionFailure(e));
    }
    if (data is! Map || data['accepted'] != true) {
      throw const DriverAuthFailure('That trip was taken by another driver');
    }
  }

  @override
  Future<void> declineOffer(String offerId) async {
    dynamic data;
    try {
      final res = await _client.functions.invoke(
        'offers',
        body: {'action': 'decline', 'offerId': offerId},
      );
      data = res.data;
    } on FunctionException catch (e) {
      throw DriverAuthFailure(describeFunctionFailure(e));
    }
    // The write is filtered on `id`, `driver_id` and `state = 'pending'`, and
    // all three can stop matching between the read and the write, so a decline
    // that changed nothing must not answer "declined" (`offers/resolve.ts`,
    // `confirmDecline`). The row count is the only evidence.
    if (data is! Map || data['declined'] != true) {
      throw const DriverAuthFailure('That offer is no longer pending');
    }
  }

  @override
  Future<void> advanceTripState(String tripId, TripState to) async {
    try {
      final rows = await _client
          .from('trips')
          .update({'state': to.name})
          .eq('id', tripId)
          .select('id')
          .limit(1);
      if (rows.isEmpty) {
        throw const DriverAuthFailure('This trip is no longer yours to move');
      }
    } on PostgrestException catch (e) {
      // `enforce_trip_transition` raises on an illegal move, and PostgREST
      // hands that back as a 400, so the rule the database enforces arrives
      // here as an exception rather than as a quiet success.
      throw DriverAuthFailure(_readableTransition(e.message));
    }
  }

  /// The database's refusal is `illegal trip transition matched -> completed`;
  /// a driver reading that learns nothing about what to press next.
  String _readableTransition(String message) {
    final match = RegExp(
      r'illegal trip transition (\w+) -> (\w+)',
    ).firstMatch(message);
    if (match == null) return message;
    return 'This trip moved from ${match.group(1)} to ${match.group(2)} '
        'without you. Pull the latest trip state before trying again.';
  }

  @override
  Future<void> verifyPickupOtp(String tripId, String code) async {
    final rows = await _client
        .from('trips')
        .select('pickup_otp')
        .eq('id', tripId)
        .limit(1);
    if (rows.isEmpty) {
      throw const DriverAuthFailure('That code is not right');
    }
    final expected = rows.first['pickup_otp'] as String?;
    if (expected == null || expected.isEmpty || expected != code.trim()) {
      throw const DriverAuthFailure('That code is not right');
    }
  }
}
