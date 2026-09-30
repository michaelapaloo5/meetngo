import 'package:flutter/foundation.dart';
import 'package:mng_core/mng_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show FunctionException;

import '../data/function_failure.dart';

/// Who the number belongs to, as the server labels it.
enum ContactRole { rider, driver }

/// The other party on a trip, and how to reach them.
///
/// Carries the number **as stored** and the decision about what to do with it,
/// rather than a dialler URI. `mng_core.ghanaTelUri` and `formatGhanaPhone` are
/// where presentation belongs, and this class is the transport.
class Contact {
  const Contact({
    required this.role,
    required this.phone,
    required this.callable,
    required this.name,
  });

  factory Contact.fromJson(Map<String, dynamic> json) => Contact(
        // `role` is the *other* party, so a driver asking gets `rider`. An
        // unrecognised value is refused rather than guessed at: showing a
        // driver's number under the heading "rider" is worse than saying
        // "contact" and letting the user read the name.
        role: switch (json['role']) {
          'rider' => ContactRole.rider,
          'driver' => ContactRole.driver,
          _ => throw const FormatException('role must be rider or driver'),
        },
        phone: (json['phone'] as String?) ?? '',
        // Read the server's answer but do not trust it alone: a number that is
        // present and malformed is not callable, and the server cannot know
        // whether it is a Ghanaian one. Both checks, so a server that returned
        // `callable: true` for `+1 555 0100` still does not open a dialler onto a
        // number that belongs to somebody in Ohio.
        callable: (json['callable'] as bool? ?? false) &&
            isCallableGhanaPhone(json['phone'] as String?),
        name: (json['name'] as String?) ?? '',
      );

  /// Whether a body from the function is a contact at all.
  ///
  /// Checked before [Contact.fromJson] rather than by catching its exception,
  /// because the caller has one job on a failure -- say what went wrong -- and a
  /// `FormatException` thrown out of a factory three frames up is a worse thing
  /// to handle than a null.
  static bool looksLikeContact(Map<String, dynamic> json) {
    final role = json['role'];
    if (role != 'rider' && role != 'driver') return false;
    // `phone` and `name` may be absent on a body that is otherwise a contact --
    // a driver who has not filled in their name -- but the two that identify it
    // are not optional.
    return json.containsKey('callable') || json.containsKey('phone');
  }

  /// Whose number this is.
  final ContactRole role;

  /// The stored form: `0241234567` or `233241234567`.
  final String phone;

  /// Whether a dialler may be offered. False for absent, for malformed, and for
  /// a number this app has no business dialling.
  final bool callable;

  /// The other party's name, for "call Michael". May be empty.
  final String name;

  /// `Michael` from `Michael Apaloo`, or empty when there is no name to use.
  ///
  /// A first name and nothing else, because a button that says "Call Apaloo
  /// Michael Edem" is a button nobody reads at a junction.
  String get shortName {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '';
    return trimmed.split(RegExp(r'\s+')).first;
  }

  /// The number grouped for reading, or null when it is not a number.
  String? get display => formatGhanaPhone(phone);

  /// A `tel:` URI, or null when the number is not one to dial.
  String? get telUri => callable ? ghanaTelUri(phone) : null;

  /// What the button says: "Call Michael" where there is a name, "Call" where
  /// there is not. Never the number itself in the label -- a label that wraps
  /// around a phone number is unreadable at the size this renders.
  String get actionLabel => shortName.isEmpty ? 'Call' : 'Call $shortName';

  /// The heading for the sheet, which does say who it is: "Rider" or "Driver".
  String get roleLabel => switch (role) {
        ContactRole.rider => 'Rider',
        ContactRole.driver => 'Driver',
      };
}

/// Loads the other party on a trip.
///
/// A port rather than a direct client call because this is the one piece of
/// driver data that needs a round trip and an authorisation decision, and the
/// screen that uses it must be testable without a network.
abstract class ContactRepository {
  /// The other party on [tripId], or null when the trip is gone or the caller
  /// is not on it. Both of those are the same answer to the user, deliberately:
  /// "not on this trip" and "no such trip" are indistinguishable from outside.
  Future<Contact?> contactFor(String tripId);
}

class SupabaseContactRepository implements ContactRepository {
  SupabaseContactRepository(this._client);

  final dynamic _client;

  /// The 404 this function answers for a trip the caller is not on.
  ///
  /// Matched on the *message* rather than the status, because
  /// `functions.invoke` throws on any non-2xx and `FunctionResponse` carries no
  /// error field -- so the status is not available here, only the decoded body
  /// inside the exception. `describeFunctionFailure` is what turns that into
  /// text, and it is already the project's rule for reading one of these.
  static bool _isNotOnTrip(String message) =>
      message.contains('no such trip') || message.contains('not on this trip');

