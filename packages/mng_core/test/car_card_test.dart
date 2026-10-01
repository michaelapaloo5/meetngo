import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';

/// The car card: a car, a name, a plate.
///
/// Two things are being pinned here, and neither is the layout.
///
/// One is that the paint follows the tier. A card whose car is the same colour
/// for every category has failed at the only job the colour has, and it fails
/// silently: nothing about the card looks broken.
///
/// The other is that a missing vehicle says so. A driver who has not saved a
/// vehicle has not done anything wrong, so the card has to read as an absence
/// rather than as a failure -- and "blank" is how a bug looks too, which is why
/// the absence is given words.

void main() {
  Widget wrap({
    String make = 'Toyota',
    String model = 'Corolla',
    String plate = 'GR-1234-25',
    RideCategory tier = RideCategory.standard,
    String? category,
  }) => MaterialApp(
    home: Scaffold(
      body: CarCard(
        make: make,
        model: model,
        plate: plate,
        tier: tier,
        category: category,
      ),
    ),
  );

  group('it says what the car is', () {
    testWidgets('the name joins make and model', (tester) async {
      await tester.pumpWidget(wrap());
      expect(
        tester.widget<Text>(find.byKey(const Key('carCardName'))).data,
        'Toyota Corolla',
      );
    });

    testWidgets('the plate is upper-cased and letterspaced', (tester) async {
      await tester.pumpWidget(wrap(plate: 'gr-1234-25'));
      final text = tester.widget<Text>(find.byKey(const Key('carCardPlate')));
      // Read aloud at a pick-up point, so it is the one string that has to be
      // exactly right. `gh-` typed by a driver is not what is painted on the car.
      expect(text.data, 'GR-1234-25');
      expect(text.style!.letterSpacing, greaterThan(0));
      expect(text.style!.fontWeight, FontWeight.w700);
    });

    testWidgets('a body style is shown when there is one', (tester) async {
      await tester.pumpWidget(wrap(category: 'SUV'));
      expect(tester.widget<Text>(find.byKey(const Key('carCardTier'))).data, 'SUV');
    });

    testWidgets('the tier is shown when there is no body style', (tester) async {
      // Not an empty line. A blank subtitle is indistinguishable from a field
      // nobody filled in, and the tier is the thing a rider needs.
      await tester.pumpWidget(wrap(tier: RideCategory.premium));
      expect(
        tester.widget<Text>(find.byKey(const Key('carCardTier'))).data,
        'Premium',
      );
    });
  });

  group('a driver with no vehicle yet', () {
    testWidgets('the name says so rather than being blank', (tester) async {
      await tester.pumpWidget(wrap(make: '', model: ''));
      final name = tester.widget<Text>(find.byKey(const Key('carCardName'))).data!;
      expect(name, 'No vehicle added yet');
      // And specifically not whitespace, which is what a naive
      // `'$make $model'.trim()` gives and which renders as nothing at all.
      expect(name.trim(), isNotEmpty);
    });

    testWidgets('the plate says so rather than being blank', (tester) async {
      await tester.pumpWidget(wrap(plate: '   '));
      expect(
        tester.widget<Text>(find.byKey(const Key('carCardPlate'))).data,
        'No number plate yet',
      );
    });

    testWidgets('one of make or model on its own is still a name', (tester) async {
      await tester.pumpWidget(wrap(make: 'Toyota', model: ''));
      expect(
        tester.widget<Text>(find.byKey(const Key('carCardName'))).data,
        'Toyota',
      );
    });

    testWidgets('the card still renders, because the car is the point', (tester) async {
      await tester.pumpWidget(wrap(make: '', model: '', plate: ''));
      expect(tester.takeException(), isNull);
      expect(find.byType(CustomPaint), findsWidgets);
    });
  });

  group('the paint follows the tier', () {
    /// Every colour actually painted, counted.
    ///
    /// Read out of a rendered image rather than out of the widget, because the
    /// claim under test is that the *car* is the tier's colour. Asserting on
    /// `CarCard.tier` would only prove the card was constructed with a tier --
    /// a painter that ignored its argument would pass that test.
    ///
    /// A set of counts rather than a hash: when it fails it says *which* colours
    /// were painted, so the message is the diagnosis.
    Future<Map<int, int>> paintFor(WidgetTester tester, RideCategory tier) async {
      final picture = (await tester.runAsync(() {
        final recorder = ui.PictureRecorder();
        const size = Size(108, 72);
        CarPainter(body: tier.color).paint(Canvas(recorder), size);
        return recorder.endRecording().toImage(108, 72);
      }))!;

      final bytes = await tester.runAsync(
        () => picture.toByteData(format: ui.ImageByteFormat.rawRgba),
      );
      final data = bytes!.buffer.asUint8List();
      final counts = <int, int>{};
      for (var i = 0; i < data.length; i += 4) {
        // Fully transparent pixels are the background, not paint. Counting them
        // would make every tier look the same, since they all share one.
        if (data[i + 3] == 0) continue;
        // Packed as standard ARGB so that `_sameColour` and `_hex` below read the
        // same bytes back. An earlier version packed r into the top byte and
        // unpacked it from bits 16-23, which made a green car report as a purple
        // one and sent the diagnosis in the wrong direction entirely.
        final pixel = (data[i + 3] << 24) | (data[i] << 16) | (data[i + 1] << 8) | data[i + 2];
        counts[pixel] = (counts[pixel] ?? 0) + 1;
      }
      return counts;
    }

    testWidgets('the body is painted in the tier colour', (tester) async {
      for (final tier in RideCategory.values) {
        final painted = (await paintFor(tester, tier)).keys.toSet();
        // The assertion that would fail if the painter ignored `body`. Read with a
        // small tolerance because anti-aliasing blends the edges; the flat middle
        // of the flank is the nominal value, but tolerance costs nothing and does
        // not depend on which part of the car a given rasteriser happened to hit.
        expect(
          painted.any((c) => _sameColour(c, tier.color)),
          isTrue,
          reason: '${tier.name} painted ${painted.map(_hex).join(' ')}, '
              'which does not include ${_hex(tier.color.toARGB32())}',
        );
      }
    });

    testWidgets('each tier paints a visibly different car', (tester) async {
      final painted = <RideCategory, Set<int>>{};
      for (final tier in RideCategory.values) {
        painted[tier] = (await paintFor(tester, tier)).keys.toSet();
      }
      expect(
        painted[ RideCategory.lite ]!.difference(painted[ RideCategory.premium ]!).isNotEmpty,
        isTrue,
        reason: 'lite and premium share every colour, so the tier is invisible',
      );
      expect(
        painted[ RideCategory.lite ]!.difference(painted[ RideCategory.standard ]!).isNotEmpty,
        isTrue,
        reason: 'lite and standard share every colour, so the tier is invisible',
      );
      expect(
        painted[ RideCategory.standard ]!.difference(painted[ RideCategory.premium ]!).isNotEmpty,
        isTrue,
        reason: 'standard and premium share every colour, so the tier is invisible',
      );
    });
  });
}

/// Close enough to call the same colour.
///
/// Anti-aliasing means the flank is never painted at its exact nominal value: the
/// edge pixels are blends towards the background. So this compares with a small
/// per-channel tolerance rather than for equality, and says so.
bool _sameColour(int argb, Color c) {
  final r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF;
  return (r - c.r * 255).abs() <= 6 &&
      (g - c.g * 255).abs() <= 6 &&
      (b - c.b * 255).abs() <= 6;
}

String _hex(int argb) =>
    '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';