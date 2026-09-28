import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

import '../auth/auth_controller.dart';
import 'profile_controller.dart';

/// The rider's own account, and the only two fields they can change here.
///
/// `profiles` UPDATE is limited by the `profiles_update_guard` trigger to
/// `full_name`, `phone`, `photo_url`, the Ghana-card fields, `selfie_url`,
/// `vehicle_id`, `availability` and `kyc_status`, and it raises if `role`,
/// `rating` or `trip_count` changes or if `kyc_status` is set to anything but
/// `pending`. So this screen writes two columns and renders the rest, and it
/// never offers a control for KYC: the rider can submit a card, not approve
/// one, and a toggle here would be a control that always fails.
///
/// Sign out is here rather than on a settings tab because there is no settings
/// tab. It delegates to [AuthController.signOut], and the app's auth gate
/// replaces the whole shell when the session ends, so this screen does not
/// navigate anywhere itself.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  bool _editing = false;
  bool _seeded = false;
  RiderProfileController? _watched;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<RiderProfileController>().load();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = context.read<RiderProfileController>();
    if (identical(c, _watched)) return;
    _watched?.removeListener(_seedFields);
    _watched = c..addListener(_seedFields);
    _seedFields();
  }

  @override
  void dispose() {
    _watched?.removeListener(_seedFields);
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  /// Fills the fields from the loaded row, once.
  ///
  /// A listener, and not a call in `build`: `TextEditingController.text = ...`
  /// notifies, `EditableText` is listening, and marking a widget dirty while
  /// the tree is building throws. It runs exactly once as well, because a
  /// re-seed would throw away whatever the rider is halfway through typing and
  /// this controller repaints on every save.
  void _seedFields() {
    final p = _watched?.profile;
    if (p == null || _seeded) return;
    _name.text = p.fullName;
    _phone.text = p.phone;
    _seeded = true;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RiderProfileController>();
    return Scaffold(
      appBar: AppBar(
        backgroundColor: MngColors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('Profile'),
        actions: [
          if (c.status == ProfileStatus.loaded)
            TextButton(
              key: const Key('editProfileButton'),
              onPressed: () => setState(() => _editing = !_editing),
              child: Text(_editing ? 'Cancel' : 'Edit'),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _body(c),
      ),
    );
  }

  Widget _body(RiderProfileController c) {
    switch (c.status) {
      case ProfileStatus.loading:
        return const Center(child: CircularProgressIndicator());
      case ProfileStatus.failed:
        return _Message(
          icon: Icons.cloud_off_outlined,
          title: 'Your profile did not load',
          body: c.error ?? 'Could not reach the server',
          onRetry: c.load,
        );
      case ProfileStatus.missing:
        return _Message(
          icon: Icons.person_off_outlined,
          title: 'No profile yet',
          body: 'Your account exists but has no profile row yet. '
              'Contact support and it will be created.',
        );
      case ProfileStatus.loaded:
        return _loaded(c);
    }
  }

  Widget _loaded(RiderProfileController c) {
    final p = c.profile!;
    return ListView(
      padding: EdgeInsets.fromLTRB(20.w, 8.h, 20.w, 24.h),
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: MngColors.primary,
              child: Text(
                _initials(p.fullName),
                style: MngTheme.light.textTheme.titleMedium?.copyWith(
                  color: MngColors.onPrimary,
                ),
              ),
            ),
            SizedBox(width: 16.w),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.fullName.isEmpty ? 'Name not set' : p.fullName,
                    key: const Key('profileName'),
                    style: MngTheme.light.textTheme.titleLarge,
                  ),
                  SizedBox(height: 2.h),
                  Text(
                    c.profile!.kyc == KycStatus.approved
                        ? 'Identity verified'
                        : 'Identity not verified',
                    style: MngTheme.light.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
        SizedBox(height: 20.h),
        if (_editing) ...[
          _Field(
            fieldKey: const Key('nameField'),
            label: 'Full name',
            controller: _name,
          ),
          SizedBox(height: 12.h),
          _Field(
            fieldKey: const Key('phoneField'),
            label: 'Phone',
            controller: _phone,
          ),
          SizedBox(height: 16.h),
          FilledButton(
            key: const Key('saveProfileButton'),
            onPressed: c.saving ? null : () => _save(c),
            child: c.saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: MngColors.onPrimary,
                    ),
                  )
                : const Text('Save details'),
          ),
          SizedBox(height: 12.h),
        ] else ...[
          _Card(
            children: [
              _Fact(
                label: 'Email',
                value: context.read<AuthController>().email ?? 'Not available',
                mono: true,
                valueKey: const Key('emailValue'),
              ),
              _Fact(
                label: 'Phone',
                value: p.phone.isEmpty ? 'Not set' : p.phone,
                valueKey: const Key('phoneValue'),
              ),
            ],
          ),
          SizedBox(height: 12.h),
          _Card(
            children: [
              _Fact(
                label: 'Rating',
                value: p.rating.toStringAsFixed(1),
                valueKey: const Key('ratingValue'),
              ),
              _Fact(
                label: 'Trips',
                value: '${p.tripCount}',
                valueKey: const Key('tripCountValue'),
              ),
              _Fact(
                label: 'Identity check',
                value: kycLabel(p.kyc),
                valueKey: const Key('kycValue'),
              ),
            ],
          ),
          SizedBox(height: 12.h),
          _Note(
            'Ratings and trip counts are set when a ride settles and cannot be '
            'edited here.',
          ),
        ],
        if (c.error != null) ...[
          SizedBox(height: 12.h),
          Text(
            c.error!,
            key: const Key('profileError'),
            style: const TextStyle(color: MngColors.error),
          ),
        ],
        SizedBox(height: 24.h),
        OutlinedButton.icon(
          key: const Key('signOutButton'),
          onPressed: c.signingOut ? null : () => _signOut(c),
          style: OutlinedButton.styleFrom(
            foregroundColor: MngColors.error,
            minimumSize: const Size.fromHeight(48),
          ),
          icon: const Icon(Icons.logout, size: 18),
          label: const Text('Sign out'),
        ),
      ],
    );
  }

  Future<void> _save(RiderProfileController c) async {
    final saved = await c.save(fullName: _name.text, phone: _phone.text);
    if (!mounted || !saved) return;
    setState(() => _editing = false);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('Details saved')));
  }

  Future<void> _signOut(RiderProfileController c) async {
    final auth = context.read<AuthController>();
    await c.signOut(auth.signOut);
  }

  /// Two letters for the avatar.
  ///
  /// Falls back to a person icon's worth of nothing rather than "?" when the
  /// name is blank, which is a real value for every account created before
  /// sign-up persisted it.
  String _initials(String fullName) {
    final parts = fullName
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }
}

