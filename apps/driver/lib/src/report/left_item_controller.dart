import 'package:flutter/foundation.dart';

/// A report that an item was left in the car.
///
/// Immutable, and compared by value for the same reason `ChatMessage` is: the
/// realtime stream re-emits the whole list and identity comparison would repaint
/// the card every time.
@immutable
class LeftItemReport {
  const LeftItemReport({
    required this.id,
    required this.tripId,
    required this.item,
    required this.description,
    required this.status,
    required this.staffNote,
    required this.createdAt,
    this.returnedAt,
  });

  final String id;
  final String tripId;
  final String item;
  final String description;

  /// `open` or `returned`, and nothing else. The constraint is `check (status in
  /// ('open','returned'))` and this mirrors it -- the server is the authority and
  /// this is the client agreeing with it rather than a second rule.
  final String status;

  /// The employee's own words.
  ///
  /// Readable by the driver on purpose. RLS works on rows, so there is no way to
  /// hide one column from a row-level policy, and an employee who writes "rider
  /// collected it, it was in the boot" has written something the driver needs to
  /// be able to read. `verify-left-item.mjs` asserts that the driver can see it,
  /// so that a future attempt to hide it arrives as a failing check.
  final String staffNote;

  final DateTime createdAt;
  final DateTime? returnedAt;

  bool get isOpen => status == 'open';
  bool get isReturned => status == 'returned';

  factory LeftItemReport.fromJson(Map<String, dynamic> json) => LeftItemReport(
    id: json['id'] as String,
    tripId: json['trip_id'] as String,
    item: (json['item'] as String?) ?? '',
    description: (json['description'] as String?) ?? '',
    status: (json['status'] as String?) ?? 'open',
    staffNote: (json['staff_note'] as String?) ?? '',
    createdAt: DateTime.parse(json['created_at'] as String).toUtc(),
    returnedAt: json['returned_at'] == null
        ? null
        : DateTime.parse(json['returned_at'] as String).toUtc(),
  );

  /// What the driver is shown as the current state, in their own terms.
  ///
  /// Not "status: returned". A driver who reported a lost phone does not have a
  /// status; they have been told whether somebody got it back.
  String get stateLabel => isReturned
      ? 'Handed back'
      : staffNote.trim().isEmpty
      ? 'Nobody has got it yet'
      : 'Answered';

  @override
  bool operator ==(Object other) =>
      other is LeftItemReport &&
      other.id == id &&
      other.tripId == tripId &&
      other.item == item &&
      other.description == description &&
      other.status == status &&
      other.staffNote == staffNote &&
      other.createdAt == createdAt &&
      other.returnedAt == returnedAt;

  @override
  int get hashCode =>
      Object.hash(id, tripId, item, description, status, staffNote, createdAt, returnedAt);
}

/// Filing and correcting a report.
///
/// The two rules that live here rather than in the screen:
///
/// **One report per trip.** The database enforces it with a unique constraint on
/// `(trip_id, reporter_id)`, so a driver who realises they left something in their
/// own car *corrects* the report rather than adding a second one. A correction
/// replaces the first account; five rows for one lost pair of sunglasses is a
/// queue an employee cannot read.
///
/// **The upsert needs two things.** `.upsert(row, onConflict: ...)` sends both the
/// `?on_conflict=` query parameter and `Prefer: resolution=merge-duplicates`, and
/// this server honours neither alone -- measured, in `toolchain/probe-upsert.mjs`,
/// where `Prefer: resolution=merge-duplicates` on its own comes back 409 with
/// `duplicate key value violates unique constraint`. So the `onConflict` argument
/// here is load-bearing and must not be dropped as a tidy-up.
class LeftItemController extends ChangeNotifier {
  LeftItemController({required this.tripId});

  final String tripId;

  LeftItemRepository? repository;

  LeftItemReport? _report;
  bool _loading = true;
  bool _saving = false;
  String? _problem;

  LeftItemReport? get report => _report;
  bool get loading => _loading;
  bool get saving => _saving;
  String? get problem => _problem;

  /// Whether there is already a report, which changes the button's wording from
  /// "Send report" to "Update report".
  bool get hasReported => _report != null;

  /// How the sheet opens, given whether a report exists.
  String get actionLabel => hasReported ? 'Update report' : 'Send report';

  static const int kMaxItem = 200;
  static const int kMaxDescription = 1000;

  /// Why [item] cannot be reported, or null if it can.
  ///
  /// 200 and 1000 are the `check` constraints on the table, so a driver typing
  /// past them is stopped by the same rule the server would refuse them with --
  /// and stopped before the round trip rather than after it.
  static String? problemFor({required String item, required String description}) {
    if (item.trim().isEmpty) return 'What was left behind?';
    if (item.trim().length > kMaxItem) {
      return 'Too long. ${item.trim().length} of $kMaxItem characters';
    }
    if (description.length > kMaxDescription) {
      return 'Too long. ${description.length} of $kMaxDescription characters';
    }
    return null;
  }

  static bool isSendable({required String item, required String description}) =>
      problemFor(item: item, description: description) == null;

  Future<void> load() async {
    final repo = repository;
    if (repo == null) {
      _loading = false;
      _problem = 'Reporting is not available right now.';
      notifyListeners();
      return;
    }
    _loading = true;
    notifyListeners();
    try {
      _report = await repo.reportFor(tripId);
      _loading = false;
      _problem = null;
    } on LeftItemFailure catch (e) {
      _loading = false;
      _problem = e.message;
    } finally {
      notifyListeners();
    }
  }

  /// File the report, or correct the one already filed.
  Future<bool> save({required String item, required String description}) async {
    final problem = problemFor(item: item, description: description);
    if (problem != null) {
      _problem = problem;
      notifyListeners();
      return false;
    }
    final repo = repository;
    if (repo == null) {
      _problem = 'Reporting is not available right now.';
      notifyListeners();
      return false;
    }
    _saving = true;
    _problem = null;
    notifyListeners();
    try {
      // The row that comes back is adopted, not discarded. Without it the driver
      // would see their own description in the field and an empty card below it
      // until the next load, which reads as the report not having been saved.
      final saved = await repo.save(
        tripId: tripId,
        item: item.trim(),
        description: description.trim(),
      );
      _report = saved;
      return true;
    } on LeftItemFailure catch (e) {
      _problem = e.message;
      return false;
    } finally {
      _saving = false;
      notifyListeners();
    }
  }
}

/// Where reports come from and go to.
abstract class LeftItemRepository {
  /// This trip's report, or null when nothing has been filed.
  Future<LeftItemReport?> reportFor(String tripId);

  /// File or correct it. Returns the row as it now stands.
  Future<LeftItemReport> save({
    required String tripId,
    required String item,
    required String description,
  });
}

class LeftItemFailure implements Exception {
  const LeftItemFailure(this.message);
  final String message;

  @override
  String toString() => 'LeftItemFailure: $message';
}

/// The default when no [LeftItemRepository] was provided.
///
/// Reports "nothing filed" and refuses a save, for the same reason
/// `NoContactRepository` answers null: the `DriverFlow(...)` calls in the test
/// suite are about offers, earnings and location. The refusal is a
/// [LeftItemFailure] with a sentence rather than a null, because a save that
/// silently succeeded into nothing is worse than one that says it could not.
class NoLeftItemRepository implements LeftItemRepository {
  const NoLeftItemRepository();

  @override
  Future<LeftItemReport?> reportFor(String tripId) async => null;

  @override
  Future<LeftItemReport> save({
    required String tripId,
    required String item,
    required String description,
  }) async {
    throw const LeftItemFailure('Reporting is not available right now.');
  }
}