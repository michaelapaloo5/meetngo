import 'package:flutter/foundation.dart';
import '../data/auth_repository.dart';

class AuthController extends ChangeNotifier {
  AuthController(this._repo);
  final AuthRepository _repo;

  bool busy = false;
  String? error;

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
    busy = true;
    notifyListeners();
    try {
      await _repo.signUp(email.trim(), password, fullName.trim());
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
}
