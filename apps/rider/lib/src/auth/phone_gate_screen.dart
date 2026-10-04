import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mng_core/mng_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/profile_repository.dart';
import '../data/supabase_profile_repository.dart';

/// Shows [child] only once the signed-in rider has a usable phone number.
///
/// Reads the profile itself rather than taking it as an argument, because the
/// thing that decides is the *saved* profile: the gate is removed by a successful
/// write, and the caller has no way to know that happened without re-reading. It
/// re-reads after a save for exactly that reason -- deciding on what was typed
/// rather than what was stored is how a gate that cannot be satisfied looks like
/// one that was never asked.
class PhoneGate extends StatefulWidget {
  const PhoneGate({super.key, required this.child, this.repository});

  final Widget child;

  /// Injected by tests. Null uses the real one.
  final ProfileRepository? repository;

  @override
  State<PhoneGate> createState() => _PhoneGateState();
}

class _PhoneGateState extends State<PhoneGate> {
  /// Null until the profile has been read, and again straight after a save so it
  /// is read from the database rather than trusted from the form.
  RiderProfile? _profile;
  bool _loading = true;

  ProfileRepository get _repo =>
      widget.repository ?? SupabaseProfileRepository(Supabase.instance.client);

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final profile = await _repo.me();
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      // A profile that cannot be read is not a phone number, and asking for one
      // is a better outcome than a shell the rider cannot be reached through.
      setState(() {
        _profile = null;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    // **Gated only on a phone known to be missing.**
    //
    // The first version treated an unreadable profile as "no number", on the
    // reasoning that unknown is not the same as known-good. That is true of the
    // number and false of the consequence: the profile is read once after launch,
    // and anything that fails that read -- a slow connection, a session that has
    // not finished refreshing -- would put a rider who already gave a number in
    // front of a form asking for it again.
    //
    // So a read that fails lets the rider through. The worst case is somebody with
    // no number reaching the app during a network fault, which is where they were
    // before this screen existed. Blocking every rider during a blip is not a
    // trade worth making, and a gate that re-asks for a number already on file
    // teaches riders that the app does not remember them.
    final phone = _profile?.phone ?? '';
    if (_profile == null || isCallableGhanaPhone(phone)) return widget.child;
    return PhoneGateScreen(
      repository: _repo,
      onSaved: _reload,
      signOut: () => Supabase.instance.client.auth.signOut(),
    );
  }
}

/// Blocks a signed-in rider who has no phone number until they add one.
///
/// ## Why this exists at all, now that signup demands a number
///
/// Signup requires a phone, so this screen should only ever meet an account
/// created before that was true -- or one that signed up through Google, where
/// GoTrue returns a session before the app has written anything to `profiles`.
///
/// It is still worth having, because the failure it prevents is not cosmetic.
/// `contact` hands the rider's number to the driver on the way to collect them.
/// A rider with no number on file is a driver standing at a kerb with nobody to
/// call, and the driver's app is under no obligation to say why -- it correctly
/// refuses to invent a number. So the rider never finds out, and the trip fails at
/// the pickup rather than at the screen that could have prevented it.
///
/// ## Why it blocks rather than nags
///
/// A banner is dismissible and this is not. The rider cannot reach the app until
/// the number exists, because every alternative is a support ticket later. The
/// only ways out are the number and signing out.
///
/// ## Why the number is checked, not just accepted
///
/// Same reason as signup, and the same rule: a malformed number is worse than
/// none, because it looks like it works. `isCallableGhanaPhone` is what the contact
/// card uses before it offers to dial, so the gate cannot save a number the card
/// would then refuse to dial.
class PhoneGateScreen extends StatefulWidget {
  const PhoneGateScreen({
    super.key,
    required this.repository,
    this.onSaved,
    this.signOut,
  });

  final ProfileRepository repository;

  /// Called after a successful save, so the gate can re-read and get out of the
  /// way itself. Null in tests that only care about the validation.
  final Future<void> Function()? onSaved;

  /// Offered at the bottom, because somebody who signed in with the wrong account
  /// has to be able to leave. Without it this screen is a dead end.
  final Future<void> Function()? signOut;

  @override
  State<PhoneGateScreen> createState() => _PhoneGateScreenState();
}

class _PhoneGateScreenState extends State<PhoneGateScreen> {
  final _controller = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final phone = _controller.text.trim();
    if (phone.isEmpty) {
      setState(() => _error = 'Enter your phone number');
      return;
    }
    if (!isCallableGhanaPhone(phone)) {
      setState(() => _error = 'Enter a Ghanaian number, like 024 123 4567');
      return;
    }
    setState(() {
      _error = null;
      _busy = true;
    });

    try {
      final me = await widget.repository.me();
      if (me == null) {
        // The profile row is missing, which means the account cannot be repaired
        // from here. Saying so beats a spinner that never resolves.
        if (mounted) {
          setState(() {
            _busy = false;
            _error = 'We could not load your account. Try again in a moment.';
          });
        }
        return;
      }
      final saved = await widget.repository.save(
        fullName: me.fullName,
        phone: phone,
      );
      if (!mounted) return;
      if (saved == null || !isCallableGhanaPhone(saved.phone)) {
        setState(() {
          _busy = false;
          _error = 'That number was not saved. Check it and try again.';
        });
        return;
      }
      setState(() => _busy = false);
      // The gate is removed by a re-read, not by a navigation: [PhoneGate] owns
      // whether this screen is showing at all.
      await widget.onSaved?.call();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'We could not save your number. Try again in a moment.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MngColors.page,
      appBar: AppBar(
        backgroundColor: MngColors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: const Text('One more thing'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Your phone number',
                style: MngTheme.light.textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'The driver coming to pick you up needs to be able to call '
                'you. We only share it with the driver on your own trip.',
                style: MngTheme.light.textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              TextField(
                key: const Key('phoneGateField'),
                controller: _controller,
                enabled: !_busy,
                keyboardType: TextInputType.phone,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9+\s-]')),
                ],
                autofillHints: const [AutofillHints.telephoneNumber],
                decoration: InputDecoration(
                  labelText: 'Phone number',
                  hintText: '024 123 4567',
                  errorText: _error,
                ),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 20),
              FilledButton(
                key: const Key('phoneGateSave'),
                onPressed: _busy ? null : _save,
                child: Text(_busy ? 'Saving…' : 'Save and continue'),
              ),
              const Spacer(),
              if (widget.signOut != null)
                TextButton(
                  key: const Key('phoneGateSignOut'),
                  onPressed: _busy ? null : widget.signOut,
                  child: const Text('Sign out'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
