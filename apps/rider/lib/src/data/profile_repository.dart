import 'package:mng_core/mng_core.dart';

/// The signed-in rider's own `profiles` row.
///
/// A rider's row is the only `profiles` row this app may read: the table has
/// exactly one SELECT policy, `own profile` (`id = auth.uid()`), and there is
/// deliberately no "driver directory is public" policy, because a
/// `role = 'driver'` policy would expose every driver's phone, selfie and
/// Ghana-card digits to the anon key that ships in the APK.
class RiderProfile {
  const RiderProfile({
    required this.id,
    required this.fullName,
    required this.phone,
    required this.rating,
    required this.tripCount,
    required this.kyc,
  });

  factory RiderProfile.fromJson(Map<String, dynamic> json) => RiderProfile(
        id: json['id'] as String,
        fullName: (json['full_name'] as String?) ?? '',
        phone: (json['phone'] as String?) ?? '',
        // The column is `numeric(2,1) not null default 5.0`, so it is present
        // and read as `num`; the `?? 5.0` is only there so a hand-written or
        // partial row cannot take the profile screen down.
        rating: ((json['rating'] as num?) ?? 5.0).toDouble(),
        tripCount: (json['trip_count'] as num?)?.toInt() ?? 0,
        kyc: KycStatus.values.byName(
          (json['kyc_status'] as String?) ?? 'notStarted',
        ),
      );

  final String id;
  final String fullName;
  final String phone;
  final double rating;
  final int tripCount;
  final KycStatus kyc;

  /// What the profile screen greets the rider with.
  ///
  /// `profiles.full_name` is `not null default ''`, so empty is a real value
  /// and not an error: it is every account created before sign-up started
  /// persisting the name. A greeting that read ", " there is worse than a
  /// generic one, so this falls back.
  String get greetingName {
    final trimmed = fullName.trim();
    if (trimmed.isEmpty) return 'there';
    return trimmed.split(RegExp(r'\s+')).first;
  }

  RiderProfile copyWith({String? fullName, String? phone}) => RiderProfile(
        id: id,
        fullName: fullName ?? this.fullName,
        phone: phone ?? this.phone,
        rating: rating,
        tripCount: tripCount,
        kyc: kyc,
      );
}

/// A read or a write against the rider's own `profiles` row.
abstract class ProfileRepository {
  Future<RiderProfile?> me();

  /// Saves the two fields the client is allowed to write.
  ///
  /// Only `full_name` and `phone` are sent. `profiles` UPDATE policy
  /// `update own profile` is `using (id = auth.uid())` with no column
  /// restriction, so the limit is enforced by the `profiles_update_guard`
  /// trigger, which raises unless every other column is untouched and
  /// `kyc_status` is either unchanged or moving to `pending`. Sending the whole
  /// row back is how a client trips that trigger, so this sends the minimum.
  Future<RiderProfile?> save({required String fullName, required String phone});
}
