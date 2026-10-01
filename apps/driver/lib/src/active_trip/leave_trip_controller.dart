import 'package:flutter/foundation.dart';
import 'package:mng_core/mng_core.dart';

/// Why a driver is leaving a trip.
///
/// Free text in the database, and this is the copy that goes with it. The reason
/// exists for whoever reads these later -- a dispatcher, or an operations person
/// looking at why rides in one neighbourhood keep falling over -- so the prompt
/// asks what somebody would need to know, and answers it with suggestions rather
/// than a blank box.
enum LeaveReason {
  riderNotAtPickup('The rider is not at the pickup', 'rider_absent'),
  wrongLocation('I cannot find the pickup', 'cannot_find'),
  riderNotAnswering('The rider is not answering', 'not_answering'),
  vehicleProblem('My vehicle has a problem', 'vehicle'),
  unsafe('I do not feel safe here', 'unsafe'),
  other('Something else', 'other');

  const LeaveReason(this.prompt, this.slug);

  /// What the driver reads. A sentence, not a label.
  final String prompt;

  /// What goes in the row.
  ///
  /// A slug and not the prompt, for two reasons: the prompt is copy that will be
  /// reworded, and a queue somebody filters on must not break when it is. The
  /// prompt is stored alongside it in the description field so the exact words are
  /// never lost.
  final String slug;
}

/// Leaving a trip.
///
/// The rules are here rather than in the screen, because both of the ones that
/// matter are rules about what is allowed and they must not be able to drift
/// between the button's label and the call it makes.
///
/// ## A driver may leave while arriving and may not while the rider is aboard
///
/// `ongoing` means somebody is in the vehicle. "Leaving" that is stranding them,
/// so the controller refuses it and the screen never offers it -- the driver is
/// told to finish the trip or call the rider instead. That is a product decision
/// as much as a safety one, and the server refuses it as well
/// (`leave-trip/handler.ts`), because a client-side check is a convenience and not
/// a boundary.
class LeaveTripController extends ChangeNotifier {
  LeaveTripController({required this.tripId});

  final String tripId;

  LeaveTripRepository? repository;

  bool _busy = false;
  String? _problem;

  bool get busy => _busy;
  String? get problem => _problem;

  /// Whether the driver may leave, given the state the trip is in.
  static bool canLeave(TripState state) => state == TripState.arriving;

  /// Why not, when [canLeave] says no. Null when they can.
  static String? refusalFor(TripState state) {
    if (canLeave(state)) return null;
    if (state == TripState.ongoing) {
      return 'The rider is in the car. Finish the trip, or call them if '
          'something is wrong.';
    }
    // Points at the control that *does* apply, rather than only saying no. A
    // driver with an offer they have not accepted needs to be told there is
    // another button, and `leave-trip/handler.ts` refuses with the same words.
    if (state == TripState.requested || state == TripState.matched) {
      return 'You do not have this trip yet. Decline the offer instead.';
    }
    return 'You cannot leave a trip you have not started.';
  }

  Future<bool> leave(LeaveReason reason, {String? detail}) async {
    final repo = repository;
    if (repo == null) {
      _problem = 'Leaving a trip is not available right now.';
      notifyListeners();
      return false;
    }
    _busy = true;
    _problem = null;
    notifyListeners();
    try {
      await repo.leave(
        tripId: tripId,
        // Both parts stored. The slug is what anybody will filter on; the
        // driver's own words are what will actually help whoever reads it, and a
        // queue of six identical slugs helps nobody.
        reason: '${reason.slug}${_detail(detail)}',
      );
      return true;
    } on LeaveTripFailure catch (e) {
      // 409 arrives here with the server's own sentence, which is better than
      // anything this file could word: the server knows the state changed under
      // us and this does not.
      _problem = e.message;
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  static String _detail(String? detail) {
    final trimmed = (detail ?? '').trim();
    if (trimmed.isEmpty) return '';
    // Capped to leave room for the slug inside the column's 300 characters.
    return ' -- ${trimmed.length > 240 ? trimmed.substring(0, 240) : trimmed}';
  }
}

/// [TripState] is `mng_core`'s, not a copy declared here. A second definition of
/// the states would be a second answer to "which states exist", and the copy
/// would not hear about a seventh one.
abstract class LeaveTripRepository {
  Future<void> leave({required String tripId, required String reason});
}

/// The default when no [LeaveTripRepository] was provided.
///
/// Refuses every withdrawal, for the same reason `NoChatRepository` refuses a
/// send: the `DriverFlow(...)` calls in the test suite are about offers, earnings
/// and location, and a repository that could not refuse would be a repository
/// with nothing left to test against.
class NoLeaveTripRepository implements LeaveTripRepository {
  const NoLeaveTripRepository();

  @override
  Future<void> leave({required String tripId, required String reason}) async {
    throw const LeaveTripFailure('Leaving a trip is not available right now.');
  }
}

class LeaveTripFailure implements Exception {
  const LeaveTripFailure(this.message);
  final String message;

  @override
  String toString() => 'LeaveTripFailure: $message';
}