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
///
/// [signUp] is here rather than absent: `apps/rider` has it and this app did
/// not, which left no way for a driver to create an account on the device that
/// has the app. It is a plain `auth.signUp`, so it needs no Edge Function.
abstract class DriverAuthRepository {
  Future<void> signInWithPassword(String email, String password);

  /// Creates an account and stores [fullName] as `full_name` in
  /// `raw_user_meta_data`.
  ///
  /// Throws [DriverAuthFailure] when the project has email confirmation on --
  /// Supabase answers a signup with no session, which is a success the caller
  /// cannot otherwise tell from a silent no-op.
  Future<void> signUp(String email, String password, String fullName);

  Future<void> signInWithGoogle();

  /// Signs out, or throws [DriverAuthFailure].
  Future<void> signOut();

  /// The signed-in account's email, or null when signed out.
  ///
  /// Lives on the repository and not on `profiles` because the address is not in
  /// that table: `create table profiles` (`20260927000001_init.sql:29`) has no
  /// email column, and the only copy of the address is on `auth.users`, which
  /// the client can read for its own session and nothing else.
  String? get currentEmail;
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
    } on Object catch (e) {
      // Not an `AuthException`, so the network failed rather than the
      // credentials: a release build with no `INTERNET` permission dies here
      // with `ClientException with SocketException: Failed host lookup ...
      // OS Error: No address associated with hostname, errno = 7`, which is
      // the one failure a driver reads as "the app is broken" and which used to
      // reach the framework as an unhandled async error with nothing on
      // screen. The permission is fixed in
      // `android/app/src/main/AndroidManifest.xml`; this is what makes the next
      // one a sentence rather than a stack trace.
      throw DriverAuthFailure(_readableTransportFailure(e));
    }
  }

  @override
  Future<void> signUp(String email, String password, String fullName) async {
    late final AuthResponse response;
    try {
      response = await _client.auth.signUp(
        email: email,
        password: password,
        // `full_name` is the key `20260928000001_persist_signup_name.sql` reads
        // to seed `profiles.full_name`, and it is the key the rider app sends,
        // so one account carries the same name whichever app created it.
        data: {'full_name': fullName},
      );
    } on AuthException catch (e) {
      throw DriverAuthFailure(e.message);
    } on Object catch (e) {
      throw DriverAuthFailure(_readableTransportFailure(e));
    }
    if (response.session == null) {
      // The project has "Confirm email" switched on: the account exists, but
      // there is no session until the address is confirmed. Saying nothing here
      // leaves the Sign Up button looking like it did nothing, so it says what
      // happened and what to do next.
      throw const DriverAuthFailure(
        'Account created. Confirm the email we sent, then log in.',
      );
    }
  }

  @override
  Future<void> signOut() async {
    try {
      await _client.auth.signOut();
    } on AuthException catch (e) {
      throw DriverAuthFailure(e.message);
    } on Object catch (e) {
      throw DriverAuthFailure(_readableTransportFailure(e));
    }
  }

  @override
  String? get currentEmail => _client.auth.currentUser?.email;

  @override
  Future<void> signInWithGoogle() async {
    // Sign-In with a third-party account is intentionally the only alternative
    // here, and it is deliberately the only one: the rider app's login test
    // asserts that a button offering another platform's account service is not
    // on screen, and this app matches it. `signInWithOAuth` launches a browser
    // and answers whether the launch happened, not whether the sign-in did:
    // the session arrives later on `auth.onAuthStateChange` through the
    // `meetngo://auth-callback` deep link, which is what the auth gate in
    // `main.dart` is driven off.
    final launched = await _client.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: 'meetngo://auth-callback',
    );
    if (!launched) throw const DriverAuthFailure('Google sign-in could not start');
  }

  /// Turns a non-`AuthException` transport fault into a sentence.
  ///
  /// The two this app has actually produced are a hostname that does not
  /// resolve -- an APK with no `INTERNET` permission -- and a plain refusal
  /// from the network. Neither is the driver's fault and neither says anything
  /// about the email address they typed.
  String _readableTransportFailure(Object e) {
    final text = e.toString();
    if (text.contains('Failed host lookup') ||
        text.contains('No address associated with hostname') ||
        text.contains('SocketException')) {
      return 'Could not reach the server. Check your connection and try again.';
    }
    return 'Could not reach the server. Try again in a moment.';
  }
}
