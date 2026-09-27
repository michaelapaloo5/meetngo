import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/booking/route_entry_sheet.dart';
import 'package:mng_core/mng_core.dart';

Widget wrap({void Function(RouteDraft draft)? onSubmit}) => ScreenUtilInit(
      designSize: const Size(390, 844),
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (_, _) => MaterialApp(
        theme: MngTheme.light,
        home: Scaffold(
          body: RouteEntrySheet(calc: FareCalculator(), onSubmit: onSubmit ?? (_) {}),
        ),
      ),
    );

Widget openHarness({void Function(RouteDraft draft)? onSubmit}) => ScreenUtilInit(
      designSize: const Size(390, 844),
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (_, _) => MaterialApp(
        theme: MngTheme.light,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showRouteEntrySheet(
                  context,
                  calc: FareCalculator(),
                  onSubmit: onSubmit ?? (_) {},
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

void useDesignSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('shows the pickup and the dropoff, not the distance twice',
      (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    expect(find.text('Osu, Accra'), findsOneWidget);
    expect(find.text('Airport Residential, Accra'), findsOneWidget);
  });

  testWidgets('summarises the measured distance, drive time and fare',
      (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    // Haversine over the two Accra constants, R = 6371.0088: 2.3299 km.
    // (5.00 + 1.80 * 2.3299) * 1.0 + 1.00 = 10.1938 -> GHS 10.19.
    expect(find.text('2.3 km  ·  ~6 min drive'), findsOneWidget);
    expect(find.text('GHS 10.19'), findsOneWidget);
  });

  testWidgets('changing the category requotes the fare', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    await tester.tap(find.byKey(const Key('chip-van')));
    await tester.pump();
    // (5.00 + 2.20 * 2.3299) * 1.0 + 1.00 = 11.1258 -> GHS 11.13.
    expect(find.text('GHS 11.13'), findsOneWidget);
  });

  testWidgets('confirm submits the draft with the chosen stops', (tester) async {
    useDesignSurface(tester);
    RouteDraft? draft;
    await tester.pumpWidget(wrap(onSubmit: (d) => draft = d));
    await tester.tap(find.byKey(const Key('chip-van')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('confirmRouteButton')));
    await tester.pump();
    expect(draft, isNotNull);
    expect(draft!.pickup.address, kDefaultPickup.address);
    expect(draft!.pickup.point, kDefaultPickup.point);
    expect(draft!.dropoff.address, kDefaultDropoff.address);
    expect(draft!.category, RideCategory.van);
  });

  testWidgets('the sheet keeps its button clear of the bottom inset',
      (tester) async {
    useDesignSurface(tester);
    tester.view.padding = const FakeViewPadding(bottom: 102);
    await tester.pumpWidget(openHarness());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final button =
        tester.getBottomRight(find.byKey(const Key('confirmRouteButton')));
    expect(button.dy, lessThanOrEqualTo(844 - 34));
  });

  testWidgets('showRouteEntrySheet opens the sheet and submits its draft',
      (tester) async {
    useDesignSurface(tester);
    RouteDraft? draft;
    await tester.pumpWidget(openHarness(onSubmit: (d) => draft = d));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('confirmRouteButton')), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirmRouteButton')));
    await tester.pumpAndSettle();
    expect(draft, isNotNull);
    expect(draft!.pickup.address, kDefaultPickup.address);
    expect(draft!.dropoff.address, kDefaultDropoff.address);
  });

  testWidgets('the route sheet has no overflow at 200% text scale',
      (tester) async {
    useDesignSurface(tester);
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(wrap());
    expect(tester.takeException(), isNull);
  });
}
