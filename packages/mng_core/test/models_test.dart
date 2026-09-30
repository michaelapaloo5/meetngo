import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';

void main() {
  group('GeoPoint', () {
    test('distance between two Accra points is about 2 km', () {
      const a = GeoPoint(5.6037, -0.1870);
      const b = GeoPoint(5.6200, -0.1870);
      expect(a.distanceKmTo(b), closeTo(1.81, 0.05));
    });

    test('identical points are zero distance', () {
      const a = GeoPoint(5.6037, -0.1870);
      expect(a.distanceKmTo(a), 0.0);
    });

    test('round-trips through JSON and compares by value', () {
      const p = GeoPoint(5.6037, -0.1870);
      final back = GeoPoint.fromJson(p.toJson());
      expect(back.lat, closeTo(5.6037, 1e-9));
      expect(back, p);
    });
  });

  group('Trip', () {
    final json = <String, dynamic>{
      'id': 't1',
      'rider_id': 'r1',
      'driver_id': 'd1',
      'category': 'standard',
      'state': 'matched',
      'pickup': {
        'label': 'Pickup',
        'point': {'lat': 5.6037, 'lng': -0.1870},
        'address': 'Osu, Accra',
      },
      'dropoff': {
        'label': 'Dropoff',
        'point': {'lat': 5.6200, 'lng': -0.1870},
        'address': 'Airport Residential',
      },
      'distance_km': 1.81,
      'fare_ghs': 12.50,
      'is_demo': true,
    };

    test('parses a trip row from Postgres json', () {
      final trip = Trip.fromJson(json);
      expect(trip.id, 't1');
      expect(trip.state, TripState.matched);
      expect(trip.category, RideCategory.standard);
      expect(trip.fareGhs, closeTo(12.50, 0.001));
      expect(trip.isDemo, isTrue);
      expect(trip.hasDriver, isTrue);
      expect(trip.pickup.address, 'Osu, Accra');
    });

    test('parses the pickup code, and a row without one is null not empty', () {
      // The rider reads this out to the driver, so the difference between
      // "absent" and "blank" is the difference between an unreadable code and
      // a screen that says the code is unavailable.
      expect(Trip.fromJson(json).pickupOtp, isNull);
      expect(Trip.fromJson({...json, 'pickup_otp': '4821'}).pickupOtp, '4821');
      expect(
        Trip.fromJson(Trip.fromJson({...json, 'pickup_otp': '4821'}).toJson())
            .pickupOtp,
        '4821',
      );
    });

    test('copyWith changes state and leaves everything else alone', () {
      final trip = Trip.fromJson(json);
      final moved = trip.copyWith(state: TripState.arriving);
      expect(moved.state, TripState.arriving);
      expect(moved.id, trip.id);
      expect(moved.fareGhs, trip.fareGhs);
      expect(moved.pickup, trip.pickup);
    });

    test('clearDriver unassigns the driver', () {
      final trip = Trip.fromJson(json);
      expect(trip.copyWith(clearDriver: true).driverId, isNull);
      expect(trip.copyWith(clearDriver: true).hasDriver, isFalse);
    });

    test('json round-trip preserves identity and geometry', () {
      final trip = Trip.fromJson(json);
      final back = Trip.fromJson(trip.toJson());
      expect(back.id, trip.id);
      expect(back.state, trip.state);
      expect(back.driverId, trip.driverId);
      expect(back.pickup.point, trip.pickup.point);
      expect(back.dropoff.point, trip.dropoff.point);
    });
  });

  group('Offer', () {
    Offer build(Duration ttl) => Offer(
      id: 'o1',
      tripId: 't1',
      driverId: 'd1',
      fareGhs: 12.50,
      pickupDistanceKm: 0.8,
      expiresAt: DateTime.now().add(ttl),
    );

    test('pending offer is not expired while ttl remains', () {
      expect(build(kOfferTtl).isExpired, isFalse);
    });

    test('offer past ttl reports expired', () {
      expect(build(const Duration(seconds: -1)).isExpired, isTrue);
    });

    test('seconds remaining never goes negative', () {
      expect(build(const Duration(minutes: -5)).secondsRemaining, 0);
    });

    // Five minutes, not the 20 seconds this used to assert. 20 seconds is not
    // enough to read an unfamiliar destination, decide whether the fare covers
    // the drive, and tap accept -- and because the nearest driver is always the
    // fastest to react, a short TTL quietly gave every offer to the same
    // driver. The twin of this assertion is `OFFER_TTL_SECONDS` in
    // `supabase/functions/request-ride/index.ts`; the two must agree or a card
    // claims one thing and the server does another.
    test('ttl is the hard-coded five minutes', () {
      expect(kOfferTtl, const Duration(seconds: 300));
    });

    test('copyWith moves the offer to released', () {
      final offer = build(kOfferTtl);
      expect(
        offer.copyWith(state: OfferState.released).state,
        OfferState.released,
      );
      expect(offer.state, OfferState.pending);
    });
  });

  group('DriverProfile', () {
    DriverProfile build({
      KycStatus kyc = KycStatus.approved,
      DriverAvailability availability = DriverAvailability.online,
      String phone = '0240000000',
    }) => DriverProfile(
      id: 'd1',
      fullName: 'Jane Cooper',
      phone: phone,
      photoUrl: '',
      rating: 4.8,
      tripCount: 148,
      kyc: kyc,
      availability: availability,
    );

    test('copyWith records a new phone and changes nothing else', () {
      // The phone is the one field that changes after the profile is built: the
      // gate asks for it once the documents are already approved, so the profile
      // the driver was approved on and the profile they carry are not the same
      // object. Getting this wrong corrupts their approval state, so the other
      // fields are asserted rather than assumed.
      final before = build();
      final after = before.copyWith(phone: '0551234567');

      expect(after.phone, '0551234567');
      expect(before.phone, '0240000000', reason: 'the original must not be mutated');
      expect(after.id, before.id);
      expect(after.fullName, before.fullName);
      expect(after.rating, before.rating);
      expect(after.tripCount, before.tripCount);
      expect(after.kyc, before.kyc);
      expect(after.availability, before.availability);
    });

    test('copyWith without a phone leaves the one it has', () {
      // The shadowing bug `copyWith` already documents for `role`, applied to
      // `phone`: a bare pass-through of the nullable parameter would hand null to
      // a non-nullable field on every call that did not mention the phone, which
      // is every call except the gate's.
      expect(build().copyWith(kyc: KycStatus.rejected).phone, '0240000000');
    });

    test('a phone can be cleared by passing an empty string, not by null', () {
      // `phone: null` means "do not change" in a `copyWith`, so the only way to
      // express "this driver has no number" is an explicit empty string -- which
      // is exactly what the column holds for a driver who never gave one, and
      // what `isCallableGhanaPhone` reads.
      final cleared = build().copyWith(phone: '');
      expect(cleared.phone, isEmpty);
      expect(isCallableGhanaPhone(cleared.phone), isFalse);
      expect(build().copyWith(phone: '').copyWith(phone: null).phone, isEmpty);
    });

    test('approved online driver can accept offers', () {
      expect(build().isApproved, isTrue);
      expect(build().canAcceptOffers, isTrue);
    });

    test('unapproved driver cannot accept offers even when online', () {
      expect(build(kyc: KycStatus.pending).canAcceptOffers, isFalse);
    });

    test('approved driver already on a trip cannot accept offers', () {
      expect(
        build(availability: DriverAvailability.onTrip).canAcceptOffers,
        isFalse,
      );
    });
  });

  group('Payment and Rating', () {
    test('succeeded demo payment is terminal', () {
      const p = Payment(
        id: 'p1',
        tripId: 't1',
        amountGhs: 12.50,
        method: PayMethod.momo,
        state: PaymentState.succeeded,
        isDemo: true,
      );
      expect(p.isDemo, isTrue);
      expect(p.state.isTerminal, isTrue);
    });

    test('pending payment is not terminal', () {
      expect(PaymentState.pending.isTerminal, isFalse);
    });

    test('rating stars are valid only from 1 to 5', () {
      expect(Rating.isValidStars(1), isTrue);
      expect(Rating.isValidStars(5), isTrue);
      expect(Rating.isValidStars(0), isFalse);
      expect(Rating.isValidStars(6), isFalse);
    });
  });

  group('Vehicle', () {
    test('display name joins make and model', () {
      final v = Vehicle(
        id: 'v1',
        ownerId: 'd1',
        category: VehicleCategory.sedan,
        make: 'Honda',
        model: 'Civic',
        plate: 'GR-1234',
        seats: 4,
        photoUrl: '',
        rideCategory: RideCategory.standard,
      );
      expect(v.displayName, 'Honda Civic');
      expect(Vehicle.fromJson(v.toJson()).rideCategory, RideCategory.standard);
    });
  });
}
