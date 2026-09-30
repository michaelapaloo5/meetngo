import 'dart:io';

import 'package:geolocator/geolocator.dart';
import 'package:mng_core/mng_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../onboarding/driver_document.dart';
import 'driver_repository.dart';
import 'driver_trip.dart';
import 'function_failure.dart';

/// The private bucket driver documents live in.
///
/// Named here rather than inline at the two call sites because a bucket name
/// that appears twice is a bucket name that can be changed in one place, and
/// `20260929000002_driver_documents.sql` is where it has to match.
const String kDocumentBucket = 'kyc-documents';

/// What a driver is told when an upload fails.
///
/// A top-level function rather than a line inside the `catch`, because the
/// choice of message is the whole of this decision and a choice buried in a
/// catch block is a choice nothing can test. `uploadDocument` needs a real
/// Supabase client to reach; this does not.
///
/// Two different failures arrive here and they are not the same news:
///
///   * A 404 is a missing bucket -- the migration has not been applied, or was
///     applied to a different project. Retrying will never fix it and neither
///     will checking their signal, so the message must not send a driver off to
///     inspect their Wi-Fi when the fault is entirely on the server. Found on a
///     device: the checklist said "check your connection" and the connection was
///     fine.
///   * Everything else is treated as transient. That is the safe assumption for
///     a 5xx or a dropped connection and the only one worth making, because the
///     cost of telling a driver to retry a server that was briefly down is one
///     wasted tap, and the cost of the reverse assumption -- telling them it is
///     not their problem when it is -- is a driver who gives up on a photo they
///     could have saved.
DriverAuthFailure documentUploadFailure(StorageException e) {
  final missingBucket =
      e.statusCode == '404' ||
      (e.error?.toLowerCase().contains('not found') ?? false) ||
      e.message.toLowerCase().contains('not found');
  if (missingBucket) {
    return const DriverAuthFailure(
      'Photos cannot be saved right now. This is nothing you need to fix — '
      'please try again later or contact support.',
    );
  }
  return const DriverAuthFailure(
    'That photo could not be saved. Check your connection and try again.',
  );
}

