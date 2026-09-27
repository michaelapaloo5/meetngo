import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/booking/choose_car_screen.dart';
import 'package:mng_core/mng_core.dart';

Vehicle vehicle(String id, RideCategory category, int seats,
        {String model = 'Civic'}) =>
    Vehicle(
      id: id,
      ownerId: 'owner-$id',
      category: VehicleCategory.sedan,
      make: 'Honda',
      model: model,
      plate: 'GR-$id',
      seats: seats,
      photoUrl: '',
      rideCategory: category,
    );

Widget wrap({
  required List<Vehicle> vehicles,
  RideCategory selected = RideCategory.standard,
  void Function(Vehicle)? onConfirm,
  void Function(RideCategory)? onCategory,
}) =>
    ScreenUtilInit(
      designSize: const Size(390, 844),
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (_, _) => MaterialApp(
        theme: MngTheme.light,
        home: ChooseCarScreen(
          vehicles: vehicles,
          selected: selected,
          onCategory: onCategory ?? (_) {},
          calc: FareCalculator(),
          onConfirm: onConfirm ?? (_) {},
        ),
      ),
    );

void useDesignSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('heading matches the reference copy', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap(vehicles: [vehicle('1', RideCategory.standard, 4)]));
    expect(find.text('Choose your car'), findsOneWidget);
  });

  testWidgets('shows the 8 km trip summary line', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap(vehicles: [vehicle('1', RideCategory.standard, 4)]));
    expect(find.text('8.0 km'), findsOneWidget);
  });

  testWidgets('card shows make, seats and GHS price', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap(vehicles: [vehicle('1', RideCategory.standard, 4)]));
    expect(find.text('Honda Civic'), findsOneWidget);
    expect(find.text('4 seats'), findsOneWidget);
    expect(find.text('GHS 20.40'), findsOneWidget);
  });

  testWidgets('tapping a card selects it and reports the vehicle', (tester) async {
    useDesignSurface(tester);
    Vehicle? chosen;
    await tester.pumpWidget(wrap(
      vehicles: [
        vehicle('1', RideCategory.standard, 4),
        vehicle('2', RideCategory.standard, 4),
      ],
      onConfirm: (v) => chosen = v,
    ));
    await tester.tap(find.byKey(const Key('vehicleCard-2')));
    await tester.pump();
    expect(chosen?.id, '2');
  });

  testWidgets('switching category filters the list and notifies the parent',
      (tester) async {
    useDesignSurface(tester);
    RideCategory? reported;
    await tester.pumpWidget(wrap(
      vehicles: [
        vehicle('1', RideCategory.standard, 4),
        vehicle('2', RideCategory.van, 7, model: 'Hiace'),
      ],
      onCategory: (c) => reported = c,
    ));
    await tester.tap(find.byKey(const Key('tab-van')));
    await tester.pump();
    expect(reported, RideCategory.van);
    expect(find.text('Honda Civic'), findsNothing);
    expect(find.text('Honda Hiace'), findsOneWidget);
  });

  testWidgets('a selected tab label is legible on the amber pill',
      (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap(
      vehicles: [vehicle('1', RideCategory.standard, 4)],
    ));
    await tester.tap(find.byKey(const Key('tab-van')));
    await tester.pump();
    final label = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('tab-van')),
        matching: find.text('Van'),
      ),
    );
    expect(label.style!.color, MngColors.onPrimary);
  });

  testWidgets('van fare uses the van per-km rate', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap(
      vehicles: [vehicle('2', RideCategory.van, 7)],
      selected: RideCategory.van,
    ));
    // (5.00 + 2.20 * 8) * 1.0 + 1.00 = 23.60
    expect(find.text('GHS 23.60'), findsOneWidget);
  });

  testWidgets('empty vehicle list disables the find-driver button', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap(vehicles: const []));
    final button =
        tester.widget<FilledButton>(find.byKey(const Key('findDriverButton')));
    expect(button.onPressed, isNull);
  });

  testWidgets('non-empty list enables find-driver', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap(vehicles: [vehicle('1', RideCategory.standard, 4)]));
    final button =
        tester.widget<FilledButton>(find.byKey(const Key('findDriverButton')));
    expect(button.onPressed, isNotNull);
  });

  testWidgets('find-driver confirms the selected vehicle', (tester) async {
    useDesignSurface(tester);
    Vehicle? confirmed;
    await tester.pumpWidget(wrap(
      vehicles: [vehicle('1', RideCategory.standard, 4)],
      onConfirm: (v) => confirmed = v,
    ));
    await tester.tap(find.byKey(const Key('findDriverButton')));
    await tester.pump();
    expect(confirmed?.id, '1');
  });

  testWidgets('a tapped card is marked as the selection', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap(vehicles: [
      vehicle('1', RideCategory.standard, 4),
      vehicle('2', RideCategory.standard, 4),
    ]));
    await tester.tap(find.byKey(const Key('vehicleCard-2')));
    await tester.pump();
    Border borderColorOf(String id) => (tester
            .widget<Container>(
              find
                  .descendant(
                    of: find.byKey(Key('vehicleCard-$id')),
                    matching: find.byType(Container),
                  )
                  .first,
            )
            .decoration! as BoxDecoration)
        .border! as Border;
    expect(borderColorOf('2').top.color, MngColors.primary);
    expect(borderColorOf('1').top.color, MngColors.divider);
  });
}
