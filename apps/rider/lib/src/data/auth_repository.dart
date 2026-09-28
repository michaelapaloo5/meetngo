class AuthFailure implements Exception {
  const AuthFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class AuthRepository {
  Future<void> signInWithPassword(String email, String password);
  Future<void> signInWithGoogle();
  Future<void> signUp(String email, String password, String fullName);
  Future<void> sendResetOtp(String email);
  Future<void> verifyOtpAndSetPassword(String email, String code, String password);
}
