import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/data/booked_trip.dart';
import 'package:meetngo_rider/src/data/location_service.dart';
import 'package:meetngo_rider/src/data/place_service.dart';
import 'package:meetngo_rider/src/home/home_screen.dart';
import 'package:meetngo_rider/src/home/widgets/promo_banner.dart';
import 'package:mng_core/mng_core.dart';

Widget wrap({
  String? riderName = 'Alex',
  DeviceLocation? location,
  PlaceName? place,
  List<BookedTrip>? recentRides,
  void Function(BuildContext context, {bool promo})? onSearchTap,
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
          location: location,
          place: place,
          recentRides: recentRides,
          onSearchTap: onSearchTap,
          onNotificationsTap: onNotificationsTap,
        ),
      ),
    );

/// A trip that happened, shaped as `trips` hands it back.
BookedTrip _booked(String id, String from, String to, double fare) =>
    BookedTrip(
      trip: Trip(
        id: id,
        riderId: 'r1',
        driverId: 'd1',
        category: RideCategory.standard,
        state: TripState.completed,
        pickup: TripStop('Pickup', const GeoPoint(5.6037, -0.1870), from),
        dropoff: TripStop('Dropoff', const GeoPoint(5.6200, -0.1870), to),
        distanceKm: 2.0,
        fareGhs: fare,
      ),
      createdAt: DateTime(2026, 9, 27, 9, 5),
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

  // The line under the greeting used to be the constant 'Osu, Accra, Ghana',
  // printed on every launch for every rider, and this test pinned that
  // constant as correct. It is not: that string is the app's default *pickup*,
  // so it named a place the rider was not standing in, and a demo given
  // anywhere but Osu would have shown it as a live reading. It is now the
  // rider's own position, and these three cover every state it can be in.
  testWidgets('the line under the greeting is never a hard-coded place name', (
    tester,
  ) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    // Nothing read yet.
    expect(find.text('Finding your location'), findsOneWidget);
    // The regression this change exists to prevent: a fixed string that reads
    // as a live location to anyone standing anywhere else.
    expect(find.text('Osu, Accra, Ghana'), findsNothing);
    expect(find.textContaining('Osu'), findsNothing);
  });

  testWidgets('a real fix with no place name reads as your location', (
    tester,
  ) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap(
      location: const DeviceLocation(
        LocationOutcome.granted,
        GeoPoint(5.6037, -0.1870),
      ),
    ));
    // Not the coordinate. "5.6037, -0.1870" is true and useless, and it is the
    // one string on this screen that reads like a fault to anyone who does not
    // know what it is. The point is on the map; the line is a place.
    expect(find.text('Your location'), findsOneWidget);
    expect(find.textContaining('5.60'), findsNothing);
    expect(find.textContaining('-0.18'), findsNothing);
  });

  testWidgets('a geocoded place name is preferred over the fallback', (
    tester,
  ) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap(
      location: const DeviceLocation(
        LocationOutcome.granted,
        GeoPoint(5.6037, -0.1870),
      ),
      place: const PlaceName(
        locality: 'Osu',
        country: 'Ghana',
        thoroughfare: 'Oxford Street',
      ),
    ));
    expect(find.text('Oxford Street, Osu, Ghana'), findsOneWidget);
    expect(find.text('Your location'), findsNothing);
  });

  testWidgets('a geocoder that failed falls back to your location', (
    tester,
  ) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap(
      location: const DeviceLocation(
        LocationOutcome.granted,
        GeoPoint(5.6037, -0.1870),
      ),
      place: null,
    ));
    // The fallback is a sentence, not a coordinate. A geocoder that is slow,
    // blocked or simply wrong must not be able to put a number on the screen.
    expect(find.text('Your location'), findsOneWidget);
    expect(find.textContaining('5.60'), findsNothing);
  });

  testWidgets('a refused permission says so instead of naming a place', (
    tester,
  ) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap(
      location: const DeviceLocation(LocationOutcome.denied),
    ));
    expect(
      find.textContaining('not allowed to use your location'),
      findsOneWidget,
    );
    expect(find.text('Osu, Accra, Ghana'), findsNothing);
  });

  testWidgets('shows the where-would-you-go search field', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    expect(find.byKey(const Key('searchField')), findsOneWidget);
  });

  testWidgets('no category chips are on the home screen', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    // The tier is picked once, on the ride page, where the distance and fare
    // that depend on it are on the same screen. Two controls for one decision
    // meant the first one was easy to forget.
    for (final c in RideCategory.values) {
      expect(find.byKey(Key('chip-${c.name}')), findsNothing, reason: c.name);
    }
  });

  testWidgets('the promo is a button and says it can be used', (tester) async {
    useDesignSurface(tester);
    var promoTaps = 0;
    await tester.pumpWidget(
      wrap(onSearchTap: (_, {bool promo = false}) {
        if (promo) promoTaps++;
      }),
    );
    expect(find.byKey(const Key('promoBanner')), findsOneWidget);
    // "Code RIDE30" invited a rider to retype it. Pressing it now takes the
    // offer, so the copy says so.
    expect(find.text('Tap to use RIDE30'), findsOneWidget);
    expect(find.text('Code RIDE30'), findsNothing);

    await tester.tap(find.byKey(const Key('promoBanner')));
    await tester.pump();
    expect(promoTaps, 1, reason: 'the offer has to actually do something');
  });

  testWidgets('pressing the search field is not the promo', (tester) async {
    useDesignSurface(tester);
    bool sawPromo = true;
    await tester.pumpWidget(
      wrap(onSearchTap: (_, {bool promo = false}) => sawPromo = promo),
    );
    await tester.tap(find.byKey(const Key('searchField')));
    await tester.pump();
    // The two open the same page but mean different things, and the sheet
    // needs to know which -- otherwise the 30% would be applied to every
    // booking.
    expect(sawPromo, isFalse);
  });

  testWidgets('no invented car, plate or fake list is drawn', (tester) async {
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
      'Available cars',
      'No cars nearby right now',
    ]) {
      expect(find.text(ghost), findsNothing, reason: ghost);
    }
  });

  testWidgets('recent rides are listed, and only real ones', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap(recentRides: [
      _booked('t1', 'Osu, Accra', 'Airport Residential, Accra', 12.5),
      _booked('t2', 'Labone', 'Spintex', 8.0),
    ]));
    expect(find.byKey(const Key('recentRides')), findsOneWidget);
    expect(find.textContaining('Osu, Accra'), findsOneWidget);
    expect(find.textContaining('GHS 12.50'), findsOneWidget);
  });

  testWidgets('no recent-rides heading for a rider who has never booked', (
    tester,
  ) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap(recentRides: const []));
    // A heading over an empty list is a promise the app has not kept.
    expect(find.byKey(const Key('recentRides')), findsNothing);
    expect(find.text('Recent rides'), findsNothing);
  });

  testWidgets('recent rides are capped at five', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap(recentRides: [
      for (var i = 1; i <= 9; i++) _booked('t$i', 'From $i', 'To $i', 5.0),
    ]));
    expect(find.byKey(const Key('recentRides')), findsOneWidget);
    for (var i = 1; i <= 5; i++) {
      expect(find.byKey(Key('recentRide-t$i')), findsOneWidget, reason: 't$i');
    }
    expect(find.byKey(const Key('recentRide-t6')), findsNothing);
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
    await tester.pumpWidget(wrap(onSearchTap: (_, {bool promo = false}) => taps++));
    await tester.tap(find.byKey(const Key('searchField')));
    expect(taps, 1);
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
