import 'package:supabase_flutter/supabase_flutter.dart';

class PayoutFailure implements Exception {
  const PayoutFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One line of a driver's earnings history.
///
/// `kind` is one of the five values the `ledger_entries` check constraint
/// allows (`init.sql:126`): `fare`, `commission`, `compensation`, `void`,
/// `bonus`. A kind outside that set cannot reach this class, because the
/// database will not store it.
class LedgerEntry {
  const LedgerEntry({
    required this.id,
    required this.kind,
    required this.amountGhs,
    required this.note,
    required this.createdAt,
  });

  factory LedgerEntry.fromJson(Map<String, dynamic> json) => LedgerEntry(
        id: json['id'] as String,
        kind: json['kind'] as String,
        amountGhs: (json['amount_ghs'] as num).toDouble(),
        note: (json['note'] as String?) ?? '',
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  final String id;
  final String kind;
  final double amountGhs;
  final String note;
  final DateTime createdAt;
}

/// Three balances, derived from the ledger rather than stored.
///
/// The ledger is the only per-trip record a driver has: `own ledger` is a
/// SELECT policy and nothing else, so a balance that disagreed with it would
/// have nothing behind it. Commission is a negative `commission` row, so
/// subtracting it from the available balance is the same arithmetic the
/// `complete-trip` settlement did when it wrote the row.
class EarningsSnapshot {
  const EarningsSnapshot({
    required this.availableGhs,
    required this.pendingGhs,
    required this.lifetimeGhs,
    required this.entries,
  });

  factory EarningsSnapshot.fromLedger(List<LedgerEntry> rows) {
    var available = 0.0;
    var lifetime = 0.0;
    for (final entry in rows) {
      if (entry.kind == 'void') {
        // A void is the settlement reversing a charge, so it zeroes what the
        // charge had built rather than continuing past zero into a negative
        // balance a driver has never earned.
        available = 0.0;
        lifetime += entry.amountGhs;
        continue;
      }
      available += entry.amountGhs;
      lifetime += entry.amountGhs;
    }
    return EarningsSnapshot(
      availableGhs: _round2(available < 0 ? 0.0 : available),
      pendingGhs: 0.0,
      lifetimeGhs: _round2(lifetime),
      entries: rows,
    );
  }

  /// Nothing is pending in this build: a fare is written to the ledger by
  /// `complete-trip` at the moment the trip completes, so there is no
  /// unsettled interval for a "pending" figure to describe. It is a tile on the
  /// wallet and it is zero, rather than a number invented to fill it.
  final double availableGhs;
  final double pendingGhs;
  final double lifetimeGhs;
  final List<LedgerEntry> entries;

  EarningsSnapshot withdraw(double amountGhs) => EarningsSnapshot(
        availableGhs: _round2(availableGhs - amountGhs),
        pendingGhs: pendingGhs,
        lifetimeGhs: lifetimeGhs,
        entries: entries,
      );

  static double _round2(double value) =>
      double.parse(value.toStringAsFixed(2));
}

abstract class EarningsRepository {
  Future<List<LedgerEntry>> ledger();
  Future<void> requestPayout({required double amountGhs});
}

class SupabaseEarningsRepository implements EarningsRepository {
  SupabaseEarningsRepository(this._client);

  final SupabaseClient _client;

  /// Read per call, not captured at construction.
  ///
  /// The id does not exist until there is a session, and a provider that
  /// captured it at build time would hold whichever value the first frame
  /// happened to have -- the empty string, for the whole of an unconfigured
  /// launch -- and read another driver's ledger, or nobody's.
  String get _driverId {
    final id = _client.auth.currentUser?.id;
    if (id == null) throw const PayoutFailure('Not signed in');
    return id;
  }

  @override
  Future<List<LedgerEntry>> ledger() async {
    // Awaiting a postgrest builder yields the rows, and a failed read throws
    // `PostgrestException` rather than handing back an error field.
    final driverId = _driverId;
    final List<dynamic> rows;
    try {
      rows = await _client
          .from('ledger_entries')
          .select('*')
          .eq('driver_id', driverId)
          .order('created_at', ascending: false);
    } on PostgrestException catch (e) {
      throw PayoutFailure(e.message);
    }
    return rows
        .map((row) => LedgerEntry.fromJson(row as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<void> requestPayout({required double amountGhs}) async {
    if (amountGhs <= 0) {
      throw const PayoutFailure('Enter an amount greater than zero');
    }
    // Nothing is sent, and nothing is written.
    //
    // The plan called `demo-pay` with `{'action': 'payout', 'amountGhs': ...}`.
    // That function takes a `tripId` and a `method` and charges a rider
    // (`demo-pay/handler.ts:14-21`); it has no `payout` action, so the body was
    // refused with a 400. Even if it had one, `payouts` carries a SELECT
    // policy and no INSERT policy (`init.sql:551-552`), so a driver cannot
    // create their own payout row at all, and `ledger_entries.kind` has no
    // `payout` value to record one with.
    //
    // So a withdrawal is applied to this session's balance and to nothing else,
    // which is what the payout sheet already told the driver: it is a demo, no
    // money moves, and no network is called. What is not done is pretend the
    // call was made.
  }
}
