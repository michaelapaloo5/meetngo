import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_repository.dart';
import 'function_failure.dart';

class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(this._client);
  final SupabaseClient _client;

  @override
  Future<void> signInWithPassword(String email, String password) async {
    try {
      await _client.auth.signInWithPassword(email: email, password: password);
    } on AuthException catch (e) {
      throw AuthFailure(e.message);
    }
  }

  @override
  Future<void> signUp(String email, String password, String fullName) async {
    try {
      final res = await _client.auth.signUp(
        email: email,
        password: password,
        data: {'full_name': fullName},
      );
      // A project with "Confirm email" enabled returns a user but no session.
      // Saying so plainly beats letting the button appear to do nothing.
      if (res.session == null) {
        throw const AuthFailure(
          'Account created. Confirm your email, then sign in.',
        );
      }
    } on AuthException catch (e) {
      throw AuthFailure(e.message);
    }
  }

  @override
  Future<void> signInWithGoogle() async {
    // Apple Sign-In is intentionally absent, see spec section 3.1.
    // `signInWithOAuth` launches a browser and returns whether the launch
    // happened, not whether the sign-in did; the session arrives later on
    // `auth.onAuthStateChanged` through the `meetngo://auth-callback` deep link.
    final launched = await _client.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: 'meetngo://auth-callback',
    );
    if (!launched) throw const AuthFailure('Google sign-in could not start');
  }

  @override
  Future<void> sendResetOtp(String email) async {
    try {
      await _client.functions.invoke('otp-mail', body: {'email': email});
    } on FunctionException catch (e) {
      throw AuthFailure(describeFunctionFailure(e));
    }
  }

  @override
  Future<void> verifyOtpAndSetPassword(
    String email,
    String code,
    String password,
  ) async {
    // `otp-mail` owns code verification (it has service-role access to the
    // `password_reset_codes` table, which RLS hides from the client). On a
    // correct code it sets a random temporary password server-side and returns
    // it once. The client signs in with that temporary password, immediately
    // replaces it with the real one, and never surfaces the temporary value.
    String? tempPassword;
    try {
      final res = await _client.functions.invoke(
        'otp-mail',
        body: {'action': 'verify', 'email': email, 'code': code},
      );
      final data = res.data;
      if (data is Map) {
        final value = data['tempPassword'];
        if (value is String && value.isNotEmpty) tempPassword = value;
      }
    } on FunctionException catch (e) {
      throw AuthFailure(describeFunctionFailure(e));
    }
    if (tempPassword == null) {
      throw const AuthFailure('That code is not right');
    }

    try {
      await _client.auth.signInWithPassword(
        email: email,
        password: tempPassword,
      );
      final updated = await _client.auth.updateUser(
        UserAttributes(password: password),
      );
      if (updated.user == null) {
        throw const AuthFailure('Could not update password');
      }
    } on AuthException catch (e) {
      throw AuthFailure(e.message);
    } finally {
      await _discardTemporarySession();
    }
  }

  /// Signing out is cleanup, and cleanup must not be able to change the answer.
  ///
  /// `GoTrueClient._signOut` clears the local session and notifies subscribers
  /// *before* it revokes the token, then rethrows any `AuthException` whose
  /// status is not 401/403/404 (`gotrue_client.dart:1085-1108`). A transport
  /// failure arrives as `AuthRetryableFetchException`, which extends
  /// `AuthException` with a null `statusCode` and rethrows for the same reason
  /// (`fetch.dart:187-189`, `types/auth_exception.dart:55-59`). An exception
  /// thrown out of a `finally` replaces whatever the block above was in the
  /// middle of reporting, so a bare `signOut()` here did two bad things at
  /// once: a reset that had already changed the password was reported to the
  /// rider as a failure, and an `AuthFailure` was replaced by a raw
  /// `AuthException` that `ResetController.submit` does not catch, leaving the
  /// button with nothing at all to show.
  ///
  /// What is given up: the local session is gone either way, so the only thing
  /// a swallowed failure loses is the server-side revoke, and that token then
  /// stays valid until it expires on its own.
  Future<void> _discardTemporarySession() async {
    try {
      await _client.auth.signOut();
    } on Object {
      // `on Object` with no catch binding, on purpose: this method's contract
      // is that it cannot throw, whatever the storage or network layer does. A
      // binding would be an unused variable, which `--fatal-infos` rejects.
    }
  }
}
