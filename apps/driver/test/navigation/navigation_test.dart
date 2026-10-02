import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';
import 'package:meetngo_driver/src/navigation/navigation_controller.dart';
import 'package:meetngo_driver/src/navigation/navigation_host.dart';
import 'package:meetngo_driver/src/navigation/route_progress.dart';
import 'package:meetngo_driver/src/navigation/turn_banner.dart';

import '../support/harness.dart';

/// Navigation: where the driver is on the route, what to tell them, and when to
/// throw the route away and fetch another.
///
/// Almost all of this is pure. That is the design, not an accident: the alternative
/// is testing turn logic through a widget that owns a `MapLibreMapController`,
/// which either needs a platform view or proves nothing. So [progressOn],
/// [shouldReRoute] and the three formatters are plain functions over a route and a
/// position, and the controller takes an injected clock and a speech port so that
/// "stuck for four minutes" and "say this once" are unit tests.

/// A straight north-bound route with four equal legs.
///
/// Realistic enough for every rule here and far easier to reason about than a real
/// OSRM geometry: 0.001 degrees of latitude is about 111 m, so each leg is about
/// 111 m and the whole route is about 444 m.
TripRoute straightRoute({
  double legDegrees = 0.001,
  int legs = 4,
  double stepM = 111,
}) {
  final geometry = <List<double>>[];
  for (var i = 0; i <= legs; i++) {
    geometry.add([-0.1870, 5.6037 + i * legDegrees]);
  }
  return TripRoute(
    distanceM: (legs * stepM).toDouble(),
    durationS: 420,
    durationFreeFlowS: 220,
    geometry: geometry,
    steps: [
      RouteStep(
        instruction: 'Head north on Boundary Road',
        distanceM: stepM,
        maneuver: 'depart',
        name: 'Boundary Road',
      ),
      RouteStep(
        instruction: 'Turn right onto Ring Road West',
        distanceM: stepM,
        maneuver: 'turn',
        name: 'Ring Road West',
      ),
      RouteStep(
        instruction: 'Turn left onto Airport Road',
        distanceM: stepM,
        maneuver: 'turn',
        name: 'Airport Road',
      ),
      RouteStep(
        instruction: 'You have arrived',
        distanceM: stepM,
        maneuver: 'arrive',
        name: '',
      ),
    ],
    engine: 'osrm',
    degraded: false,
  );
}

/// Records what was said, so "says it once" is checkable.
class RecordingSpeech implements SpeechPort {
  final List<String> said = [];
  int stops = 0;

  @override
  Future<void> speak(String text) async => said.add(text);

  @override
  Future<void> stop() async => stops++;
}

class StubRoute implements RouteRepository {
  StubRoute(this.answer);
  TripRoute answer;
  Object? error;
  int calls = 0;
  GeoPoint? lastFrom;

  @override
  Future<TripRoute> route(GeoPoint from, GeoPoint to) async {
    calls++;
    lastFrom = from;
    final e = error;
    if (e != null) throw e;
    return answer;
  }
}

/// Never answers, so a test can drive the poll while a fetch is still open.
///
/// The completers are exposed rather than the futures so a test can decide when the
/// world moves, which is the only way to pin behaviour about overlapping requests.
class HangingRoute implements RouteRepository {
  final List<GeoPoint> asked = [];
  final List<Completer<TripRoute>> pending = [];

  @override
  Future<TripRoute> route(GeoPoint from, GeoPoint to) {
    asked.add(from);
    final c = Completer<TripRoute>();
    pending.add(c);
    return c.future;
  }

  /// Answers every open request with [answer].
  void release(TripRoute answer) {
    for (final c in pending) {
      if (!c.isCompleted) c.complete(answer);
    }
  }
}

/// A routing repository the test completes by hand.
///
/// Exists because a fetch that finishes before the widget is built proves
/// nothing about whether the widget listens for the fetch finishing. The state
/// under test is "the banner is already on screen when the route arrives".
class _PendingRoute implements RouteRepository {
  _PendingRoute(this._route);

  final TripRoute _route;
  final _completer = Completer<TripRoute>();

  void complete() => _completer.complete(_route);

  @override
  Future<TripRoute> route(GeoPoint from, GeoPoint to) => _completer.future;
}

