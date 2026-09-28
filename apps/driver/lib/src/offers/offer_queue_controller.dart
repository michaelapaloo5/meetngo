import 'package:flutter/foundation.dart';
import 'package:mng_core/mng_core.dart';

import '../data/driver_repository.dart';

/// The driver's offer queue, newest first.
///
/// The 20-second TTL is `kOfferTtl` in `mng_core` and is not configurable
/// anywhere. [tick] is what enforces it on screen: the server's own sweeper
/// does not exist, so an offer whose `expires_at` has passed is still
/// `pending` in the database until somebody acts on it, and the only somebody
/// here is this list.
class OfferQueueController extends ChangeNotifier {
  OfferQueueController(this._repo);

  final DriverRepository _repo;

  final List<Offer> _offers = [];
  String? error;

  List<Offer> get offers => List.unmodifiable(_offers);
  Offer? get next => _offers.isEmpty ? null : _offers.first;

  /// Newest first, de-duplicated, and pending only.
  ///
  /// A non-pending offer is dropped rather than shown disabled: an offer the
  /// server has already released is not information, and an expired one is
  /// about to be gone on the next [tick] anyway.
  void add(Offer offer) {
    if (offer.state != OfferState.pending) return;
    if (_offers.any((o) => o.id == offer.id)) return;
    _offers.insert(0, offer);
    notifyListeners();
  }

  void clear() {
    if (_offers.isEmpty) return;
    _offers.clear();
    notifyListeners();
  }

  void tick() {
    final before = _offers.length;
    _offers.removeWhere((o) => o.isExpired);
    if (_offers.length != before) notifyListeners();
  }

  /// Accepts [offer], and answers whether the driver won it.
  ///
  /// A false answer keeps the offer in the queue rather than dropping it: the
  /// offer may still be live and the loss was a transport fault, and silently
  /// removing it would hide a trip the driver can still take.
  Future<bool> accept(Offer offer) async {
    error = null;
    try {
      await _repo.acceptOffer(offer.id);
      _remove(offer);
      return true;
    } on DriverAuthFailure catch (e) {
      error = e.message;
      notifyListeners();
      return false;
    }
  }

  /// Declines [offer], removing it either way.
  ///
  /// Removed on a failure too, unlike [accept]: the driver's intent was clear,
  /// and leaving a declined offer on screen with a countdown invites them to
  /// press the wrong button.
  Future<void> decline(Offer offer) async {
    error = null;
    try {
      await _repo.declineOffer(offer.id);
    } on DriverAuthFailure catch (e) {
      error = e.message;
    }
    _remove(offer);
  }

  void _remove(Offer offer) {
    final before = _offers.length;
    _offers.removeWhere((o) => o.id == offer.id);
    if (_offers.length != before) notifyListeners();
  }
}
