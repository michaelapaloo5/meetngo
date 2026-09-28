import 'package:supabase_flutter/supabase_flutter.dart';

import 'driver_repository.dart' show DriverAuthFailure;

/// Signing in, and nothing else.
///
/// The rider app's `AuthRepository` carries `sendResetOtp` and
/// `verifyOtpAndSetPassword`, and this one does not, on purpose. Both of those
/// call the `otp-mail` Edge Function, and `supabase/functions/` has six
/// functions and `otp-mail` is not one of them -- it is still Task 18. A
/// repository that declared those two methods would have nothing to call, and
/// the screen behind them would have to claim an email had been sent.
///
/// So the driver app renders the "Forgot Password?" link and nothing behind it
/// beyond a dialog that says the service is not switched on in this build. The
/// alternative is a screen that lies about having sent something.
abstract class DriverAuthRepository {
  Future<void> signInWithPassword(String email, String password);
  Future<void> signInWithGoogle();
}

class SupabaseDriverAuthRepository implements DriverAuthRepository {
  SupabaseDriverAuthRepository(this._client);
  final SupabaseClient _client;

  @override
  Future<void> signInWithPassword(String email, String password) async {
    try {
      await _client.auth.signInWithPassword(email: email, password: password);
    } on AuthException catch (e) {
      throw DriverAuthFailure(e.message);
    }
  }

  @override
  Future<void> signInWithGoogle() async {
    // Apple Sign-In is intentionally absent, in code and on screen, and the
    // rider app's login test asserts the button is not there. `signInWithOAuth`
    // launches a browser and answers whether the launch happened, not whether
    // the sign-in did: the session arrives later on `auth.onAuthStateChange`
    // through the `meetngo://auth-callback` deep link, which is what the auth
    // gate in `main.dart` is driven off.
    final launched = await _client.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: 'meetngo://auth-callback',
    );
    if (!launched) throw const DriverAuthFailure('Google sign-in could not start');
  }
}
