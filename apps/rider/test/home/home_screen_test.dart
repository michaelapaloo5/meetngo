import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/home/home_screen.dart';
import 'package:meetngo_rider/src/home/widgets/category_chips.dart';
import 'package:meetngo_rider/src/home/widgets/promo_banner.dart';
import 'package:mng_core/mng_core.dart';

Widget wrap({
  String? riderName = 'Alex',
  void Function(BuildContext context)? onSearchTap,
  void Function(BuildContext context)? onNotificationsTap,
}) =>
    ScreenUtilInit(
      designSize: const Size(390, 844),
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (_, _) => MaterialApp(
        theme: MngTheme.light,
        home: HomeScreen(
          riderName: riderName,
          promoCode: 'RIDE30',
          onSearchTap: onSearchTap,
          onNotificationsTap: onNotificationsTap,
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

  // The "Available cars" section and the `kNearbyVehicles` constant behind it
  // are gone: four seeded Toyotas, Nissans and a Mercedes with invented plates
  // that are not rows in `vehicles` and are owned by nobody. These two tests
  // replace the ones that listed them, and they assert the *absence*, which is
  // a stronger claim than the presence they used to make -- a screen can only
  // print a fake plate if the constant comes back.
  testWidgets('no fake nearby-cars section is drawn', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    expect(find.text('Available cars'), findsNothing);
    expect(find.text('See all'), findsNothing);
    expect(find.text('No cars nearby right now'), findsNothing);
    expect(find.text('Toyota Corolla'), findsNothing);
    expect(find.text('Nissan Note'), findsNothing);
    expect(find.text('Mercedes-Benz C-Class'), findsNothing);
    expect(find.text('Hyundai H100'), findsNothing);
    // No seeded plate leaks through the ride picker either, and no car icon
    // is drawn anywhere on the home screen.
    expect(find.text('GR-1234-21'), findsNothing);
    expect(find.text('GR-4417-22'), findsNothing);
    expect(find.text('GR-9021-23'), findsNothing);
    expect(find.text('GR-7788-24'), findsNothing);
    expect(find.byIcon(Icons.directions_car), findsNothing);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('the notification bell is live and reports its tap', (tester) async {
    useDesignSurface(tester);
    var taps = 0;
    await tester.pumpWidget(wrap(onNotificationsTap: (_) => taps++));
    final bell = find.byKey(const Key('notificationsButton'));
    expect(bell, findsOneWidget);
    // Not a bare `Icon`: an `Icon` with no `onPressed` is the dead control this
    // replaces, and `IconButton` is what makes the tap real.
    expect(find.byType(IconButton), findsOneWidget);
    await tester.tap(bell);
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('the greeting names the signed-in rider', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap(riderName: 'Adwoa'));
    expect(find.textContaining('Adwoa'), findsOneWidget);
    expect(find.textContaining('Alex'), findsNothing);
  });

  testWidgets('a blank rider name greets without a trailing comma',
      (tester) async {
    useDesignSurface(tester);
    // `profiles.full_name` is `not null default ''`, so a blank name is a real
    // value and the greeting must not render ", ".
    for (final blank in [null, '', '   ']) {
      await tester.pumpWidget(wrap(riderName: blank));
      final text = tester.widget<Text>(find.byKey(const Key('greeting')));
      expect(text.data, isNot(contains(',')), reason: '"${text.data}"');
      expect(text.data!.startsWith('Good'), isTrue, reason: text.data!);
    }
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

  testWidgets('the home screen has no overflow at 200% text scale',
      (tester) async {
    useDesignSurface(tester);
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(wrap());
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long rider name does not overflow the greeting row',
      (tester) async {
    useDesignSurface(tester);
    // The greeting sits beside the bell, so an unbroken name is the case that
    // would push the bell off a 390-wide row.
    await tester.pumpWidget(
      wrap(riderName: 'Kwabenantenomaa-Boateng-Sarpong'),
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('notificationsButton')), findsOneWidget);
  });
}
