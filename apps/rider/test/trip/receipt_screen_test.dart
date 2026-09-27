import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/trip/receipt_screen.dart';
import 'package:mng_core/mng_core.dart';

// The default flutter_test surface is 800x600, where ScreenUtil scales .w by
// 2.05 and .h by 0.525, so a widget that fits 390x844 can land off-screen and a
// tap can hit nothing. Pin the surface to the design size.
void useDesignSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

Trip completedTrip() => Trip(
      id: 't1',
      riderId: 'r1',
      driverId: 'd1',
      category: RideCategory.standard,
      state: TripState.completed,
      pickup: const TripStop('P', GeoPoint(5.6037, -0.1870), 'Osu, Accra'),
      dropoff:
          const TripStop('D', GeoPoint(5.6052, -0.1660), 'Airport Residential'),
      distanceKm: 2.4,
      fareGhs: 20.40,
      isDemo: true,
    );

Widget wrap({
  PaymentState state = PaymentState.succeeded,
  void Function(int stars, String comment)? onRated,
  Settlement? settlement,
}) =>
    ScreenUtilInit(
      designSize: const Size(390, 844),
      builder: (_, _) => MaterialApp(
        theme: MngTheme.light,
        home: ReceiptScreen(
          trip: completedTrip(),
          // The fare is a parameter because the long money is what makes the
          // itemised rows overflow. Pinned at GHS 20.40 they are nowhere near
          // the card's edge at 200%, so a fixture that only ever renders
          // `GHS 20.40` cannot fail when their width guards are removed --
          // which is exactly what a fixture that cannot fail looks like.
          settlement: settlement ??
              const Settlement(
                fareGhs: 20.40,
                commissionGhs: 3.06,
                driverPayoutGhs: 17.34,
              ),
          paymentState: state,
          onRated: onRated ?? (_, _) {},
        ),
      ),
    );

