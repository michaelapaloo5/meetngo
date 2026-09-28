import 'package:flutter/foundation.dart';

import '../data/driver_auth_repository.dart';
import '../data/driver_repository.dart' show DriverAuthFailure;

/// The driver's own driver as a `ChangeNotifier`, so the screen can read a
/// busy flag and an error without holding the repository.
///
/// Validates before it calls: a driver who taps "Log In" with an empty field is
/// told which field, and the repository is not asked, so a test can prove the
/// screen refused rather than that a fake threw.
class DriverAuthController extends ChangeNotifier {
  DriverAuthController(this._repo);
  final DriverAuthRepository _repo;

  bool busy = false;
  String? error;

  /// Clears a message left over from the other mode.
  ///
  /// Called when the screen flips between signing in and signing up: "Invalid
  /// login credentials" is not what a driver who just tapped "Sign Up" asked
  /// about, and leaving it up reads as a new failure.
  void clearError() {
    if (error == null) return;
    error = null;
    notifyListeners();
  }

  Future<bool> submitPassword(String email, String password) async {
    error = null;
    if (email.trim().isEmpty) {
      error = 'Enter your email';
      notifyListeners();
      return false;
    }
    if (password.isEmpty) {
      error = 'Enter your password';
      notifyListeners();
      return false;
    }
    busy = true;
    notifyListeners();
    try {
      await _repo.signInWithPassword(email.trim(), password);
      return true;
    } on DriverAuthFailure catch (e) {
      error = e.message;
      return false;
    } on Object catch (e) {
      // A repository that throws something the screen does not name would take
      // the message off the screen entirely: `error` stays null, the button
      // re-enables, and the driver's only evidence is that nothing happened.
      error = e.toString();
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Creates a driver account.
  ///
  /// The name is required and is sent, not typed and dropped: `handle_new_user`
  /// mints `profiles` with `full_name` defaulting to the empty string
  /// (`20260927000001_init.sql:32`), and
  /// `20260928000001_persist_signup_name.sql` is what copies it out of
  /// `raw_user_meta_data`. Without a name here, the driver signs up and reaches
  /// a profile that calls them nothing.
  Future<bool> submitSignUp(
    String email,
    String password,
    String fullName,
  ) async {
    error = null;
    if (fullName.trim().isEmpty) {
      error = 'Enter your name';
      notifyListeners();
      return false;
    }
    if (email.trim().isEmpty) {
      error = 'Enter your email';
      notifyListeners();
      return false;
    }
    if (password.length < 6) {
      error = 'Password must be at least 6 characters';
      notifyListeners();
      return false;
    }
    busy = true;
    notifyListeners();
    try {
      await _repo.signUp(email.trim(), password, fullName.trim());
      return true;
    } on DriverAuthFailure catch (e) {
      error = e.message;
      return false;
    } on Object catch (e) {
      error = e.toString();
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Signs out, or leaves [error] with what the server said.
  Future<bool> submitSignOut() async {
    error = null;
    busy = true;
    notifyListeners();
    try {
      await _repo.signOut();
      return true;
    } on DriverAuthFailure catch (e) {
      error = e.message;
      return false;
    } on Object catch (e) {
      error = e.toString();
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<bool> submitGoogle() async {
    error = null;
    busy = true;
    notifyListeners();
    try {
      await _repo.signInWithGoogle();
      return true;
    } on DriverAuthFailure catch (e) {
      error = e.message;
      return false;
    } on Object catch (e) {
      error = e.toString();
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}
