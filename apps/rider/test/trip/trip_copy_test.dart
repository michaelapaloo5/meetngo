import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/trip/trip_copy.dart';
import 'package:mng_core/mng_core.dart';

/// A coordinate is not an address.
///
/// Found on a device, not reasoned about: four of five recent rides on the
/// home screen read "5.5879, -0.2204 to Airport Residential, Accra", written by
/// the build before the pickup label stopped being a coordinate. Those rows are
/// real and stay in the database, so the app has to refuse to print one rather
/// than rely on there being no such rows.
void main() {
  TripStop stop(String label, String address) =>
      TripStop(label, const GeoPoint(5.6037, -0.1870), address);

  group('recognising a coordinate pair', () {
    test('it matches the shape the old build wrote', () {
      expect(looksLikeCoordinates('5.5879, -0.2204'), isTrue);
      expect(looksLikeCoordinates('5.6037,-0.1870'), isTrue);
      expect(looksLikeCoordinates('  5.6037 , -0.1870  '), isTrue,
          reason: 'whitespace around the pair is still a pair');
      expect(looksLikeCoordinates('-33.8688'), isFalse,
          reason: 'one number is not a pair');
    });

    test('it matches whole numbers too', () {
      expect(looksLikeCoordinates('6, -1'), isTrue);
    });

    test('it does not match a real place with a comma in it', () {
      // The test that decides whether this rule is safe to have at all. A
      // house number or a shop name that happens to contain a comma and two
      // numbers must survive; replacing those with "Pickup" would be worse
      // than the coordinate problem ever was.
      expect(looksLikeCoordinates('Spintex, Addogonnо, Nungua'), isFalse);
      expect(looksLikeCoordinates('House 12, Oxford Street'), isFalse);
      expect(looksLikeCoordinates('Airport Residential, Accra'), isFalse);
      expect(looksLikeCoordinates('Shop 4, Block 7, Cantonments'), isFalse);
    });

    test('it does not match an address that only starts with a number', () {
      expect(looksLikeCoordinates('5 Airport Residential, Accra'), isFalse);
    });
  });

  group('a coordinate is never shown as an address', () {
    test('a coordinate pickup falls back to the label', () {
      expect(
        stopLabel(stop('Pickup', '5.5879, -0.2204')),
        'Pickup',
      );
    });

    test('a real address is shown as itself', () {
      expect(
        stopLabel(stop('Pickup', 'Obibini Street, Avenor, Ghana')),
        'Obibini Street, Avenor, Ghana',
      );
    });

    test('an empty address still falls back', () {
      expect(stopLabel(stop('Pickup', '   ')), 'Pickup');
    });

    test('a label with nothing in it gets a generic one', () {
      expect(stopLabel(stop('', '5.5879, -0.2204')), 'Pickup or drop-off');
    });
  });

  group('addressForDisplay, the copy the history list uses', () {
    test('a real address passes through', () {
      expect(
        addressForDisplay('Obibini Street, Avenor, Ghana', 'Pickup'),
        'Obibini Street, Avenor, Ghana',
      );
    });

    test('a coordinate is replaced by the fallback', () {
      expect(addressForDisplay('5.5879, -0.2204', 'Pickup'), 'Pickup');
    });

    test('an empty address is replaced by the fallback', () {
      expect(addressForDisplay('   ', 'Pickup'), 'Pickup');
    });

    test('a place with a comma and numbers in it is not mistaken for one', () {
      expect(
        addressForDisplay('Shop 4, Block 7, Cantonments', 'Pickup'),
        'Shop 4, Block 7, Cantonments',
      );
    });
  });

  group('other copy the rider reads', () {
    test('money is still formatted the same', () {
      expect(formatGhs(12.5), 'GHS 12.50');
    });
  });
}
