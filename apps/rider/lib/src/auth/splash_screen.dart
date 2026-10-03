import 'package:flutter/material.dart';
import 'package:mng_core/mng_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app/rider_shell.dart';
import '../auth/login_screen.dart';

/// The animated start of the rider app.
///
/// The animation and the reveal both live in [MngSplashScreen] in the shared
/// package, because the driver app opens on the same sequence with its own logo.
/// What this file adds is the two things that are genuinely this app's: which
/// logo, and what the splash opens onto.
///
/// ## What it opens onto
///
/// [_AuthGate] decides between the sign-in screen and the dashboard from the live
/// auth stream, and it is passed as the splash's child rather than swapped in
/// afterwards. That means the session is being resolved while the car is still
/// driving, so a slow restore costs nothing the rider can see -- and it is what
/// makes step six a real reveal instead of a fade between two routes.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return MngSplashScreen(
      logo: AssetImage('assets/brand/meet_n_go_logo.png'),
      tagline: 'Make a beeline across the city',
      child: const _AuthGate(),
    );
  }
}

/// Shows the login screen until there is a session, then the app.
///
/// Driven off `onAuthStateChange` rather than reading `currentSession` once at
/// startup, because the Google sign-in path returns to the app through a deep
/// link: the session is established by the redirect, not by anything this screen
/// awaited.
class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      initialData: null,
      builder: (context, snapshot) {
        final state = snapshot.data;
        if (state == null) {
          // A spinner, and only while there is genuinely no answer. It sits
          // behind the splash for the whole animation, so the rider sees it only
          // if the session takes longer than the car does.
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return state.session == null ? const LoginScreen() : const RiderShell();
      },
    );
  }
}