/// One model per row out of a realtime event.
///
/// A `SupabaseStreamBuilder` yields a whole row list per event
/// (`SupabaseStreamEvent` is `List<Map<String, dynamic>>`,
/// `supabase-2.16.1/lib/src/supabase_stream_builder.dart:31`) and the stream
/// operations on it all fold a future in rather than a stream, so `expand` and
/// `asyncMap` cannot flatten one stream of lists into one stream of rows. An
/// `await for` is the only thing that can.
Stream<DriverProfile> _profilesOf(
  Stream<List<Map<String, dynamic>>> events,
) async* {
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
  Future<bool> claimDriverRole() async {
    final uid = _uid;
    try {
      // Conditional on `role = 'rider'`, which does two things.
      //
      // It makes the write a no-op for an account that is already a driver, so
      // this is safe to call on every launch rather than needing a local flag
      // saying "have I claimed yet" -- and a local flag is a second copy of a
      // fact the server already holds, which is the thing that goes stale.
      //
      // And it means a zero-row update is the *expected* answer for a driver who
      // is already a driver, so it cannot be mistaken for a failure. The write
      // that matters -- `rider` to `driver` -- is the one that returns a row.
      final rows = await _client
          .from('profiles')
          .update({'role': 'driver'})
          .eq('id', uid)
          .eq('role', 'rider')
          .select('id')
          .limit(1);
      return rows.isNotEmpty;
    } on PostgrestException catch (e) {
      // A repair, not a step. `guard_profile_update` refuses the reverse
      // transition, and if it ever refused this one the driver would be stuck
      // with a screen that cannot be dismissed, so the failure is swallowed and
      // the driver carries on sending documents.
      throw DriverAuthFailure(e.message);
    }
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
    String dob = '',
    String sex = '',
    String nationality = '',
    String issued = '',
    String phone = '',
  }) async {
    final uid = _uid;
    final digits = cardNumber.replaceAll(RegExp(r'[^0-9]'), '');
    try {
      final rows = await _client
          .from('profiles')
          .update({
            'kyc_status': 'pending',
            // The first four digits, as before. `ghana_card_number` now carries
            // the whole thing and is what readers prefer, but this is still
            // written so no row is ever missing it, and so a downgrade to an
            // older build loses the full number rather than being unable to show
            // anything at all.
            'ghana_card_last4': digits.length >= 4
                ? digits.substring(0, 4)
                : null,
            'ghana_card_number': cardNumber.trim(),
            'ghana_card_dob': dob.trim(),
            'ghana_card_sex': sex.trim(),
            'ghana_card_nationality': nationality.trim(),
            'ghana_card_issued': issued.trim(),
            'ghana_card_expiry': expiry,
            'full_name': fullName,
            // Normalised on the way in, so the column never holds `024 123 4567`
            // for one driver and `+233 24 123 4567` for another. Written here
            // rather than in the controller because this is the last point
            // before the database and every other writer of `profiles.phone` has
            // to go through the same rule -- `DriverRepository` is the only
            // writer of this table from the driver app, so it is the right place
            // for it.
            //
            // An empty or unparseable value is written as the empty string
            // rather than as null. The column is `not null default ''`, and a
            // driver who reaches this call without a phone -- which is every
            // driver on a build from before the field existed -- should keep the
            // value they already have rather than have it cleared.
            'phone': phone.trim().isEmpty
                ? null
                : (normaliseGhanaPhone(phone) ?? ''),
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
  Future<void> savePhone(String phone) async {
    final uid = _uid;
    final normalised = normaliseGhanaPhone(phone);
    if (normalised == null) {
      // Thrown rather than written. The screen validates first, so reaching here
      // means something bypassed the form -- and writing an undiallable number
      // would leave a driver permanently unreachable with the app showing them a
      // Call button that never works.
      throw DriverAuthFailure(
        'That is not a Ghanaian phone number. Nothing was saved.',
      );
    }
    try {
      // `.select('id')` is what makes this measurable. Without it, an update
      // answers `data = null, error = null` whether it wrote a row or matched
      // none, and those are a success and a failure. With it, an empty list is a
      // zero-row match.
      //
      // The shape is the one every other write in this file uses: `.select()`
      // resolves to a `PostgrestList` rather than to a response envelope, so
      // there is no `.error` to read here. A thrown `PostgrestException` is how a
      // write failure arrives, and the outer `catch` turns it into a
      // `DriverAuthFailure` with a message a driver can act on.
      final rows = await _client
          .from('profiles')
          .update({'phone': normalised})
          .eq('id', uid)
          .select('id')
          .limit(1);
      if (rows.isEmpty) {
        throw DriverAuthFailure('Could not save your number. Try again.');
      }
      // The cache is NOT written here. `watchProfile` is a realtime stream on
      // `profiles` keyed by `id`, so this update arrives on its own and the gate
      // clears on the next frame. Hand-updating the cached profile as well would
      // be a second source of truth for the same row, and the two could disagree
      // if the stream lost the event.
    } on DriverAuthFailure {
      rethrow;
    } catch (e) {
      throw DriverAuthFailure('Could not save your number. Try again.');
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
  Future<void> uploadDocument({
    required DriverDocumentKind kind,
    required String filePath,
  }) async {
    final uid = _uid;
    final file = File(filePath);
    // Checked before the upload rather than after. A missing file would fail the
    // upload with a message about buckets and policies, which tells a driver
    // nothing; this tells them the photo was not there, which is the truth and
    // is actionable.
    if (!file.existsSync()) {
      throw DriverAuthFailure(
        'That ${kind.label.toLowerCase()} could not be read',
      );
    }

    // The object path carries the driver's own uid as its first folder, because
    // the storage policy that stops one driver writing into another's folder is
    // `storage.foldername(name))[1] = auth.uid()::text` and that is the only
    // place the object name exists. The timestamp means a re-upload never
    // overwrites in place: Storage has no UPDATE, so an in-place write would
    // either fail or leave the old object reachable.
    final objectPath =
        '$uid/${kind.wire}/${DateTime.now().toUtc().millisecondsSinceEpoch}.jpg';

    try {
      await _client.storage
          .from(kDocumentBucket)
          .upload(
            objectPath,
            file,
            fileOptions: const FileOptions(
              contentType: 'image/jpeg',
              upsert: false,
            ),
          );
    } on StorageException catch (e) {
      throw documentUploadFailure(e);
    } on PostgrestException catch (e) {
      throw DriverAuthFailure(e.message);
    }

    try {
      // Upsert, not insert, and `onConflict` names the constraint to resolve on.
      //
      // The `onConflict` is the whole thing. `unique (driver_id, kind)` means a
      // second photo of the same kind collides, and a driver replacing a blurry
      // licence has to be able to -- so the row is replaced rather than inserted.
      //
      // But PostgREST's default conflict target is the table's **primary key**,
      // which here is `id`. The payload has no `id`, so there is nothing for it
      // to match on, it takes the INSERT branch, and the insert violates
      // `driver_documents_driver_id_kind_key`. Found on the device: the first
      // upload of each kind worked and every second one failed, so the face
      // check passed, uploaded once, and then could never be re-uploaded -- and
      // "Tap to replace this photo" was broken for all six photographs too.
      //
      // The old storage object is left alone rather than deleted, because a
      // delete that failed after a successful upload would lose the new photo
      // over tidying up the old one.
      await _client.from('driver_documents').upsert({
        'driver_id': uid,
        'kind': kind.wire,
        'path': objectPath,
        'created_at': DateTime.now().toIso8601String(),
      }, onConflict: 'driver_id,kind');
    } on PostgrestException catch (e) {
      throw DriverAuthFailure(e.message);
    }
  }

  @override
  Future<List<DriverDocument>> myDocuments() async {
    final List<dynamic> rows;
    try {
      rows = await _client
          .from('driver_documents')
          .select('kind, path, created_at')
          .eq('driver_id', _uid);
    } on PostgrestException catch (e) {
      throw DriverAuthFailure(e.message);
    }
    // A row whose `kind` is not one of the six is dropped rather than guessed
    // at. A migration that removes a document must not make the checklist throw.
    return rows
        .cast<Map<String, dynamic>>()
        .map(DriverDocument.fromJson)
        .nonNulls
        .toList();
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
        saved = await _client
            .from('vehicles')
            .insert(payload)
            .select('id')
            .limit(1);
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
  Future<void> updateLocation(GeoPoint point, {double? bearing}) async {
    final uid = _uid;
    try {
      await _client.from('driver_locations').upsert({
        'driver_id': uid,
        'point': 'POINT(${point.lng} ${point.lat})',
        // Written as a number, not a string, and omitted entirely when the
        // device has no compass. The rider's map feeds it straight to
        // MapLibre's `icon-rotate`, which needs a number; a text column would
        // be rotated as a CSS value and would silently not rotate at all.
        'heading': bearing,
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
  Future<List<DriverTrip>> myTrips({int limit = 50}) async {
    final uid = _uid;
    // `created_at` rather than the enum: this list is ordered the way a driver
    // remembers their work, and that is by day. A driver who took two trips in
    // one afternoon must not see them in an order the database happened to
    // return.
    final List<dynamic> rows;
    try {
      rows = await _client
          .from('trips')
          .select('*')
          .eq('driver_id', uid)
          .order('created_at', ascending: false)
          .limit(limit);
    } on PostgrestException catch (e) {
      throw DriverAuthFailure(e.message);
    }
    return rows
        .map((row) => DriverTrip.fromRow(row as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<Vehicle?> myVehicle() async {
    final uid = _uid;
    final rows = await _client
        .from('vehicles')
        .select('*')
        .eq('owner_id', uid)
        .limit(1);
    if (rows.isEmpty) return null;
    return Vehicle.fromJson(rows.first);
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
    final match = RegExp(r'illegal trip transition (\w+) -> (\w+)')
        .firstMatch(message);
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
