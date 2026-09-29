import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/booking/choose_car_screen.dart';
import 'package:mng_core/mng_core.dart';

Widget wrap({
  RideCategory selected = RideCategory.standard,
  void Function(RideCategory c)? onCategory,
  void Function(RideCategory c)? onConfirm,
  double distanceKm = 8.0,
}) =>
    ScreenUtilInit(
      designSize: const Size(390, 844),
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (_, _) => MaterialApp(
        theme: MngTheme.light,
        home: ChooseCarScreen(
          calc: FareCalculator(),
          selected: selected,
          onCategory: onCategory ?? (_) {},
          onConfirm: onConfirm ?? (_) {},
          distanceKm: distanceKm,
        ),
      ),
    );

void useDesignSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('shows the distance and says the fares are estimates', (
    tester,
  ) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    expect(find.text('Choose your ride'), findsOneWidget);
    expect(find.text('8.0 km'), findsOneWidget);
    expect(find.textContaining('estimates'), findsOneWidget);
  });

  // The screen used to be handed four named cars with invented registration
  // plates. Those were not rows in `vehicles` and were owned by nobody, and the
  // rider was picking between them as though they were real. The screen now
  // offers the three launch categories, which is what the server actually
  // matches on.

  testWidgets('offers the three launch categories and no moto', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    for (final c in RideCategory.values) {
      expect(
        find.byKey(Key('rideCard-${c.name}')),
        findsOneWidget,
        reason: c.name,
      );
    }
    expect(find.byKey(const Key('rideCard-moto')), findsNothing);
  });

  testWidgets('no invented car, make, model or plate is drawn', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    for (final ghost in [
      'Toyota Corolla',
      'Nissan Note',
      'Mercedes-Benz C-Class',
      'Hyundai H100',
      'GR-1234-21',
      'GR-4417-22',
      'GR-9021-23',
      'GR-7788-24',
    ]) {
      expect(find.text(ghost), findsNothing, reason: ghost);
    }
  });

  // The sentence that replaces the fake list. A rider is told the car is
  // assigned on match, which is both true and what every real app says.
  testWidgets('says the driver and car are assigned on acceptance', (
    tester,
  ) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    expect(find.textContaining('assigned when a driver'), findsOneWidget);
    expect(find.textContaining('name, car and plate'), findsOneWidget);
  });

  testWidgets('each category shows its own computed fare', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    // 8 km standard: (5.00 + 1.80 * 8) + 1.00 = 20.40
    expect(find.text('GHS 20.40'), findsWidgets);
    // 8 km premium: (5.00 + 2.80 * 8) + 1.00 = 28.40
    expect(find.text('GHS 28.40'), findsOneWidget);
    // 8 km van: (5.00 + 2.20 * 8) + 1.00 = 23.60
    expect(find.text('GHS 23.60'), findsOneWidget);
  });

  testWidgets('seat counts are a property of the category', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    expect(find.text('4 seats'), findsNWidgets(2)); // standard and premium
    expect(find.text('7 seats'), findsOneWidget); // van
  });

  testWidgets('tapping a category selects it and reports the change', (
    tester,
  ) async {
    useDesignSurface(tester);
    RideCategory? reported;
    await tester.pumpWidget(wrap(onCategory: (c) => reported = c));

    await tester.tap(find.byKey(const Key('rideCard-van')));
    await tester.pump();

    expect(reported, RideCategory.van);
  });

  testWidgets('the button quotes the selected category', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    expect(
      find.text('Find driver  GHS 20.40'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('rideCard-van')));
    await tester.pump();

    expect(find.text('Find driver  GHS 23.60'), findsOneWidget);
  });

  testWidgets('the fare is over the real distance, not a constant', (
    tester,
  ) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap(distanceKm: 2.4));
    // (5.00 + 1.80 * 2.4) + 1.00 = 10.32
    expect(find.text('GHS 10.32'), findsWidgets);
    expect(find.text('GHS 20.40'), findsNothing);
  });

  testWidgets('confirm passes the selected category, not a vehicle', (
    tester,
  ) async {
    useDesignSurface(tester);
    RideCategory? confirmed;
    await tester.pumpWidget(wrap(onConfirm: (c) => confirmed = c));

    await tester.tap(find.byKey(const Key('rideCard-van')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('findDriverButton')));
    await tester.pump();

    expect(confirmed, RideCategory.van);
  });

  testWidgets('a selection made upstream is honoured', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap(selected: RideCategory.premium));
    expect(find.text('Find driver  GHS 28.40'), findsOneWidget);
  });

  testWidgets('the selected card is marked and the others are not', (
    tester,
  ) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());

    BorderSide borderOf(String name) {
      // The keyed panel, not "the last Container under the card": the icon is
      // a Container too, and picking by position is how a test ends up
      // asserting on the wrong decoration.
      final box = tester.widget<Container>(
        find.byKey(Key('tierPanel-$name')),
      );
      return (box.decoration! as BoxDecoration).border!.top;
    }

    expect(borderOf('standard').width, 2);
    expect(borderOf('van').width, 1);
  });

  testWidgets('the screen has no overflow at 200% text scale', (tester) async {
    useDesignSurface(tester);
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(wrap());
    expect(tester.takeException(), isNull);
  });
}
