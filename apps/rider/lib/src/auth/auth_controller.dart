import 'package:flutter/foundation.dart';
import 'package:mng_core/mng_core.dart';

import '../data/auth_repository.dart';

class AuthController extends ChangeNotifier {
  AuthController(this._repo);
  final AuthRepository _repo;

  bool busy = false;
  String? error;

  /// The signed-in account's address, or null when signed out.
  String? get email => _repo.email;

  /// The signed-in account's uuid, or null when signed out.
  String? get uid => _repo.uid;

  Future<bool> submitPassword(String email, String password) async {
    error = null;
    if (email.isEmpty) {
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
      await _repo.signInWithPassword(email, password);
      return true;
    } on AuthFailure catch (e) {
      error = e.message;
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Clears a message left over from the other mode.
  ///
  /// Called when the screen flips between sign-in and sign-up: a message like
  /// "Invalid login credentials" is not what the reader just asked about, and
  /// leaving it up reads as a new failure.
  void clearError() {
    if (error == null) return;
    error = null;
    notifyListeners();
  }

  Future<bool> submitSignUp(
    String email,
    String password,
    String fullName,
    String phone,
  ) async {
    error = null;
    if (fullName.trim().isEmpty) {
      error = 'Enter your name';
      notifyListeners();
      return false;
    }
    if (email.isEmpty) {
      error = 'Enter your email';
      notifyListeners();
      return false;
    }
    if (password.length < 6) {
      error = 'Password must be at least 6 characters';
      notifyListeners();
      return false;
    }
    // **A phone number is required, and it is checked rather than merely
    // demanded.**
    //
    // The `contact` function hands this number to the driver on the way to pick
    // the rider up. A number that is present but malformed is the worst outcome:
    // the driver dials something that is not a phone, or copies it out and reads
    // it to a stranger. `isCallableGhanaPhone` is the rule this project already
    // agreed on -- the same one the contact card uses before it offers to dial --
    // so signup refuses anything that card would later refuse to dial.
    final trimmedPhone = phone.trim();
    if (trimmedPhone.isEmpty) {
      error = 'Enter your phone number';
      notifyListeners();
      return false;
    }
    if (!isCallableGhanaPhone(trimmedPhone)) {
      error = 'Enter a Ghanaian number, like 024 123 4567';
      notifyListeners();
      return false;
    }
    busy = true;
    notifyListeners();
    try {
      await _repo.signUp(email.trim(), password, fullName.trim(), trimmedPhone);
      return true;
    } on AuthFailure catch (e) {
      error = e.message;
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
    } on AuthFailure catch (e) {
      error = e.message;
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Ends the session.
  ///
  /// Deliberately reports nothing on failure. `_AuthGate` swaps the shell for
  /// the login screen off `onAuthStateChange`, which GoTrue fires as soon as
  /// the local session is cleared and before the token revoke is attempted, so
  /// the rider is already back at sign-in by the time this returns. Setting
  /// [error] here would paint a red line on the *login* screen about a
  /// failure in a screen the rider has already left.
  Future<void> signOut() async {
    error = null;
    await _repo.signOut();
  }
}
