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
      // Every exit signs out, the refusal above included. The client is signed
      // in on the server-issued temporary password at this point, so signing
      // out is not only the tidy-up after a successful reset: skipping it on
      // one path leaves the rider holding a session on a password they never
      // chose and never saw.
      await _client.auth.signOut();
    }
  }
}
