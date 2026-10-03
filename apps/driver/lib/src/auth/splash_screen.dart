import 'package:flutter/material.dart';
import 'package:mng_core/mng_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app/driver_shell.dart';
import 'driver_login_screen.dart';

/// The animated start of the driver app.
///
/// The sequence is shared with the rider app -- same car, same timing, same reveal
/// -- because the two products are one product and a driver who also rides should
/// not find a different app opening. [MngSplashScreen] takes the logo as an
/// argument precisely so that is possible without either app hard-coding a mark.
///
/// What differs here is the mark and the lack of a tagline: the driver logo
/// already carries "DRIVER PARTNER APP" underneath its wordmark, so adding
/// another line of type under it would say the same thing twice.
class DriverSplashScreen extends StatelessWidget {
  const DriverSplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Not `const`: `brandLogoAsset` is a function call, and a function call is
    // not a constant expression. The asset *keys* are constants; turning one into
    // an `AssetImage` is not.
    return MngSplashScreen(
      logo: brandLogoAsset(isDriver: true),
      tagline: null,
      child: const _DriverAuthGate(),
    );
  }
}

/// Shows the login screen until there is a session, then the app.
///
/// Driven off `onAuthStateChange` rather than reading `currentSession` once at
/// startup, because the Google sign-in path returns to the app through a deep
/// link: the session is established by the redirect, not by anything this screen
/// awaited.
///
/// Built behind the splash rather than swapped in after it, so the session is
/// being resolved while the car is still driving and a slow restore costs the
/// driver nothing they can see.
class _DriverAuthGate extends StatelessWidget {
  const _DriverAuthGate();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      initialData: null,
      builder: (context, snapshot) {
        final state = snapshot.data;
        if (state == null) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return state.session == null
            ? const DriverLoginScreen()
            : const DriverShell();
      },
    );
  }
}
