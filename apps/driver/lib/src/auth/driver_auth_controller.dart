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
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}
