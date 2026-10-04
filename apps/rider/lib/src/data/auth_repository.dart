class AuthFailure implements Exception {
  const AuthFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class AuthRepository {
  /// The signed-in account's email address, or null when signed out.
  ///
  /// Read from the session rather than from `profiles`: the address lives in
  /// GoTrue's own `auth.users` table, which is not reachable through PostgREST
  /// at all, so a `profiles` select cannot produce it and inventing one from
  /// the row's uuid would show a rider a hex string where their address
  /// should be.
  String? get email;

  /// The signed-in account's uuid, or null when signed out.
  ///
  /// This is the value every `auth.uid()`-scoped row in the database carries:
  /// `trips.rider_id`, `chat_messages.sender_id` and `profiles.id` are all the
  /// same uuid. The chat screen needs it to decide which side of a thread a
  /// message is on, and it cannot be derived from a `profiles` row, whose only
  /// readable column set for a rider is their own and whose id is the uuid but
  /// which may not exist at all.
  String? get uid;

  Future<void> signInWithPassword(String email, String password);
  Future<void> signInWithGoogle();

  /// Creates the account.
  ///
  /// [phone] is required and is not optional decoration: the `contact` function
  /// hands this number to the driver who is picking the rider up, so an account
  /// without one is a driver standing at a kerb with nobody to call. It goes in
  /// the signup metadata so the `profiles` row is created with it, rather than
  /// being written afterwards.
  Future<void> signUp(
    String email,
    String password,
    String fullName,
    String phone,
  );
  Future<void> sendResetOtp(String email);
  Future<void> verifyOtpAndSetPassword(
    String email,
    String code,
    String password,
  );

  /// Ends the session and returns to the sign-in screen.
  ///
  /// Cannot throw, and must not appear to have failed: `_AuthGate` swaps the
  /// shell for the login screen off `onAuthStateChange`, which GoTrue fires as
  /// soon as the local session is cleared — before the token revoke is even
  /// attempted. A button that reported a failure after the rider was already
  /// back on the login screen would be reporting a problem with a state the
  /// rider has already left.
  Future<void> signOut();
}
