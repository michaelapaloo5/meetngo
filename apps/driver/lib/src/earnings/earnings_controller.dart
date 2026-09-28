import 'package:flutter/foundation.dart';

import 'earnings_repository.dart';

/// The wallet, as state a screen can read and a test can drive.
///
/// Every field is a notifying setter, for the reason `KycController`'s are: the
/// balance tiles and the withdraw button read these, and a plain public field
/// changed one with no `notifyListeners` leaves the screen showing the value
/// from before. A withdrawal that emptied the wallet would leave the "Available"
/// tile full and the button live, and the driver's next tap would be refused by
/// the controller against a balance the screen had already spent.
class EarningsController extends ChangeNotifier {
  EarningsController(this._repo);

  final EarningsRepository _repo;

  EarningsSnapshot? _snapshot;
  EarningsSnapshot? get snapshot => _snapshot;
  set snapshot(EarningsSnapshot? value) {
    _snapshot = value;
    notifyListeners();
  }

  bool _busy = false;
  bool get busy => _busy;
  set busy(bool value) {
    _busy = value;
    notifyListeners();
  }

  String? _error;
  String? get error => _error;
  set error(String? value) {
    _error = value;
    notifyListeners();
  }

  Future<void> load() async {
    busy = true;
    error = null;
    try {
      snapshot = EarningsSnapshot.fromLedger(await _repo.ledger());
    } on PayoutFailure catch (e) {
      error = e.message;
    } finally {
      busy = false;
    }
  }

  /// Withdraws [amountGhs] from the available balance.
  ///
  /// The balance after a withdrawal is computed, not re-read. The plan called
  /// `load()` here, which is the same code path that produced the balance the
  /// driver was just spending: it read the ledger back, the ledger had not
  /// changed, and the balance the driver had just withdrawn snapped to its
  /// full amount again under a "requested" message. A withdrawal is not
  /// persisted in this build -- see
  /// `SupabaseEarningsRepository.requestPayout` -- so it is applied here and
  /// lasts for the session, and the sheet says exactly that.
  Future<bool> requestPayout(double amountGhs) async {
    error = null;
    final current = _snapshot;
    final available = current?.availableGhs ?? 0.0;
    if (amountGhs <= 0) {
      error = 'Enter an amount greater than zero';
      return false;
    }
    if (amountGhs > available) {
      error = 'You only have GHS ${available.toStringAsFixed(2)} available';
      return false;
    }
    busy = true;
    try {
      await _repo.requestPayout(amountGhs: amountGhs);
      snapshot = current!.withdraw(amountGhs);
      return true;
    } on PayoutFailure catch (e) {
      error = e.message;
      return false;
    } finally {
      busy = false;
    }
  }
}
