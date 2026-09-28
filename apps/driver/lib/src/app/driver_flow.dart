import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mng_core/mng_core.dart';

import '../active_trip/active_trip_controller.dart';
import '../data/driver_repository.dart';
import '../earnings/earnings_repository.dart';
import '../location/location_controller.dart';
import '../location/location_reader.dart';
import '../offers/availability_controller.dart';
import '../offers/offer_queue_controller.dart';

/// The driver's progress through the app, and nothing else.
///
/// Two facts decide every stage the shell shows and neither of them is a
/// navigation event: [profile] -- in particular `kyc_status` -- and the live
/// trip. `match_offers_for_trip` only matches `kyc_status = 'approved'`
/// drivers, so a driver who is not approved must not reach the offer queue at
/// all, and that gate lives here rather than in the shell so there is one
/// answer to "may this driver drive" and one place it is written down.
///
/// Every method catches. A throw out of any of them reaches the framework as an
/// unhandled async error with nothing on the driver's screen.
///
/// The controllers are made here and handed to the screens, rather than created
/// inside a screen and thrown away with it: the toggle's state is the driver's,
/// not the home tab's, and a controller rebuilt on every rebuild would drop an
/// in-flight request and a pending error.
///
/// [LocationController] lives here for the same reason and one more: a fix is
/// the driver's, not a screen's, so both the home tab and the live trip read
/// the same one, and a driver who goes offline and back online does not have to
/// wait for a second fix. [locationReader] is a constructor argument so the
/// whole flow can be driven by a fake -- `Geolocator` is a plugin, and a test
/// binding has no channel to answer on.
class DriverFlow extends ChangeNotifier {
  DriverFlow({
    required this.drivers,
    required this.earnings,
    LocationReader? locationReader,
  }) : _locationReader = locationReader ?? const GeolocatorLocationReader();

  final DriverRepository drivers;
  final EarningsRepository earnings;
  final LocationReader _locationReader;

  DriverProfile? profile;
  bool loading = false;
  String? error;

  /// Whether the driver may go online, and therefore see the offer queue.
  bool get kycApproved => profile?.isApproved ?? false;

  StreamSubscription<DriverProfile>? _profileWatch;

  /// Whether [load] has completed without throwing. Gates [startProfileWatch].
  bool _readSucceeded = false;

  AvailabilityController? _availability;
  OfferQueueController? _offers;
  ActiveTripController? _activeTrip;
  LocationController? _location;

  AvailabilityController get availability =>
      _availability ??= AvailabilityController(drivers);

  OfferQueueController get offers => _offers ??= OfferQueueController(drivers);

  ActiveTripController get activeTrip =>
      _activeTrip ??= ActiveTripController(drivers);

  LocationController get location =>
      _location ??= LocationController(_locationReader, drivers);

  /// Asks the operating system where the driver is.
  ///
  /// A convenience over [location] and [refresh] so the shell has one call to
  /// make, and deliberately not awaited by the caller: a phone that takes
  /// twenty seconds to find a satellite must not hold the first frame.
  Future<void> refreshLocation() => location.refresh();

  /// Reads the profile, seeds the availability toggle, and reconciles a stored
  /// `onTrip` that no longer has a trip behind it.
  Future<void> load() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      final me = await drivers.me();
      _readSucceeded = true;
      profile = me;
      if (me == null) return;
      final toggle = availability;
      toggle.adoptStored(me.availability);
      if (me.availability == DriverAvailability.onTrip) {
        // The phone died mid-trip, or the app was killed. A driver whose
        // profile still reads `onTrip` with no live trip is invisible to the
        // matcher forever, and the driver has no way to work out why, so a
        // stored `onTrip` with no trip behind it goes back to `online`.
        if (await drivers.activeTrip() == null) {
          await toggle.setOnline(true);
          profile = profile?.copyWith(availability: DriverAvailability.online);
        }
      }
    } on DriverAuthFailure catch (e) {
      error = e.message;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Starts watching the profile row.
  ///
  /// The offer queue is a separate watch, started by the shell once the driver
  /// is past the KYC gate: subscribing to `offers` for a driver who cannot
  /// receive one is a round trip that can only ever return nothing.
  ///
  /// Refused until a read has actually succeeded. The shell calls this straight
  /// after [load], and [load] catches rather than throws, so on a failed read
  /// this used to open a subscription that could hand back a profile the failed
  /// read never produced -- and the first event replaced `profile` and with it
  /// the KYC gate, moving a driver whose status nobody had successfully read
  /// into the offer queue. A stream is not a substitute for the read it is
  /// supposed to follow.
  void startProfileWatch() {
    if (!_readSucceeded || _profileWatch != null) return;
    _profileWatch = drivers.watchMe().listen(
      (updated) {
        profile = updated;
        notifyListeners();
      },
      onError: (Object e) {
        error = e.toString();
        notifyListeners();
      },
    );
  }

  /// Feeds one offer into the queue. Called by the shell's offer subscription.
  void addOffer(Offer offer) => offers.add(offer);

  /// Reads the live trip, for the shell's poll.
  Future<Trip?> readActiveTrip() async {
    try {
      return await drivers.activeTrip();
    } on DriverAuthFailure catch (e) {
      error = e.message;
      notifyListeners();
      return null;
    }
  }

  /// Puts the flow back to the home tab and forgets the finished trip.
  void reset() {
    _activeTrip?.trip = null;
    _activeTrip = null;
    offers.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _profileWatch?.cancel();
    _profileWatch = null;
    _availability?.dispose();
    _offers?.dispose();
    _activeTrip?.dispose();
    _location?.dispose();
    super.dispose();
  }
}