  @override
  Future<Contact?> contactFor(String tripId) async {
    Map<String, dynamic> body;
    try {
      final response = await _client.functions.invoke(
        'contact',
        body: {'tripId': tripId},
      );
      // `invoke` answers a Map on success. Anything else is a client
      // misconfiguration rather than a server answer, and treating it as an
      // empty contact would look like "this rider has no number".
      if (response is! Map) {
        throw ContactFailure('The contact service answered with something unexpected');
      }
      body = response.map((k, v) => MapEntry(k.toString(), v));
    } on FunctionException catch (e) {
      final message = describeFunctionFailure(e);
      // A trip this driver is not on is an ordinary outcome, not a fault, and
      // the UI has to survive it rather than show an error. The server sends 404
      // for both "no such trip" and "not on this trip" on purpose, so this
      // collapses them.
      if (_isNotOnTrip(message)) return null;
      throw ContactFailure(message);
    }
    if (body['error'] != null) {
      final message = body['error'].toString();
      if (_isNotOnTrip(message)) return null;
      throw ContactFailure(message);
    }
    if (!Contact.looksLikeContact(body)) {
      throw ContactFailure('The contact service answered with something unexpected');
    }
    return Contact.fromJson(body);
  }
}

/// A contact lookup that failed for a reason a driver could act on.
///
/// Its own type rather than reusing `DriverAuthFailure`: that one means "you are
/// not signed in", and reusing it would make an expired session and a network
/// fault indistinguishable to the screen, which handles them differently.
class ContactFailure implements Exception {
  ContactFailure(this.message);

  final String message;

  @override
  String toString() => 'ContactFailure: $message';
}

/// The default when no [ContactRepository] was provided.
///
/// Answers null for every trip rather than throwing, because the twenty-odd
/// `DriverFlow(...)` calls in the test suite are about offers, earnings and
/// location. A flow with no contact repository genuinely cannot produce a
/// number, and a null is what the screen already knows how to draw: a Call button
/// that is disabled and a sheet that would say "no number". Throwing would turn a
/// missing optional dependency into a crash on a screen that does not use it.
///
/// Public because `driver_flow.dart` is the one that defaults to it, and a
/// private class in another file is not usable as a default value there.
class NoContactRepository implements ContactRepository {
  const NoContactRepository();

  @override
  Future<Contact?> contactFor(String tripId) async => null;
}

/// Holds the contact for the live trip, and answers "can this be dialled".
///
/// The `busy` and `error` are here so the button on the trip screen can show a
/// spinner and a message without owning any state, and so a failed lookup is
/// visible rather than a Call button that does nothing.
class ContactController extends ChangeNotifier {
  ContactController(this._repo);

  final ContactRepository _repo;

  Contact? contact;
  String? error;
  bool busy = false;
  String? _tripId;

  /// Loads the contact for [tripId], or clears it when [tripId] is null.
  ///
  /// A second call for a different trip supersedes the first: the `if` on
  /// `_tripId` means a lookup that arrives after the driver has moved on is
  /// discarded rather than overwriting the new trip's contact with the old
  /// one's. A driver who finishes a trip and starts another is exactly the case
  /// where a late response would put the previous rider's number on screen.
  Future<void> load(String? tripId) async {
    if (_tripId == tripId && contact != null) return;
    if (tripId == null) {
      _tripId = null;
      contact = null;
      error = null;
      notifyListeners();
      return;
    }
    _tripId = tripId;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final found = await _repo.contactFor(tripId);
      // Only adopt the answer if we are still on the trip we asked about.
      if (_tripId != tripId) return;
      contact = found;
      if (found == null) {
        error = 'No contact for this trip';
      }
    } on ContactFailure catch (e) {
      if (_tripId != tripId) return;
      error = e.message;
    } catch (e) {
      if (_tripId != tripId) return;
      error = 'Could not load contact';
    } finally {
      if (_tripId == tripId) {
        busy = false;
        notifyListeners();
      }
    }
  }

  /// Adopts [value] as the current contact without going through the repository.
  ///
  /// For a test that has already resolved the contact and only needs the screen to
  /// render with it. Setting the public [contact] field would work and would also
  /// notify no listener, which is the same thing -- so this exists to say "this
  /// value is a real answer, not a placeholder" at the call site rather than to
  /// add behaviour.
  void adopt(Contact? value) {
    _tripId = value == null ? null : 'seeded';
    contact = value;
    error = value == null ? 'No contact for this trip' : null;
    busy = false;
    notifyListeners();
  }

  void clear() {
    _tripId = null;
    contact = null;
    error = null;
    busy = false;
    notifyListeners();
  }
}
