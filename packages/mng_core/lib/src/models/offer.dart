/// How long an offer stays live, and the Dart half of the pair with
/// `OFFER_TTL_SECONDS` in `supabase/functions/request-ride/index.ts`.
///
/// This was 20 seconds, which is not enough time to do what an offer asks: read
/// a destination you have never heard of, decide whether the fare covers the
/// drive, and tap accept, with the phone in a pocket and Accra traffic outside.
/// A driver slower than the clock lost the ride to whoever was faster, and
/// because the nearest driver is always the fastest to react, that quietly
/// meant the nearest driver took everything and everyone else took nothing.
///
/// Five minutes, and the two numbers change together. The server writes
/// `offers.expires_at`; this constant exists so the app can reason about an
/// offer without a round trip, and a mismatch between them is a card that
/// claims to be expired while the server still considers it live, or the
/// reverse -- a card the driver taps and is told "that offer has gone".
const Duration kOfferTtl = Duration(seconds: 300);

enum OfferState { pending, accepted, declined, expired, released }

class Offer {
  const Offer({
    required this.id,
    required this.tripId,
    required this.driverId,
    required this.fareGhs,
    required this.pickupDistanceKm,
    required this.expiresAt,
    this.state = OfferState.pending,
  });

  factory Offer.fromJson(Map<String, dynamic> json) => Offer(
    id: json['id'] as String,
    tripId: json['trip_id'] as String,
    driverId: json['driver_id'] as String,
    fareGhs: (json['fare_ghs'] as num).toDouble(),
    pickupDistanceKm: (json['pickup_distance_km'] as num).toDouble(),
    expiresAt: DateTime.parse(json['expires_at'] as String),
    state: OfferState.values.byName((json['state'] as String?) ?? 'pending'),
  );

  final String id;
  final String tripId;
  final String driverId;
  final double fareGhs;
  final double pickupDistanceKm;
  final DateTime expiresAt;
  final OfferState state;

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  int get secondsRemaining {
    final seconds = expiresAt.difference(DateTime.now()).inSeconds;
    return seconds < 0 ? 0 : seconds;
  }

  Offer copyWith({OfferState? state}) => Offer(
    id: id,
    tripId: tripId,
    driverId: driverId,
    fareGhs: fareGhs,
    pickupDistanceKm: pickupDistanceKm,
    expiresAt: expiresAt,
    state: state ?? this.state,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'trip_id': tripId,
    'driver_id': driverId,
    'fare_ghs': fareGhs,
    'pickup_distance_km': pickupDistanceKm,
    'expires_at': expiresAt.toIso8601String(),
    'state': state.name,
  };
}
