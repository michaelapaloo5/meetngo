import 'package:mng_core/mng_core.dart';

/// A row of `trips` as the rider's own history needs to read it.
///
/// [Trip.fromJson] is the shared parser and it is not changed here, because
/// `mng_core` is a package both apps depend on and this app must not be the
/// thing that reshapes a model the driver app also uses. It parses the columns
/// the ride itself is made of and has no field for `created_at`, so the one
/// value this list is sorted by and shows as a date is read alongside it and
/// carried here.
///
/// The row is read as a whole, so `BookedTrip.fromRow` re-parses from the same
/// map the [Trip] came from rather than asking the caller to pass both.
class BookedTrip {
  const BookedTrip({required this.trip, required this.createdAt});

  factory BookedTrip.fromRow(Map<String, dynamic> row) => BookedTrip(
        trip: Trip.fromJson(row),
        // `created_at` is `timestamptz not null default now()`, so it is
        // always present and always ISO-8601. The fallback is a parse failure
        // rather than a missing key, and it is `DateTime.fromMillisecondsSinceEpoch`
        // rather than `DateTime.now()` so a malformed row reads as the epoch
        // — obviously wrong — instead of as "booked just now".
        createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );

  final Trip trip;
  final DateTime createdAt;

  String get id => trip.id;
  TripState get state => trip.state;
  TripStop get pickup => trip.pickup;
  TripStop get dropoff => trip.dropoff;
  double get fareGhs => trip.fareGhs;
  double get distanceKm => trip.distanceKm;
  RideCategory get category => trip.category;
  String? get pickupOtp => trip.pickupOtp;
  bool get isActive => trip.state.isActive;
}
