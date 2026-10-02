
/// A problem a rider has reported about one of their rides.
///
/// [reason] is a short phrase the rider chose or typed, and [detail] is anything
/// they added. Neither is a fixed list: the categories that turn out to be common
/// are counted from the rows afterwards, and a table of reasons invented before
/// anyone has reported anything is a list of what the product believes can go
/// wrong rather than what does.
class RideReport {
  const RideReport({
    required this.tripId,
    required this.reason,
    this.detail = '',
  });

  /// Reasons offered as one-tap starting points.
  ///
  /// Suggestions and not a form: the field is always editable, because a rider
  /// whose problem is none of these should not have to pick the closest one.
  /// "Other" is deliberately absent -- typing something else is one tap fewer
  /// than finding the Other chip and then typing anyway.
  static const List<String> suggestions = <String>[
    'Driver never arrived',
    'Driver cancelled on me',
    'Dropped somewhere else',
    'Waited a long time',
    'Driver was not who I expected',
    'Charged more than we agreed',
  ];

  final String tripId;
  final String reason;
  final String detail;

  /// Whether this is worth sending.
  ///
  /// The reason is the whole of it -- the detail is optional and there is no
  /// minimum length, because a rider who writes "the driver was rude" has
  /// reported something and should not be told it was too short.
  bool get isSendable => reason.trim().isNotEmpty && tripId.isNotEmpty;
}

/// Writing and reading a rider's own reports.
abstract class TripReportRepository {
  /// The report this rider already has on [tripId], or null.
  ///
  /// Read so the button can say "Reported" instead of inviting a second report
  /// of the same journey.
  Future<RideReport?> reportFor(String tripId);

  /// Write or update the rider's report on [tripId].
  ///
  /// Upsert rather than insert: the table has `unique (trip_id, reported_by)`
  /// and a plain insert would make a second report an error rather than the
  /// update it actually is.
  Future<RideReport> save(RideReport report);
}

class SupabaseTripReportRepository implements TripReportRepository {
  SupabaseTripReportRepository(this._client);

  final dynamic _client;

  @override
  Future<RideReport?> reportFor(String tripId) async {
    final user = _client.auth.currentUser;
    if (user == null) return null;
    try {
      final rows = await _client
          .from('trip_reports')
          .select('trip_id, reason, detail')
          .eq('trip_id', tripId)
          .eq('reported_by', user.id)
          .limit(1);
      final list = rows as List<dynamic>;
      if (list.isEmpty) return null;
      final row = Map<String, dynamic>.from(list.first as Map);
      return RideReport(
        tripId: (row['trip_id'] as String?) ?? tripId,
        reason: (row['reason'] as String?) ?? '',
        detail: (row['detail'] as String?) ?? '',
      );
    } catch (_) {
      // Null rather than an error: "no report yet" and "could not ask" both mean
      // the button offers to take one, which is the safe reading. The reverse
      // would hide the button from a rider who has never reported.
      return null;
    }
  }

  @override
  Future<RideReport> save(RideReport report) async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw const ReportFailure('You are signed out.');
    }
    if (!report.isSendable) {
      throw const ReportFailure('Say what went wrong first.');
    }
    try {
      final rows = await _client
          .from('trip_reports')
          .upsert({
            'trip_id': report.tripId,
            'reported_by': user.id,
            'reason': report.reason.trim(),
            'detail': report.detail.trim(),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .select('trip_id, reason, detail');
      final list = rows as List<dynamic>;
      if (list.isNotEmpty) {
        final row = Map<String, dynamic>.from(list.first as Map);
        return RideReport(
          tripId: (row['trip_id'] as String?) ?? report.tripId,
          reason: (row['reason'] as String?) ?? report.reason,
          detail: (row['detail'] as String?) ?? report.detail,
        );
      }
      return report;
    } catch (e) {
      // PostgREST answers a refused write with a 4xx and an error body, and a
      // `TypeError` from a malformed row arrives as an `Error` rather than an
      // `Exception`, so both clauses are needed. The rider's own words are worth
      // more than the database's, so the sheet keeps them either way.
      throw ReportFailure('Could not send that. Try again in a moment.');
    }
  }
}

/// A report that did not reach the database.
///
/// Separate from the repository's internals on purpose: the sheet shows this and
/// keeps the text the rider typed, because losing somebody's description of a bad
/// ride to a failed write is the worst outcome here.
class ReportFailure implements Exception {
  const ReportFailure(this.message);
  final String message;
  @override
  String toString() => message;
}