String kycLabel(KycStatus kyc) => switch (kyc) {
      KycStatus.notStarted => 'Not started',
      KycStatus.pending => 'In review',
      KycStatus.approved => 'Verified',
      KycStatus.rejected => 'Not approved',
    };

class _Field extends StatelessWidget {
  const _Field({
    required this.fieldKey,
    required this.label,
    required this.controller,
  });

  final Key fieldKey;
  final String label;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: fieldKey,
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: MngColors.muted,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MngRadius.small),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(16.w),
      decoration: BoxDecoration(
        color: MngColors.surface,
        borderRadius: BorderRadius.circular(MngRadius.large),
        border: Border.all(color: MngColors.divider),
      ),
      child: Column(children: children),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({
    required this.label,
    required this.value,
    this.valueKey,
    this.mono = false,
  });

  final String label;
  final String value;
  final Key? valueKey;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: 8.h),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(label, style: MngTheme.light.textTheme.bodySmall),
          ),
          SizedBox(width: 12.w),
          Flexible(
            child: Text(
              value,
              key: valueKey,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: MngTheme.light.textTheme.bodyMedium?.copyWith(
                fontFamily: mono ? 'monospace' : null,
                fontSize: mono ? 11.sp : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline, size: 14, color: MngColors.textSub),
        SizedBox(width: 8.w),
        Expanded(
          child: Text(text, style: MngTheme.light.textTheme.bodySmall),
        ),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String body;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.symmetric(horizontal: 32.w, vertical: 80.h),
      children: [
        Icon(icon, size: 40, color: MngColors.divider),
        SizedBox(height: 12.h),
        Text(
          title,
          textAlign: TextAlign.center,
          style: MngTheme.light.textTheme.titleMedium,
        ),
        SizedBox(height: 4.h),
        Text(
          body,
          textAlign: TextAlign.center,
          style: MngTheme.light.textTheme.bodySmall,
        ),
        if (onRetry != null) ...[
          SizedBox(height: 20.h),
          OutlinedButton(
            onPressed: onRetry,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            child: const Text('Try again'),
          ),
        ],
      ],
    );
  }
}
