import 'package:flutter/foundation.dart';
import '../data/auth_repository.dart';

class ResetController extends ChangeNotifier {
  ResetController(this._repo, this.email);
  final AuthRepository _repo;
  final String email;

  String? error;
  bool done = false;

  Future<bool> submit({
    required String code,
    required String password,
    required String confirm,
  }) async {
    error = null;
    if (code.length != 6) {
      error = 'Enter the 6-digit code';
      notifyListeners();
      return false;
    }
    if (password.length < 6) {
      error = 'At least 6 characters';
      notifyListeners();
      return false;
    }
    if (password != confirm) {
      error = 'Passwords do not match';
      notifyListeners();
      return false;
    }
    try {
      await _repo.verifyOtpAndSetPassword(email, code, password);
      done = true;
      notifyListeners();
      return true;
    } on AuthFailure catch (e) {
      error = e.message;
      notifyListeners();
      return false;
    }
  }
}
