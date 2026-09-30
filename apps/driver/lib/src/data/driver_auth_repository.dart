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
  /// `raw_user_meta_data`, along with `role: 'driver'`.
  ///
  /// The project has `mailer_autoconfirm` on, so this answers with a usable
  /// session straight away and the driver goes into the app without touching an
  /// inbox. That was not always so, and it is the setting most likely to be
  /// turned off by accident, so the no-session case is handled and explained
  /// rather than assumed impossible.
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
        //
        // `role: 'driver'` is the other half of that, and it was missing, which
        // is why no driver who signed up could ever be matched to a trip.
        // `handle_new_user` reads it once, here, at signup; the value written is
        // `driver` when this key says `driver` and `rider` for anything else,
        // including no key at all. So a person who installed the *rider* app
        // first was a rider forever: they could upload all seven documents and
        // be approved by an employee and still be invisible to
        // `match_offers_for_trip`, which filters on `role = 'driver'`.
        //
        // Sending it here is not a privilege escalation and does not need one.
        // It is a category, not a capability -- `20260930000002_driver_role.sql`
        // explains why the same transition is also allowed afterwards, and that
        // `role = 'driver'` on its own gets a person no further than a place in
        // the approval queue, because `kyc_status = 'approved'` and
        // `vehicles.approved` are both service-role writes.
        data: {'full_name': fullName, 'role': 'driver'},
      );
    } on AuthException catch (e) {
      throw DriverAuthFailure(e.message);
    } on Object catch (e) {
      throw DriverAuthFailure(_readableTransportFailure(e));
    }
    if (response.session == null) {
      // The project used to have "Confirm email" switched on, and this branch
      // existed to explain to a driver that their account existed but needed a
      // click on an email first. `mailer_autoconfirm` is now true, so a signup
      // answers with a session every time, and this is no longer an expected
      // state -- it means the setting was turned back on, or the response is
      // not what it looks like.
      //
      // It is kept rather than deleted because a driver who hits it deserves a
      // sentence and not a stack trace, and because the fix is one toggle in the
      // Supabase dashboard rather than a code change. The wording no longer
      // promises an email is on its way, because with autoconfirm on it would
      // not be.
      throw const DriverAuthFailure(
        'Could not start your session. Try again in a moment.',
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
