import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';
import 'package:meetngo_driver/src/auth/driver_auth_controller.dart';
import 'package:meetngo_driver/src/data/driver_auth_repository.dart';
import 'package:meetngo_driver/src/profile/driver_profile_screen.dart';
import 'package:provider/provider.dart';

import '../support/fakes.dart';
import '../support/harness.dart';

/// The vehicle block on the Profile tab.
///
/// This block had no test of its own. The Profile tab was exercised only by the
/// wiring test, which checks that opening it reads the driver's own row -- a
/// screen that renders nothing at all passes that. So this file exists because
/// the block changed, not because it was important.
///
/// What changed: a two-line grey summary became a [CarCard]. The summary said
/// what the driver had typed and showed them nothing, which is the wrong job for
/// the last screen a rider sees before getting in.

void main() {
  DriverProfile jane({String? vehicleId}) => DriverProfile(
    id: 'd1',
    fullName: 'Jane Cooper',
    phone: '0241234567',
    rating: 4.8,
    tripCount: 40,
    kyc: KycStatus.approved,
    availability: DriverAvailability.offline,
    vehicleId: vehicleId,
  );

  Widget wrap({Vehicle? vehicle, String? vehicleId}) => appHarness(
    MultiProvider(
      providers: [
        Provider<DriverAuthRepository>.value(value: StubDriverAuthRepository()),
        ChangeNotifierProvider<DriverAuthController>(
          create: (_) => DriverAuthController(StubDriverAuthRepository()),
        ),
      ],
      child: DriverProfileScreen(
        profile: jane(vehicleId: vehicleId ?? vehicle?.id),
        email: 'jane@example.test',
        vehicle: vehicle,
        onSignOut: () async {},
      ),
    ),
  );

  group('a driver with a vehicle', () {
    testWidgets('sees the car, its name and its plate', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(
        wrap(
          vehicle: driverVehicle(
            make: 'Toyota',
            model: 'Corolla',
            plate: 'GR-1234-25',
          ),
        ),
      );

      expect(find.byType(CarCard), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('carCardName'))).data,
        'Toyota Corolla',
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('carCardPlate'))).data,
        'GR-1234-25',
      );
    });

    testWidgets('sees the seats and the tier, which the card does not carry', (
      tester,
    ) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(vehicle: driverVehicle(seats: 4)));

      // Deliberately kept off the card: `4 seats` is information a driver needs
      // and a rider cannot see from outside the car, so it has to be on screen
      // somewhere.
      final detail = tester
          .widget<Text>(find.byKey(const Key('profileVehicleDetail')))
          .data!;
      expect(detail, contains('4 seats'));
    });

    testWidgets('the car is painted in that vehicle own tier colour', (
      tester,
    ) async {
      useDesignSurface(tester);
      await tester.pumpWidget(
        wrap(vehicle: driverVehicle(rideCategory: RideCategory.premium)),
      );

      // The paint, not the text. A premium car and a lite car differing only in a
      // line of small text is a tier nobody can pick out of a car park.
      final painters = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<CarPainter>();
      expect(painters, isNotEmpty);
      expect(painters.first.body, RideCategory.premium.color);
    });
  });

  group('a driver with no vehicle', () {
    testWidgets('is told so, in words, and gets no card', (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(vehicle: null));

      expect(find.byKey(const Key('profileNoVehicle')), findsOneWidget);
      // No card. An empty card beside a sentence that says "No vehicle added yet"
      // is the sentence said twice, one of them as a gap.
      expect(find.byType(CarCard), findsNothing);
    });

    testWidgets('a vehicle id with no readable row says so', (tester) async {
      useDesignSurface(tester);
      // `vehicles` is referenced `on delete set null`, so this is a state the
      // database should not hold. The honest rendering is a sentence rather than
      // an empty panel, and that is worth pinning because the reference is the
      // only thing preventing it.
      await tester.pumpWidget(wrap(vehicle: null, vehicleId: 'v-gone'));

      expect(find.byKey(const Key('profileVehicleUnreadable')), findsOneWidget);
    });
  });
}
