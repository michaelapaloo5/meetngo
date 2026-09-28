import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_repository.dart';
import 'profile_repository.dart';

class SupabaseProfileRepository implements ProfileRepository {
  SupabaseProfileRepository(this._client);
  final SupabaseClient _client;

  String? get _uid => _client.auth.currentUser?.id;

  @override
  Future<RiderProfile?> me() async {
    final uid = _uid;
    if (uid == null) return null;
    // `.limit(1)` and `data?.[0]`, not `.single()`: `single()` throws
    // `PostgrestException` on zero rows, so a rider whose `profiles` row was
    // never created — every account that predates the sign-up trigger — would
    // arrive here as a thrown exception rather than as "no profile yet", and
    // the profile screen would have no way to tell that apart from a network
    // failure. Awaiting a postgrest builder yields the rows themselves
    // (`postgrest_builder.dart:150`), so there is no `.data` to read.
    final rows = await _client
        .from('profiles')
        .select('id, full_name, phone, rating, trip_count, kyc_status')
        .eq('id', uid)
        .limit(1);
    if (rows.isEmpty) return null;
    return RiderProfile.fromJson(rows.first);
  }

  @override
  Future<RiderProfile?> save({
    required String fullName,
    required String phone,
  }) async {
    final uid = _uid;
    if (uid == null) {
      throw const AuthFailure('Not signed in');
    }
    final updated = await _client
        .from('profiles')
        .update({'full_name': fullName, 'phone': phone})
        .eq('id', uid)
        .select('id, full_name, phone, rating, trip_count, kyc_status')
        .limit(1);
    if (updated.isEmpty) return null;
    return RiderProfile.fromJson(updated.first);
  }
}