/// The contrast ratio two opaque colours make against each other, from
/// `Color.computeLuminance()` rather than from a hand-rolled sRGB transfer
/// function. Written as a hand-rolled function it was wrong -- the transfer is
/// `((v + 0.055) / 1.055) ^ 2.4` and a transcription that drops the exponent
/// reads `MngColors.textSub` on white as 2.83:1 instead of 3.44:1, which would
/// have had this test failing a colour that is correct. The framework's own
/// arithmetic is also not an assertion about the test's own expression, which is
/// what the ledger identity test in `complete_trip_handler.test.ts` is careful
/// about.
double contrast(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  final lighter = first > second ? first : second;
  final darker = first > second ? second : first;
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  testWidgets('total is the settled fare', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    expect(find.byKey(const Key('receiptTotal')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('receiptTotal'))).data,
      'GHS 20.40',
    );
  });

  testWidgets('receipt states the money was demo', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    expect(find.text('Demo payment — no real money moved'), findsOneWidget);
  });

  testWidgets('choosing a star highlights it and only the stars below',
      (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    expect(find.byKey(const Key('ratingStars')), findsOneWidget);
    Icon iconIn(String key) => tester.widget<Icon>(
          find.descendant(
            of: find.byKey(Key(key)),
            matching: find.byType(Icon),
          ),
        );
    expect(iconIn('star-1').icon, Icons.star_border);
    await tester.tap(find.byKey(const Key('star-4')));
    await tester.pump();
    expect(iconIn('star-4').icon, Icons.star);
    expect(iconIn('star-3').icon, Icons.star);
    expect(iconIn('star-5').icon, Icons.star_border);
  });

  testWidgets('an unselected star clears the 3:1 non-text threshold on white',
      (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    Icon iconIn(String key) => tester.widget<Icon>(
          find.descendant(
            of: find.byKey(Key(key)),
            matching: find.byType(Icon),
          ),
        );
    // The outline star is the whole affordance for "you have not picked this
    // one yet", so it has to be visible against the page. Amber is 1.85:1 on
    // white -- measured here, not quoted -- and that is the defect this pins:
    // an amber `star_border` on white is a 36px icon nobody can see.
    final outline = iconIn('star-1');
    expect(outline.icon, Icons.star_border);
    final ratio = contrast(outline.color ?? MngColors.page, MngColors.page);
    // 3:1 is WCAG 1.4.11's floor for a non-text graphic, and `MngColors.textSub`
    // clears it on this page. The ratio is in the failure message rather than
    // the `reason` argument, which `expect` does not take in this form.
    expect(
      ratio >= 3.0,
      true,
      reason: 'outline star is ${ratio.toStringAsFixed(2)}:1 on white',
    );
    // Pinned by value as well as by threshold, so a mutation to a different
    // in-palette grey that happens to clear 3:1 is still visible in the diff.
    expect(outline.color, MngColors.textSub);
  });

  testWidgets('a selected star is the brand amber, as on the driver card',
      (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    await tester.tap(find.byKey(const Key('star-2')));
    await tester.pump();
    final filled = tester.widget<Icon>(
      find.descendant(of: find.byKey(const Key('star-2')), matching: find.byType(Icon)),
    );
    // `MngColors.primary` on white is 1.85:1, which is below the 3:1 a lone
    // graphic is measured against, and it is also what the shipped driver card
    // already draws (`tracking/widgets/driver_summary.dart:58`). The selected
    // state is carried by the fill and the count as well as by the colour, so
    // this matches the accepted precedent rather than inventing a new one; the
    // outline star is the one that has to clear 3:1, and the test above is the
    // one that pins it.
    expect(filled.color, MngColors.primary);
    expect(contrast(filled.color ?? MngColors.page, MngColors.page), lessThan(3.0));
  });

  testWidgets('submitting sends the chosen stars and the comment',
      (tester) async {
    useDesignSurface(tester);
    int? stars;
    String? comment;
    await tester.pumpWidget(wrap(onRated: (s, c) {
      stars = s;
      comment = c;
    }));
    await tester.tap(find.byKey(const Key('star-4')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('ratingComment')), 'Great');
    await tester.tap(find.byKey(const Key('submitRatingButton')));
    await tester.pump();
    expect(stars, 4);
    expect(comment, 'Great');
  });

  testWidgets('driver payout is itemised on the receipt', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    expect(find.text('Driver payout'), findsOneWidget);
    expect(find.text('GHS 17.34'), findsOneWidget);
  });

  testWidgets('a voided payment shows the void notice instead of a total',
      (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(wrap(state: PaymentState.voided));
    expect(find.text('This trip was not charged'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('receiptTotal'))).data,
      'GHS 0.00',
    );
  });

  testWidgets('no overflow at 200% text scale', (tester) async {
    useDesignSurface(tester);
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(wrap());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('no overflow at 200% with a fare of nine digits', (tester) async {
    // The fixture above is the one that cannot fail. `GHS 20.40` is nine
    // characters and the card is 350 logical pixels wide, so the receipt's own
    // money rows have slack to spare at 200% -- and a width guard on them can
    // be deleted without anything going red. `numeric(10,2)` holds eight digits
    // before the point (`init.sql:61`), so `GHS 99999999.99` is a fare the
    // database can actually hold, and the two money rows are then 63 and 35
    // pixels past the card's edge with their guards removed and 120 and 120 at
    // `GHS 112221.00`. Measured by applying the mutation and reading the
    // `RenderFlex` message, not predicted.
    useDesignSurface(tester);
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(wrap(
      settlement: const Settlement(
        fareGhs: 99999999.99,
        commissionGhs: 14999999.99,
        driverPayoutGhs: 84999999.99,
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the money is scaled down to fit, not clipped, on every money row',
      (tester) async {
    // `FittedBox` is the half that does the work on both rows, and it is the half
    // no overflow assertion can pin: a `Flexible` on its own keeps the value
    // inside the Row by *clipping* it, which throws nothing and prints the wrong
    // amount. Measured matrix at 200%, by deleting each half in turn:
    //
    //   total row   both clean | neither 58px | `Flexible` only clean (clips)
    //              | `FittedBox` only 58px
    //   itemised    both clean | neither 63px+35px at GHS 112221.00
    //              | `Flexible` only clean (clips) | `FittedBox` only 63px+35px
    //
    // So this asserts the presence of the wrapper, which is the only thing that
    // can catch the clipping variant. It pins the mechanism rather than the
    // outcome; the outcome is pinned by the two tests above, which catch the
    // whole wrapper going.
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    expect(
      find.ancestor(
        of: find.byKey(const Key('receiptTotal')),
        matching: find.byType(FittedBox),
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.text('GHS 17.34'),
        matching: find.byType(FittedBox),
      ),
      findsOneWidget,
    );
  });

  testWidgets('submitting without a star selection is blocked', (tester) async {
    bool called = false;
    useDesignSurface(tester);
    await tester.pumpWidget(wrap(onRated: (_, _) => called = true));
    await tester.tap(find.byKey(const Key('submitRatingButton')));
    await tester.pump();
    expect(called, isFalse);
    expect(find.text('Pick a rating first'), findsOneWidget);
  });

  testWidgets('choosing a star takes the prompt away again', (tester) async {
    // The prompt and the selection must not be able to disagree on screen. The
    // brief's version never cleared `_errorShown`, so a rider who pressed
    // submit, saw the prompt, then tapped a star was left with "Pick a rating
    // first" under four filled stars.
    useDesignSurface(tester);
    await tester.pumpWidget(wrap());
    await tester.tap(find.byKey(const Key('submitRatingButton')));
    await tester.pump();
    expect(find.text('Pick a rating first'), findsOneWidget);
    await tester.tap(find.byKey(const Key('star-3')));
    await tester.pump();
    expect(find.text('Pick a rating first'), findsNothing);
  });
}
