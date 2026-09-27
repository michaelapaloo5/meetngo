import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/home/home_screen.dart';
import 'package:meetngo_rider/src/home/widgets/category_chips.dart';
import 'package:meetngo_rider/src/home/widgets/promo_banner.dart';
import 'package:mng_core/mng_core.dart';

Vehicle vehicle(String id, RideCategory category, int seats) => Vehicle(
      id: id,
      ownerId: 'owner-$id',
      category: VehicleCategory.sedan,
      make: 'Toyota',
      model: 'Corolla',
      plate: 'GR-$id',
      seats: seats,
      photoUrl: '',
      rideCategory: category,
    );

Widget wrap({
  List<Vehicle> nearby = const [],
  void Function(BuildContext context)? onSearchTap,
}) =>
    ScreenUtilInit(
      designSize: const Size(390, 844),
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (_, _) => MaterialApp(
        theme: MngTheme.light,
        home: HomeScreen(
          nearby: nearby,
          promoCode: 'RIDE30',
          onSearchTap: onSearchTap,
        ),
      ),
    );

void useDesignSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('greets the rider by time of day', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    expect(find.textContaining('Good'), findsOneWidget);
  });

  testWidgets('shows the Accra locality line', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    expect(find.text('Osu, Accra, Ghana'), findsOneWidget);
  });

  testWidgets('shows the where-would-you-go search field', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    expect(find.byKey(const Key('searchField')), findsOneWidget);
  });

  testWidgets('renders the three launch categories and no moto', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    expect(find.byKey(const Key('chip-standard')), findsOneWidget);
    expect(find.byKey(const Key('chip-premium')), findsOneWidget);
    expect(find.byKey(const Key('chip-van')), findsOneWidget);
    expect(find.text('Moto'), findsNothing);
    final unselected = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('chip-van')),
        matching: find.text('Van'),
      ),
    );
    // `textSub` on `muted` measures 3.16:1, under the 4.5:1 WCAG AA minimum
    // for text this size. The tokens are Task 1's, so this pins the value.
    expect(unselected.style!.color, MngColors.textSub);
  });

  testWidgets('tapping a category chip moves the selection', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    await tester.tap(find.byKey(const Key('chip-van')));
    await tester.pump();
    final chips = tester.widget<CategoryChips>(find.byType(CategoryChips));
    expect(chips.selected, RideCategory.van);
  });

  testWidgets('promo banner shows the discount and code', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    expect(find.text('30% off your first ride'), findsOneWidget);
    expect(find.text('Code RIDE30'), findsOneWidget);
  });

  testWidgets('empty nearby list shows a friendly empty state', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    expect(find.text('No cars nearby right now'), findsOneWidget);
  });

  testWidgets('nearby cars are listed with category and seats', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(
      wrap(nearby: [vehicle('v1', RideCategory.standard, 4)]),
    );
    expect(find.text('Toyota Corolla'), findsOneWidget);
    expect(find.text('Standard · 4 seats'), findsOneWidget);
    final avatar = tester.widget<Icon>(
      find.descendant(
        of: find.byType(CircleAvatar),
        matching: find.byIcon(Icons.directions_car),
      ),
    );
    expect(avatar.color, MngColors.onPrimary);
  });

  testWidgets('promo banner paints the 20px radius on the dark surface',
      (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    final banner = find.byType(PromoBanner);
    expect(tester.widget<PromoBanner>(banner).code, 'RIDE30');
    final box = tester.widget<Container>(
      find.descendant(of: banner, matching: find.byType(Container)).first,
    );
    final decoration = box.decoration! as BoxDecoration;
    expect(decoration.color, MngColors.textPrimary);
    expect(decoration.borderRadius, BorderRadius.circular(MngRadius.large));
  });

  testWidgets('tapping the search field reports the tap', (tester) async {
    useDesignSurface(tester);
    var taps = 0;
    await tester.pumpWidget(wrap(onSearchTap: (_) => taps++));
    await tester.tap(find.byKey(const Key('searchField')));
    expect(taps, 1);
  });

  testWidgets('a selected Premium chip is legible against its own colour',
      (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    await tester.tap(find.byKey(const Key('chip-premium')));
    await tester.pump();
    final chip = find.byKey(const Key('chip-premium'));
    final icon = tester.widget<Icon>(
      find.descendant(of: chip, matching: find.byIcon(Icons.auto_awesome)),
    );
    final label = tester.widget<Text>(
      find.descendant(of: chip, matching: find.text('Premium')),
    );
    expect(icon.color, MngColors.page);
    expect(label.style!.color, MngColors.page);
  });

  testWidgets('a selected Van chip is legible against its own colour',
      (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    await tester.tap(find.byKey(const Key('chip-van')));
    await tester.pump();
    final chip = find.byKey(const Key('chip-van'));
    final icon = tester.widget<Icon>(
      find.descendant(of: chip, matching: find.byIcon(Icons.airport_shuttle)),
    );
    final label = tester.widget<Text>(
      find.descendant(of: chip, matching: find.text('Van')),
    );
    expect(icon.color, MngColors.onPrimary);
    expect(label.style!.color, MngColors.onPrimary);
  });

  testWidgets('a Van nearby avatar is legible against its own colour',
      (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap(nearby: [vehicle('v1', RideCategory.van, 7)]));
    final icon = tester.widget<Icon>(
      find.descendant(
        of: find.byType(CircleAvatar),
        matching: find.byIcon(Icons.directions_car),
      ),
    );
    expect(icon.color, MngColors.onPrimary);
  });

  testWidgets('a Premium nearby avatar is legible against its own colour',
      (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(
      wrap(nearby: [vehicle('v1', RideCategory.premium, 4)]),
    );
    final icon = tester.widget<Icon>(
      find.descendant(
        of: find.byType(CircleAvatar),
        matching: find.byIcon(Icons.directions_car),
      ),
    );
    expect(icon.color, MngColors.page);
  });

  testWidgets('the home screen has no overflow at 200% text scale',
      (tester) async {
    useDesignSurface(tester);
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(wrap(
      nearby: [vehicle('v1', RideCategory.van, 7)],
    ));
    expect(tester.takeException(), isNull);
  });
}
