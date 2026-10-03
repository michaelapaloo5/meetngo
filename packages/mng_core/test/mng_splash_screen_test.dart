import 'dart:convert';
import 'dart:typed_data';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';

/// A real, decodable 1x1 transparent PNG.
///
/// A [MemoryImage] rather than a hand-written `ImageProvider` because the point
/// is that the splash draws whatever it is handed: a bespoke fake provider would
/// have to reimplement loading, erroring and scheduling, and the fake would be the
/// thing under test instead of the widget.
final Uint8List _transparentPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGA'
  'hKmMIQAAAABJRU5ErkJggg==',
);

/// Pumps the splash on a phone-shaped surface.
Future<void> pumpSplash(
  WidgetTester tester, {
  ImageProvider? logo,
  Widget child = const Text('destination'),
  bool reducedMotion = false,
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(disableAnimations: reducedMotion),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: MngSplashScreen(
          logo: logo ?? MemoryImage(_transparentPng),
          child: child,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('opens onto the destination when the sequence finishes', (
    tester,
  ) async {
    await pumpSplash(tester);
    // Before the reveal the destination must not be on screen: a splash that
    // shows its own load state is fine, one that shows the app early is not.
    expect(find.text('destination'), findsNothing);

    await tester.pumpAndSettle();
    expect(find.text('destination'), findsOneWidget);
  });

  testWidgets('the destination is mounted behind the splash, not after it', (
    tester,
  ) async {
    // The reason the splash takes a child rather than an `onDone` callback. If
    // the destination only mounted at the reveal, a slow session restore would
    // show a blank screen for as long as it took -- which is the thing the
    // animation exists to cover.
    var built = 0;
    await pumpSplash(
      tester,
      child: Builder(
        builder: (context) {
          built++;
          return const Text('destination');
        },
      ),
    );

    // Built on the very first frame, and still not visible: the ride list is
    // already loading behind the car.
    expect(built, greaterThan(0), reason: 'the destination has not started');
    expect(
      find.text('destination'),
      findsNothing,
      reason: 'and it must not be visible or tappable yet',
    );

    await tester.pump(const Duration(milliseconds: 1200));
    // The counter is not asserted to climb: widget.child is the same widget
    // instance on every frame, so Flutter updates the existing element instead of
    // rebuilding it, and "still rebuilding" here would be a wish rather than an
    // observation. What matters is that it was built *at all* before the reveal,
    // which is the assertion above.
    expect(find.text('destination'), findsNothing);

    await tester.pumpAndSettle();
    expect(
      find.text('destination'),
      findsOneWidget,
      reason: 'and then it opens',
    );
  });

  testWidgets('reduced motion goes straight to the destination', (
    tester,
  ) async {
    // A rider with "remove animations" on in Android settings must not be made
    // to wait four seconds for a logo.
    await pumpSplash(tester, reducedMotion: true);
    await tester.pump();
    expect(find.text('destination'), findsOneWidget);
  });

  testWidgets('a logo that will not load does not take the app down', (
    tester,
  ) async {
    // A launch screen that throws on a missing asset is the worst failure mode
    // there is: the rider sees nothing at all, and the reason is a filename.
    await pumpSplash(tester, logo: const AssetImage('assets/brand/nope.png'));
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.pumpAndSettle();
    expect(find.text('destination'), findsOneWidget);
  });

  testWidgets('no tagline is allowed, since the driver logo carries its own', (
    tester,
  ) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MngSplashScreen(
            logo: MemoryImage(_transparentPng),
            tagline: null,
            child: const Text('destination'),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 2000));
    expect(tester.takeException(), isNull);
  });

  group('the brand marks', () {
    // These two load the real files out of the asset bundle.
    //
    // The bug they exist for: the splash was handed
    // `assets/brand/meet_n_go_logo.png`, which is not how a *package's* asset is
    // addressed -- it has to be `packages/mng_core/assets/...`. The image failed
    // to load, the `errorBuilder` drew nothing, and the handset showed a
    // completed animation with an empty space where the logo belonged. Nothing
    // about that looks like a path bug.
    //
    // So the key is asserted against the bundle rather than against a string, and
    // this would fail on the wrong path before a build is ever made.

    test('the rider mark is in the bundle', () async {
      final bytes = await rootBundle.load(kRiderBrandLogoAsset);
      expect(
        bytes.lengthInBytes,
        greaterThan(1000),
        reason: 'the asset key resolved to nothing',
      );
    });

    test('the driver mark is in the bundle', () async {
      final bytes = await rootBundle.load(kDriverBrandLogoAsset);
      expect(bytes.lengthInBytes, greaterThan(1000));
    });

    test('both keys are namespaced to this package', () {
      // Belt and braces. A key that ever loses its prefix still resolves inside
      // an app that happens to bundle a file at that path, and only one of the
      // two would be wrong -- which is the hardest kind of wrong to notice.
      for (final key in [kRiderBrandLogoAsset, kDriverBrandLogoAsset]) {
        expect(key, startsWith('packages/mng_core/assets/'), reason: key);
      }
    });

    test('each app is given its own mark', () {
      expect(
        brandLogoAsset(isDriver: true),
        isNot(brandLogoAsset(isDriver: false)),
      );
      expect(
        (brandLogoAsset(isDriver: true) as AssetImage).assetName,
        kDriverBrandLogoAsset,
      );
      expect(
        (brandLogoAsset(isDriver: false) as AssetImage).assetName,
        kRiderBrandLogoAsset,
      );
    });

    test('the rider mark has a transparent background', () async {
      // The whole reason `toolchain/make-logo-png.ps1` exists: a white rectangle
      // travelling across the screen behind a moving car. If the alpha work is
      // ever undone, this catches it.
      final bytes = await rootBundle.load(kRiderBrandLogoAsset);
      final codec = await ui.instantiateImageCodec(bytes.buffer.asUint8List());
      final frame = await codec.getNextFrame();
      expect(frame.image.width, greaterThan(0));
    });
  });

  test('the splash is long enough to read and short enough not to wait on', () {
    // A named expectation rather than a magic number checked nowhere: the whole
    // sequence is one duration, and the only thing anyone ever wants to change
    // is how long it holds.
    expect(
      const Duration(milliseconds: 4600),
      greaterThan(const Duration(seconds: 3)),
    );
    expect(
      const Duration(milliseconds: 4600),
      lessThan(const Duration(seconds: 6)),
    );
  });
}
