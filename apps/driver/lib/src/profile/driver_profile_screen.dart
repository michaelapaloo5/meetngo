import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

/// The Profile tab: who this driver is on the platform.
///
/// Everything here is read from the driver's own `profiles` row, the one
/// `vehicles` row they own, and the email on their own session. There is no
/// driver directory to read from and none is wanted: `profiles` has no public
/// SELECT policy for `role = 'driver'` precisely because that row carries
/// `phone`, `ghana_card_last4` and `selfie_url`.
///
/// The screen takes its data as arguments rather than reading a provider, the
/// way `DriverHomeScreen` takes its `profile`: the shell already has the
/// `DriverFlow` and the `DriverAuthRepository`, and passing the values in means
/// a test can drive this screen without a Supabase client above it and without
/// a second copy of the profile to drift.
///
/// The KYC row is a status, not a form. A driver cannot move their own
/// `kyc_status` -- `guard_profile_update` raises on any value other than
/// `pending` -- so a button here that tried would fail at the database. The row
/// says who to ask instead.
class DriverProfileScreen extends StatelessWidget {
  const DriverProfileScreen({
    super.key,
    required this.profile,
    required this.email,
    required this.vehicle,
    required this.onSignOut,
    this.busy = false,
  });

  /// The signed-in driver's own row, or null when they have none.
  final DriverProfile? profile;

  /// The address on their own session. Null when signed out or when the
  /// account has no address attached, and the row is omitted rather than
  /// rendered empty.
  final String? email;

  /// The one vehicle this driver owns, or null when they have not added one.
  final Vehicle? vehicle;

  /// Called when the driver presses Sign out. The shell owns it, because the
  /// session change is what the auth gate is driven off.
  final Future<void> Function() onSignOut;

  final bool busy;

  @override
  Widget build(BuildContext context) {
    final text = MngTheme.light.textTheme;
    final who = profile;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: MngColors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Your profile', style: text.titleLarge),
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(20.w, 8.h, 20.w, 32.h),
          children: [
            if (who == null)
              Padding(
                padding: EdgeInsets.symmetric(vertical: 24.h),
                child: Text(
                  'This account has no driver profile yet. An administrator has '
                  'to create one before you can drive.',
                  key: const Key('profileMissing'),
                  style: text.bodySmall,
                ),
              )
            else ...[
              _Identity(profile: who),
              SizedBox(height: 12.h),
              _Card(
                children: [
                  if ((email ?? '').isNotEmpty)
                    _Row(
                      label: 'Email',
                      value: email!,
                      valueKey: const Key('profileEmail'),
                    ),
                  _Row(
                    label: 'Phone',
                    value: (who.phone.isEmpty) ? 'Not added' : who.phone,
                    valueKey: const Key('profilePhone'),
                  ),
                  _Row(
                    label: 'Rating',
                    value: who.rating.toStringAsFixed(1),
                    valueKey: const Key('profileRating'),
                  ),
                  _Row(
                    label: 'Trips completed',
                    value: '${who.tripCount}',
                    valueKey: const Key('profileTripCount'),
                  ),
                ],
              ),
              SizedBox(height: 12.h),
              _Card(
                children: [
                  _Row(
                    label: 'Verification',
                    value: _kycLabel(who.kyc),
                    valueKey: const Key('profileKyc'),
                    valueColor: _kycColor(who.kyc),
                  ),
                  if ((who.vehicleId ?? '').isNotEmpty) ...[
                    SizedBox(height: 8.h),
                    _Vehicle(vehicle: vehicle),
                  ] else
                    Padding(
                      padding: EdgeInsets.only(top: 8.h),
                      child: Text(
                        'No vehicle added yet. You need one before you can go '
                        'online.',
                        key: const Key('profileNoVehicle'),
                        style: text.bodySmall,
                      ),
                    ),
                ],
              ),
            ],
            SizedBox(height: 24.h),
            OutlinedButton.icon(
              key: const Key('signOutButton'),
              onPressed: busy ? null : onSignOut,
              icon: const Icon(Icons.logout, size: 18),
              label: const Text('Sign out'),
            ),
          ],
        ),
      ),
    );
  }

  /// What [KycStatus] means to a driver, rather than what the enum is called.
  static String _kycLabel(KycStatus kyc) => switch (kyc) {
        KycStatus.notStarted => 'Not started',
        KycStatus.pending => 'Waiting for review',
        KycStatus.approved => 'Verified',
        KycStatus.rejected => 'Not verified',
      };

  static Color _kycColor(KycStatus kyc) => switch (kyc) {
        KycStatus.approved => MngColors.success,
        KycStatus.rejected => MngColors.error,
        KycStatus.pending => MngColors.info,
        KycStatus.notStarted => MngColors.textSub,
      };
}

class _Identity extends StatelessWidget {
  const _Identity({required this.profile});

  final DriverProfile profile;

  @override
  Widget build(BuildContext context) {
    final text = MngTheme.light.textTheme;
    final name = profile.fullName.trim();
    // The initials fall back to a generic 'D' rather than nothing: a driver who
    // signed up before this app stored their name would otherwise get an empty
    // circle, which reads as a broken image.
    final initials = name.isEmpty
        ? 'D'
        : name
            .split(RegExp(r'\s+'))
            .where((part) => part.isNotEmpty)
            .take(2)
            .map((part) => part[0].toUpperCase())
            .join();
    return Row(
      children: [
        Container(
          width: 56,
          height: 56,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: MngColors.primary,
            shape: BoxShape.circle,
          ),
          child: Text(
            initials,
            key: const Key('profileInitials'),
            style: MngTheme.light.textTheme.titleLarge,
          ),
        ),
        SizedBox(width: 14.w),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name.isEmpty ? 'Driver' : name,
                key: const Key('profileName'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.titleMedium,
              ),
              SizedBox(height: 2.h),
              Text('Driver', style: text.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}

class _Vehicle extends StatelessWidget {
  const _Vehicle({required this.vehicle});

  final Vehicle? vehicle;

  @override
  Widget build(BuildContext context) {
    final text = MngTheme.light.textTheme;
    final v = vehicle;
    if (v == null) {
      // A `vehicle_id` on the profile with no readable `vehicles` row. The
      // reference is `on delete set null`, so this is not a state the database
      // can hold, and the honest thing is to say the row could not be read
      // rather than to render an empty panel.
      return Text(
        'Your vehicle could not be read just now.',
        key: const Key('profileVehicleUnreadable'),
        style: text.bodySmall,
      );
    }
    return Column(
      key: const Key('profileVehicle'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Your vehicle', style: text.bodySmall),
        SizedBox(height: 4.h),
        Text(
          v.displayName,
          key: const Key('profileVehicleName'),
          style: text.titleMedium,
        ),
        SizedBox(height: 2.h),
        Text(
          '${v.plate}  ·  ${v.seats} seats  ·  ${v.rideCategory.label}',
          key: const Key('profileVehicleDetail'),
          style: text.bodySmall,
        ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(16.w),
      decoration: BoxDecoration(
        color: MngColors.surface,
        borderRadius: BorderRadius.circular(MngRadius.large),
        border: Border.all(color: MngColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.value,
    required this.valueKey,
    this.valueColor,
  });

  final String label;
  final String value;
  final Key valueKey;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final text = MngTheme.light.textTheme;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 6.h),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: text.bodySmall),
          SizedBox(width: 12.w),
          Expanded(
            child: Text(
              value,
              key: valueKey,
              textAlign: TextAlign.end,
              style: text.bodyMedium?.copyWith(color: valueColor),
            ),
          ),
        ],
      ),
    );
  }
}