void main() {
  const start = GeoPoint(5.6037, -0.1870);
  const end = GeoPoint(5.6057, -0.1870);

  group('geometry that came back from the engine', () {
    test('becomes points in lat, lng, not the GeoJSON order it arrives in', () {
      final r = straightRoute();
      // `[lng, lat]` from the function, `GeoPoint(lat, lng)` here. Swapping these
      // puts every driver in the Gulf of Guinea.
      expect(r.points.first.lat, closeTo(5.6037, 1e-9));
      expect(r.points.first.lng, closeTo(-0.1870, 1e-9));
    });

    test('a malformed point is dropped rather than throwing', () {
      final r = TripRoute(
        distanceM: 100,
        durationS: 60,
        durationFreeFlowS: 30,
        geometry: [
          [-0.1870, 5.6037],
          [-0.1870], // too short
          [double.nan, 5.6], // not finite
          [400.0, 91.0], // out of range
          [-0.1870, 5.6057],
        ],
        steps: const [],
        engine: 'osrm',
        degraded: false,
      );
      // A driver should get a line missing a vertex, not a black screen.
      expect(r.points, hasLength(2));
      expect(r.isUsable, isTrue);
    });

    test('a route of one point is not a route', () {
      final r = TripRoute(
        distanceM: 0,
        durationS: 0,
        durationFreeFlowS: 0,
        geometry: [
          [-0.1870, 5.6037],
        ],
        steps: const [],
        engine: 'osrm',
        degraded: false,
      );
      expect(r.isUsable, isFalse);
    });

    test('a route from a point to itself is not one either', () {
      // What the live function actually answers for identical points: HTTP 200,
      // two identical geometry points, `distanceM: 0`, and two zero-length steps.
      // It is well-formed and it passes a two-point test, so without
      // [TripRoute.goesAnywhere] a driver gets a banner reading "Head out on Otswe
      // Street, 0 m" and follows it forever. Measured by
      // `toolchain/verify-navigation.mjs`.
      final degenerate = TripRoute(
        distanceM: 0,
        durationS: 0,
        durationFreeFlowS: 0,
        geometry: [
          [-0.172147, 5.55692],
          [-0.172147, 5.55692],
        ],
        steps: const [
          RouteStep(
            instruction: 'Head out on Otswe Street',
            distanceM: 0,
            maneuver: 'depart',
            name: 'Otswe Street',
          ),
          RouteStep(
            instruction: 'You have arrived',
            distanceM: 0,
            maneuver: 'arrive',
            name: 'Otswe Street',
          ),
        ],
        engine: 'osrm',
        degraded: true,
      );
      // Two points, so the naive check passes it.
      expect(degenerate.isUsable, isTrue);
      expect(degenerate.goesAnywhere, isFalse);
    });

    test('a route with a non-zero distance is one', () {
      expect(straightRoute().goesAnywhere, isTrue);
    });

    test('a step with no instruction gets words, not a blank banner', () {
      final step = RouteStep.fromJson({
        'instruction': '   ',
        'distanceM': 10,
        'maneuver': 'turn',
        'name': 'Spintex Road',
      });
      // A banner with nothing in it reads as "loading", which is a lie.
      expect(step.instruction.trim(), isNotEmpty);
    });

    test('an arrive step with no instruction says so', () {
      final step = RouteStep.fromJson({
        'distanceM': 0,
        'maneuver': 'arrive',
        'name': '',
      });
      expect(step.instruction, 'You have arrived');
      expect(step.isArrival, isTrue);
    });
  });

  group('where the driver is on the route', () {
    test('at the very start they are in the first step', () {
      final p = progressOn(straightRoute(), start);
      expect(p.stepIndex, 0);
      expect(
        p.distanceToStepM,
        closeTo(111, 3),
        reason: 'the whole first leg is ahead',
      );
      expect(p.distanceToRouteM, lessThan(1));
    });

    test('past the first leg they are in the second step', () {
      // 0.001 degrees of latitude is about 111 m and each leg is one of those, so
      // the first turn is at 111 m. 5.6044 is 78 m in -- still the first leg. The
      // number has to be past 5.6047 to be in the second, and this is why a
      // hand-written expectation here is worth checking against the geometry
      // rather than guessed.
      expect(
        progressOn(straightRoute(), const GeoPoint(5.6044, -0.1870)).stepIndex,
        0,
      );
      final past = progressOn(straightRoute(), const GeoPoint(5.6048, -0.1870));
      expect(past.stepIndex, 1);
      expect(past.step!.name, 'Ring Road West');
    });

    test('a driver on the line is not off it', () {
      final p = progressOn(straightRoute(), const GeoPoint(5.6045, -0.1870));
      expect(p.distanceToRouteM, lessThan(kOffRouteM));
    });

    test('a driver beside the line is measured to the line, not to a vertex', () {
      // Half a millidegree east is about 55 m. If this were measured to the
      // nearest vertex the answer would be up to a whole segment away, which at
      // 20 m per geometry point would spend a quarter of the threshold on
      // nothing.
      final p = progressOn(straightRoute(), const GeoPoint(5.6045, -0.1865));
      expect(p.distanceToRouteM, closeTo(55, 12));
      expect(
        p.metresAlong,
        closeTo(89, 12),
        reason: 'their progress is unaffected by being beside the road',
      );
    });

    test('the final step is the arrival', () {
      // The arrival is the fourth leg, which starts at 333 m, so the driver has to
      // be past 5.6067 to be in it.
      final p = progressOn(straightRoute(), const GeoPoint(5.6070, -0.1870));
      expect(p.stepIndex, 3);
      expect(p.step!.isArrival, isTrue);
    });

    test(
      'a route with no steps reports no instruction rather than throwing',
      () {
        final r = straightRoute();
        final noSteps = TripRoute(
          distanceM: r.distanceM,
          durationS: r.durationS,
          durationFreeFlowS: r.durationFreeFlowS,
          geometry: r.geometry,
          steps: const [],
          engine: r.engine,
          degraded: false,
        );
        final p = progressOn(noSteps, start);
        expect(p.step, isNull);
        expect(p.hasStep, isFalse);
      },
    );
  });

  group('when to throw the route away', () {
    // No seconds on RouteProgress: how long the driver has been still is a
    // clock question and belongs to the controller, which owns the clock. Mixing it
    // in here would mean the geometry carried a time it has no way of knowing.
    RouteProgress onLine({required double distanceToRoute}) => RouteProgress(
      step: null,
      stepIndex: 0,
      distanceToStepM: 100,
      distanceToRouteM: distanceToRoute,
      metresAlong: 100,
    );

    test('a driver beside the route', () {
      expect(
        shouldReRoute(onLine(distanceToRoute: 80), secondsWithoutProgress: 0),
        isTrue,
      );
    });

    test('a driver on it, moving', () {
      expect(
        shouldReRoute(onLine(distanceToRoute: 5), secondsWithoutProgress: 0),
        isFalse,
      );
    });

    test('a driver on it, but stopped in traffic for long enough', () {
      // A driver stopped at a light is not off-route. Re-routing them produces an
      // identical route and a banner that says nothing, four minutes later, while
      // they are still in the queue.
      expect(
        shouldReRoute(onLine(distanceToRoute: 5), secondsWithoutProgress: 239),
        isFalse,
      );
      expect(
        shouldReRoute(onLine(distanceToRoute: 5), secondsWithoutProgress: 240),
        isTrue,
      );
    });

    test('the threshold is above the noise a phone fix produces', () {
      // A city fix is routinely 20-30 m out, and a car on a road whose geometry was
      // snapped to a street centreline is a car width off it while entirely on it.
      expect(kOffRouteM, greaterThan(30));
    });
  });

  group('the numbers a driver reads', () {
    test('metres, rounded to something actionable', () {
      // "387 m" implies a precision that turns as soon as the next fix arrives.
      expect(formatDistance(387), '390 m');
      expect(formatDistance(46), '50 m');
      expect(formatDistance(950), '950 m');
    });

    test('kilometres to one decimal under ten', () {
      expect(formatDistance(1200), '1.2 km');
      expect(formatDistance(9900), '9.9 km');
      expect(
        formatDistance(24000),
        '24 km',
        reason: 'past ten, a decimal is noise',
      );
    });

    test('an unusable distance reads as dashes, not "NaN m"', () {
      expect(formatDistance(double.nan), '--');
      expect(formatDistance(double.infinity), '--');
    });

    test('minutes under an hour', () {
      expect(formatDuration(420), '7 min');
      expect(formatDuration(0), '--');
    });

    test(
      'hours and padded minutes, because a clock is being read against one',
      () {
        // "65 min" and "1h 5m" both make the driver do arithmetic. "1 h 05" does not.
        expect(formatDuration(3900), '1 h 05');
      },
    );

    test('an arrival clock is local and padded', () {
      expect(formatArrivalClock(DateTime(2026, 9, 30, 14, 5), 1800), '14:35');
      expect(formatArrivalClock(DateTime(2026, 9, 30, 14, 5), 3600), '15:05');
    });
  });

  group('the controller', () {
    late RecordingSpeech speech;
    late DateTime now;

    NavigationController make(StubRoute repo) => NavigationController(
      from: start,
      to: end,
      repository: repo,
      speech: speech,
      clock: () => now,
      speakInstructions: true,
    );

    setUp(() {
      speech = RecordingSpeech();
      now = DateTime(2026, 9, 30, 14, 5);
    });

    test('a route arrives with a first instruction', () async {
      final c = make(StubRoute(straightRoute()));
      await c.start();
      expect(c.route, isNotNull);
      expect(c.currentStep, isNotNull);
      expect(c.currentStep!.maneuver, 'depart');
      expect(c.failure, isNull);
    });

    test('it says the first instruction once, not once per position fix', () async {
      final c = make(StubRoute(straightRoute()));
      await c.start();
      expect(speech.said, hasLength(1));
      // Lower-cased, because the spoken sentence begins with the distance and the
      // instruction is folded into it: "In 110 m, head north on Boundary Road".
      expect(speech.said.first, contains('head north'));

      // Nine fixes over the first leg, none of which crosses into the next step.
      for (var i = 1; i < 9; i++) {
        await c.onMoved(GeoPoint(5.6037 + i * 0.00005, -0.1870));
      }
      // Repeating the same sentence once a second for four minutes is the most
      // reliable way there is to make a driver uninstall a navigator.
      expect(speech.said, hasLength(1));
    });

    test(
      'it says the next instruction when the driver crosses into it',
      () async {
        final c = make(StubRoute(straightRoute()));
        await c.start();
        // Past 111 m, which is where the first leg ends.
        await c.onMoved(const GeoPoint(5.6048, -0.1870));
        expect(speech.said.length, greaterThan(1));
        expect(speech.said.last, contains('Ring Road West'));
      },
    );

    test('a driver who turned the voice off is not spoken to', () async {
      final c = NavigationController(
        from: start,
        to: end,
        repository: StubRoute(straightRoute()),
        speech: speech,
        clock: () => now,
      );
      await c.start();
      expect(speech.said, isEmpty);
    });

    test('turning the voice off stops what is being said', () async {
      final c = make(StubRoute(straightRoute()));
      await c.start();
      c.setSpeaking(false);
      // A driver who mutes while the last instruction is still being spoken hears
      // it finish and concludes the button did not work.
      expect(speech.stops, 1);
      await c.onMoved(const GeoPoint(5.6044, -0.1870));
      expect(speech.said, hasLength(1));
    });

    test(
      'a driver who leaves the line gets a new route from where they are',
      () async {
        final repo = StubRoute(straightRoute());
        final c = make(repo);
        await c.start();
        expect(repo.calls, 1);

        // Well off the line, east of the route.
        final rerouted = await c.onMoved(const GeoPoint(5.6040, -0.1855));
        expect(rerouted, isTrue);
        expect(repo.calls, 2);
        // The new route starts where they are, not where they set off. A route from
        // the original point is a route to somewhere they left.
        expect(repo.lastFrom!.lat, closeTo(5.6040, 1e-9));
      },
    );

    test('a driver stopped in traffic is not re-routed', () async {
      final repo = StubRoute(straightRoute());
      final c = make(repo);
      await c.start();
      await c.onMoved(const GeoPoint(5.6040, -0.1870));

      // Four minutes pass with no movement along the line.
      now = now.add(const Duration(minutes: 4));
      final rerouted = await c.onMoved(const GeoPoint(5.6040, -0.1870));
      expect(
        rerouted,
        isTrue,
        reason: 'four minutes in one place is a jam or a detour, and a new route is the right answer',
      );
      expect(repo.calls, 2);
    });

    test('a failed re-route keeps the route the driver was following', () async {
      final repo = StubRoute(straightRoute());
      final c = make(repo);
      await c.start();
      repo.error = const NavigationFailure('Could not reach the server.');
      await c.onMoved(const GeoPoint(5.6040, -0.1855));

      // A driver off-route and refused a new one is better off on a stale line
      // than with no line at all.
      expect(c.route, isNotNull);
      expect(c.failure, isNotNull);
    });

    test('a route that is not a route is refused, not drawn', () async {
      final broken = TripRoute(
        distanceM: 0,
        durationS: 0,
        durationFreeFlowS: 0,
        geometry: [
          [-0.1870, 5.6037],
        ],
        steps: const [],
        engine: 'osrm',
        degraded: false,
      );
      final c = make(StubRoute(broken));
      await c.start();
      expect(c.route, isNull);
      expect(c.failure, isNotNull);
    });

    test('a zero-length route says the driver is already there', () async {
      // Not "could not find a route": the route was found, it was simply
      // somewhere the driver already is, and telling them so is the truth.
      final degenerate = TripRoute(
        distanceM: 0,
        durationS: 0,
        durationFreeFlowS: 0,
        geometry: [
          [-0.172147, 5.55692],
          [-0.172147, 5.55692],
        ],
        steps: const [
          RouteStep(
            instruction: 'Head out',
            distanceM: 0,
            maneuver: 'depart',
            name: 'Otswe Street',
          ),
        ],
        engine: 'osrm',
        degraded: true,
      );
      final c = make(StubRoute(degenerate));
      await c.start();
      expect(c.route, isNull);
      expect(c.failure?.message, 'You are already there.');
    });

    test('no repository says so rather than doing nothing', () async {
      final c = NavigationController(from: start, to: end);
      await c.start();
      expect(c.failure, isNotNull);
      expect(c.currentStep, isNull);
    });

    test('the arrival time is the clock plus the routed duration', () async {
      final c = make(StubRoute(straightRoute()));
      await c.start();
      // `durationS` is the server's traffic-scaled figure, not the free-flow one.
      // 420 seconds after 14:05 is 14:12.
      expect(c.arrivalAt, DateTime(2026, 9, 30, 14, 12));
    });
  });

  group('the host', () {
    test(
      'reuses the controller so the voice setting survives a re-route',
      () async {
        final repo = StubRoute(straightRoute());
        final host = NavigationHost(
          repository: repo,
          clock: () => DateTime(2026, 9, 30, 14, 5),
        );
        await host.start(at: start, destination: end);
        final first = host.controller;
        host.setSpeaking(true);

        await host.start(at: const GeoPoint(5.6040, -0.1870), destination: end);
        // A fresh controller here would mean the driver has to turn the voice back
        // on at the pickup after turning it off at the drop-off.
        expect(identical(host.controller, first), isTrue);
        expect(host.speakInstructions, isTrue);
      },
    );

    test('a new destination retargets rather than starting over', () async {
      final repo = StubRoute(straightRoute());
      final host = NavigationHost(repository: repo);
      await host.start(at: start, destination: end);
      await host.start(at: start, destination: const GeoPoint(5.6200, -0.1870));
      // The pickup becomes the drop-off the moment the rider gets in, and a
      // navigator still pointing at the pickup sends the driver back.
      expect(host.controller!.to_.lat, closeTo(5.6200, 1e-9));
    });

    test(
      'stopping drops the route so the next trip does not inherit it',
      () async {
        final host = NavigationHost(repository: StubRoute(straightRoute()));
        await host.start(at: start, destination: end);
        expect(host.isRunning, isTrue);
        host.stop();
        expect(host.isRunning, isFalse);
      },
    );

    test(
      'a position with no navigation running is ignored, not a crash',
      () async {
        // The shell's poll calls this unconditionally.
        final host = NavigationHost(repository: StubRoute(straightRoute()));
        await host.onMoved(start);
        expect(host.isRunning, isFalse);
      },
    );
  });

  group('the banner', () {
    NavigationController withRoute({bool speaking = true}) {
      final c = NavigationController(
        from: start,
        to: end,
        repository: StubRoute(straightRoute()),
        speech: RecordingSpeech(),
        clock: () => DateTime(2026, 9, 30, 14, 5),
        speakInstructions: speaking,
      );
      // The controller's own constructor already fetched, so this is synchronous.
      return c;
    }

    Future<void> show(WidgetTester tester, NavigationController c) async {
      await tester.pumpWidget(
        appHarness(Scaffold(body: TurnBanner(controller: c))),
      );
      await tester.pump();
    }

    testWidgets('shows the instruction, the distance and the arrival', (
      tester,
    ) async {
      useDesignSurface(tester);
      final c = withRoute();
      await c.start();
      await show(tester, c);

      expect(find.byKey(const Key('turnBanner')), findsOneWidget);
      // `find.textContaining` because the instruction and the road name are one
      // RichText paragraph now, so there is no separate `Text` holding either.
      expect(find.byKey(const Key('turnBannerInstruction')), findsOneWidget);
      expect(
        find.textContaining('Head north', findRichText: true),
        findsOneWidget,
      );
      expect(find.byKey(const Key('turnBannerDistance')), findsOneWidget);
      expect(find.text('14:12'), findsOneWidget);
    });

    testWidgets(
      'shows the instruction when the route lands after the banner is up',
      (tester) async {
        useDesignSurface(tester);

        // The fetch is completed by hand, so it is genuinely still in flight while
        // the banner is on screen. Every other test in this group awaits `start`
        // *before* pumping the banner, which is why they never noticed that
        // `TurnBanner` was not listening to the controller at all: they only ever
        // saw a banner drawn after the route had already arrived.
        //
        // This is the state the driver is in for the whole of the call -- and on
        // the handset it left the banner saying "Working out the route" forever,
        // because the trip screen only rebuilt on a position fix, and a parked
        // phone does not produce one.
        final pending = _PendingRoute(straightRoute());
        final c = NavigationController(
          from: start,
          to: end,
          repository: pending,
          speech: RecordingSpeech(),
          clock: () => DateTime(2026, 9, 30, 14, 5),
        );

        await tester.pumpWidget(
          appHarness(Scaffold(body: TurnBanner(controller: c))),
        );
        await tester.pump();
        expect(find.byKey(const Key('turnBannerMessage')), findsOneWidget);

        unawaited(c.start());
        await tester.pump();
        expect(
          find.byKey(const Key('turnBannerMessage')),
          findsOneWidget,
          reason: 'the fetch is still open',
        );

        pending.complete();
        // Two pumps: the first turns the event queue over so the awaited future
        // resumes and notifies, the second draws the frame that shows it.
        await tester.pump();
        await tester.pump();

        expect(
          find.byKey(const Key('turnBannerMessage')),
          findsNothing,
          reason:
              'the banner must rebuild when the controller notifies, with '
              'nothing else in the app having changed',
        );
        expect(
          find.textContaining('Head north', findRichText: true),
          findsOneWidget,
        );
        expect(find.byKey(const Key('turnBannerDistance')), findsOneWidget);
      },
    );

    testWidgets('is one line, not two', (tester) async {
      useDesignSurface(tester);
      final c = withRoute();
      await c.start();
      await show(tester, c);

      // The whole reason the instruction and the road name are one paragraph
      // rather than stacked: on a phone in a mount, two rows of the one thing a
      // driver reads while driving is the cost that was not worth paying.
      expect(find.byKey(const Key('turnBannerInstruction')), findsOneWidget);
      expect(find.byKey(const Key('turnBannerRoad')), findsNothing);
      final banner = tester.getSize(find.byKey(const Key('turnBanner')));
      expect(
        banner.height,
        lessThan(90),
        reason: 'a single line of title text plus its padding, not two rows',
      );
    });

    testWidgets(
      'names the road on the same line, smaller than the instruction',
      (tester) async {
        useDesignSurface(tester);
        final c = withRoute();
        await c.start();
        await show(tester, c);

        // The road name is context and it is the part that changes while the
        // driver is looking at it, so it is not the biggest thing on the banner
        // and it is not on a line of its own. Asserted through the paragraph
        // because that is what it is: the instruction and the road name are one
        // RichText, so `find.text('Boundary Road')` finds nothing.
        final paragraph = tester.widget<RichText>(
          find.byKey(const Key('turnBannerInstruction')),
        );
        final text = paragraph.text.toPlainText();
        expect(text, contains('Boundary Road'));
        // The whole line, in the reading order a driver reads it in.
        expect(text, matches(RegExp(r'^Head north .*Boundary Road$')));

        // `TextSpan`, not `InlineSpan`: `RichText.text` is typed as the base
        // class, and only the concrete one carries `children`.
        final spans = (paragraph.text as TextSpan).children!.cast<TextSpan>();
        final instructionStyle = spans.first.style as TextStyle;
        final roadStyle = spans.last.style as TextStyle;
        expect(
          roadStyle.fontSize! < instructionStyle.fontSize!,
          isTrue,
          reason:
              'the instruction is the thing being read; the road is context',
        );
      },
    );
    testWidgets('says the failure rather than stale directions', (
      tester,
    ) async {
      useDesignSurface(tester);
      final c = withRoute();
      await c.start();
      c.attach(
        StubRoute(straightRoute())
          ..error = const NavigationFailure('Could not reach the server.'),
      );
      await c.onMoved(const GeoPoint(5.6040, -0.1855));
      await show(tester, c);

      // The re-route has resolved by the time the frame is built, so the spinner
      // is not what can be asserted here -- the durable outcome is that the banner
      // stops confidently instructing the driver along a route they have left.
      expect(
        c.route,
        isNotNull,
        reason:
            'a driver off-route is better off on a stale line than with none',
      );
      expect(find.byKey(const Key('turnBannerMessage')), findsOneWidget);
    });

    testWidgets('says why when there is no route at all', (tester) async {
      useDesignSurface(tester);
      final c =
          NavigationController(
            from: start,
            to: end,
            repository: StubRoute(straightRoute()),
            clock: () => DateTime(2026, 9, 30, 14, 5),
          )..attach(
            StubRoute(straightRoute())
              ..error = const NavigationFailure('Could not reach the server'),
          );
      await c.start();
      await show(tester, c);

      // A banner with nothing in it reads as loading, and if the route really
      // failed the driver is owed the reason.
      expect(find.byKey(const Key('turnBannerMessage')), findsOneWidget);
      expect(find.textContaining('Could not reach the server'), findsOneWidget);
    });

    testWidgets('has a mute control only when there is one to have', (
      tester,
    ) async {
      useDesignSurface(tester);
      final c = withRoute();
      await c.start();

      await tester.pumpWidget(
        appHarness(
          Scaffold(
            body: TurnBanner(controller: c, onMuteToggle: () {}),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('turnBannerMute')), findsOneWidget);

      // A button that cannot do anything teaches the driver the app is broken.
      await tester.pumpWidget(
        appHarness(Scaffold(body: TurnBanner(controller: c))),
      );
      await tester.pump();
      expect(find.byKey(const Key('turnBannerMute')), findsNothing);
    });

    testWidgets('muting goes through the controller, not just the icon', (
      tester,
    ) async {
      useDesignSurface(tester);
      final c = withRoute();
      await c.start();
      await tester.pumpWidget(
        appHarness(
          Scaffold(
            body: TurnBanner(
              controller: c,
              onMuteToggle: () => c.setSpeaking(false),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('turnBannerMute')));
      await tester.pump();
      expect(c.speakInstructions, isFalse);
    });
  });

  // Found on an A06 parked indoors, not reasoned about in advance.
  group('overlapping fetches', () {
    NavigationController withHangingRoute(HangingRoute repo) =>
        NavigationController(from: start, to: end, speech: RecordingSpeech())
          ..attach(repo);

    test('a poll during an open fetch does not start a second one', () async {
      final repo = HangingRoute();
      final c = withHangingRoute(repo);

      // The driver taps Navigate.
      final first = c.start();
      // ...and the shell's three-second poll lands before it answers.
      await c.start();
      await c.start();
      await c.start();

      expect(
        repo.asked.length,
        1,
        reason:
            'three extra polls must not become three extra routing requests',
      );

      repo.release(straightRoute());
      await first;
      expect(c.loading, isFalse);
    });

    test('the poll asks again once the fetch has landed', () async {
      // The other half, and the reason refusing the overlap is safe: the poll is
      // faster than the fetch, so the *next* tick makes a request from the newer
      // position rather than the stale one being skipped.
      final repo = HangingRoute();
      final c = withHangingRoute(repo);

      final first = c.start();
      repo.release(straightRoute());
      await first;

      final second = c.start();
      expect(repo.asked.length, 2, reason: 'a settled controller is not stuck');
      repo.release(straightRoute());
      await second;
      expect(c.loading, isFalse);
    });

    test('a refused fetch leaves no loading state behind', () async {
      // A fetch that throws must clear the guard, or the guard outlives the thing
      // it was guarding and navigation can never start again for this trip.
      final repo = StubRoute(straightRoute())
        ..error = NavigationFailure('nope');
      final c = NavigationController(
        from: start,
        to: end,
        speech: RecordingSpeech(),
      )..attach(repo);

      await c.start();
      expect(c.loading, isFalse);
      expect(c.failure?.message, 'nope');

      // And a second attempt is allowed through rather than silently skipped.
      repo.error = null;
      await c.start();
      expect(repo.calls, 2, reason: 'the guard must not latch after a failure');
    });
  });
}
