import 'package:flutter/foundation.dart';

import '../data/failure_message.dart';
import '../data/profile_repository.dart';

enum ProfileStatus { loading, loaded, missing, failed }

/// The signed-in rider's own `profiles` row, and the two fields they can edit.
///
/// Held above the tab bar rather than inside the profile tab, because the home
/// screen greets the rider by the name that lives in this row and a greeting
/// that is only correct after the profile tab has been opened is not a
/// greeting.
class RiderProfileController extends ChangeNotifier {
  RiderProfileController(this._profiles);

  final ProfileRepository _profiles;

  ProfileStatus _status = ProfileStatus.loading;
  ProfileStatus get status => _status;

  RiderProfile? _profile;
  RiderProfile? get profile => _profile;

  String? _error;
  String? get error => _error;

  bool _saving = false;
  bool get saving => _saving;

  bool _signingOut = false;
  bool get signingOut => _signingOut;

  /// What the home screen greets with. Falls back rather than rendering ", ".
  String get greetingName => _profile?.greetingName ?? 'there';

  Future<void> load() async {
    _error = null;
    _status = ProfileStatus.loading;
    notifyListeners();
    try {
      final row = await _profiles.me();
      _profile = row;
      // A rider with no `profiles` row is not a failure: every account created
      // before sign-up began persisting the name has none, and the database
      // creates the row on signup rather than on a profile read. It is a real
      // state with its own screen, distinct from a read that never arrived.
      _status =
          row == null ? ProfileStatus.missing : ProfileStatus.loaded;
    } on Object catch (e) {
      _error = describeFailure(e);
      _status = ProfileStatus.failed;
    }
    notifyListeners();
  }

  /// Writes back `full_name` and `phone`, and nothing else.
  ///
  /// The values are trimmed and the name is required: `profiles.full_name` is
  /// `not null` but not length-checked, so an empty name is accepted by the
  /// database and would leave the home screen falling back to "there" with no
  /// way for the rider to tell that is what happened. Refusing it here gives
  /// them a sentence instead.
  Future<bool> save({required String fullName, required String phone}) async {
    if (_saving) return false;
    final name = fullName.trim();
    if (name.isEmpty) {
      _error = 'Enter your name';
      notifyListeners();
      return false;
    }
    _saving = true;
    _error = null;
    notifyListeners();
    try {
      final row = await _profiles.save(
        fullName: name,
        phone: phone.trim(),
      );
      if (row == null) {
        _error = 'Your details could not be saved';
        return false;
      }
      _profile = row;
      _status = ProfileStatus.loaded;
      return true;
    } on Object catch (e) {
      _error = describeFailure(e);
      return false;
    } finally {
      _saving = false;
      notifyListeners();
    }
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  /// Ends the session. `onSignedOut` is the screen's cue to pop, because the
  /// app's auth gate swaps the whole shell for the login screen on its own and
  /// a still-mounted profile screen underneath it would be popped twice.
  Future<void> signOut(Future<void> Function() onSignedOut) async {
    if (_signingOut) return;
    _signingOut = true;
    notifyListeners();
    try {
      await onSignedOut();
    } finally {
      _signingOut = false;
      notifyListeners();
    }
  }
}
