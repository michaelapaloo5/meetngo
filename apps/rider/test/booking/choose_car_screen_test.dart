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
}) => ScreenUtilInit(
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
    // 8 km: there is no base fare and no booking fee, so a fare is the per-km
    // rate times the distance. 0.28 * 8 = 2.24, 0.35 * 8 = 2.80, 0.46 * 8 =
    // 3.68. The old figures here were 20.40 / 23.60 / 28.40, from the model with
    // a GHS 5.00 base and a GHS 1.00 booking fee.
    expect(
      find.text('GHS 64.00'),
      findsWidgets,
    ); // standard, the default selection
    expect(find.text('GHS 80.00'), findsOneWidget); // premium
    expect(find.text('GHS 48.00'), findsOneWidget); // lite
  });

  testWidgets('seat counts are a property of the category', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    expect(find.text('4 seats'), findsNWidgets(2)); // standard and premium
    expect(find.text('7 seats'), findsOneWidget); // lite, the bigger tier
  });

  testWidgets('tapping a category selects it and reports the change', (
    tester,
  ) async {
    useDesignSurface(tester);
    RideCategory? reported;
    await tester.pumpWidget(wrap(onCategory: (c) => reported = c));

    await tester.tap(find.byKey(const Key('rideCard-lite')));
    await tester.pump();

    expect(reported, RideCategory.lite);
  });

  testWidgets('the button quotes the selected category', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    expect(find.text('Find driver  GHS 64.00'), findsOneWidget);

    await tester.tap(find.byKey(const Key('rideCard-lite')));
    await tester.pump();

    // 0.28 * 8 = 2.24, so selecting lite lowers the quote rather than raising it.
    expect(find.text('Find driver  GHS 48.00'), findsOneWidget);
  });

  testWidgets('the fare is over the real distance, not a constant', (
    tester,
  ) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap(distanceKm: 4.0));
    // 8 * 4 = 32.00 for standard, and clear of the 23.00 floor -- which is the
    // point of the distance being read at all. At 2.4 km this would have been the
    // floor, and the assertion would pass against a constant.
    expect(find.text('GHS 32.00'), findsWidgets);
    // The 8 km figure must be gone. This is the test that a distance is read at
    // all, rather than a fare pinned by a constant somewhere in the widget.
    expect(find.text('GHS 64.00'), findsNothing);
  });

  testWidgets('a short ride costs the tier minimum, not the rate', (
    tester,
  ) async {
    useDesignSurface(tester);
    // 2.4 km standard is 19.20 by the rate and 23.00 by the floor, so this pins
    // which of the two won. Under the old 0.35/km scale this was 0.84 and there
    // was no floor anywhere near it.
    await tester.pumpWidget(wrap(distanceKm: 2.4));
    expect(find.text('GHS 23.00'), findsWidgets);
    expect(find.text('GHS 17.00'), findsWidgets); // lite
    expect(find.text('GHS 28.00'), findsWidgets); // premium
  });

  testWidgets('confirm passes the selected category, not a vehicle', (
    tester,
  ) async {
    useDesignSurface(tester);
    RideCategory? confirmed;
    await tester.pumpWidget(wrap(onConfirm: (c) => confirmed = c));

    await tester.tap(find.byKey(const Key('rideCard-lite')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('findDriverButton')));
    await tester.pump();

    expect(confirmed, RideCategory.lite);
  });

  testWidgets('a selection made upstream is honoured', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap(selected: RideCategory.premium));
    // 0.46 * 8 = 3.68, and premium must be the dearer of the two for the
    // "upstream selection is honoured" claim to be distinguishable from the
    // default being shown.
    expect(find.text('Find driver  GHS 80.00'), findsOneWidget);
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
      final box = tester.widget<Container>(find.byKey(Key('tierPanel-$name')));
      return (box.decoration! as BoxDecoration).border!.top;
    }

    expect(borderOf('standard').width, 2);
    expect(borderOf('lite').width, 1);
  });

  testWidgets('the screen has no overflow at 200% text scale', (tester) async {
    useDesignSurface(tester);
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(wrap());
    expect(tester.takeException(), isNull);
  });
}
