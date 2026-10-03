import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';
import 'package:meetngo_driver/src/navigation/route_progress.dart';

/// The driver's turn-by-turn, checked against a route the engine actually
/// returned.
///
/// ## Why a captured fixture and not coordinates someone typed
///
/// Hand-written test coordinates are the one thing guaranteed not to look like a
/// real road: no snapping to junctions, no unnamed service roads, no zero-length
/// steps, and a geometry whose vertices are evenly spaced by hand. Bugs that only
/// appear on real geometry pass every test written that way -- a projection that
/// snaps to the wrong segment, a step index that runs off the end, a distance
/// total that disagrees with the engine's own.
///
/// This is the Tesano-to-Dansoman run the app's own recent rides are on, captured
/// from the deployed `route` function by `toolchain/capture-route-fixture.mjs`:
/// 352 geometry points, 25 steps, real named streets. Re-capture it with that
/// script; do not hand-edit it.
void main() {
  final route = TripRoute.fromJson(
    jsonDecode(
      File('test/navigation/fixtures/real_route_tesano_dansoman.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>,
  );
  final points = route.points;

  group('the captured route is a real one', () {
    test('it has geometry and steps', () {
      expect(points.length, greaterThan(50), reason: 'snapped road geometry');
      expect(route.steps.length, greaterThan(10));
      expect(route.isUsable, isTrue);
      expect(route.goesAnywhere, isTrue);
    });

    test('the steps cover the route the engine measured', () {
      // `progressOn` indexes steps by accumulating their own `distanceM` and
      // treating the running total as a position along the route. That only works
      // if the engine's step distances sum to its route distance. If they do not,
      // every "you are in step N" is right by accident.
      final stepped = route.steps.fold<double>(
        0,
        (sum, s) => sum + s.distanceM,
      );
      final engine = route.distanceM;
      expect(
        (stepped - engine).abs() / engine,
        lessThan(0.02),
        reason:
            'steps total ${stepped.toStringAsFixed(0)} m against an engine '
            'distance of ${engine.toStringAsFixed(0)} m',
      );
    });

    test('no step tells a driver to act on a manoeuvre with no words', () {
      for (final step in route.steps) {
        expect(
          step.instruction.trim(),
          isNotEmpty,
          reason: 'a blank instruction leaves the banner with nothing to say',
        );
      }
    });
  });

  group('progress along the real route', () {
    test('at the pickup the first step is current', () {
      final progress = progressOn(route, points.first);
      expect(progress.hasStep, isTrue);
      expect(progress.stepIndex, 0);
      expect(progress.step!.instruction, route.steps.first.instruction);
    });

    test('standing still on the road is not off-route', () {
      // A phone's fix in Accra is routinely 20-30 m out. A driver sitting still on
      // the road must not read as having left it, or the app re-routes them for
      // the GPS.
      final progress = progressOn(route, points[3]);
      expect(
        progress.distanceToRouteM,
        lessThan(kOffRouteM),
        reason: 'a point taken from the route itself is on the route',
      );
    });

    test('a point off in the next district reads as off-route', () {
      // 0.01 degrees of latitude is about 1.1 km, unambiguously not on this road.
      final off = GeoPoint(points.first.lat - 0.01, points.first.lng);
      final progress = progressOn(route, off);
      expect(
        progress.distanceToRouteM,
        greaterThan(kOffRouteM),
        reason: 'a kilometre away is not a rounding error',
      );
      expect(shouldReRoute(progress, secondsWithoutProgress: 0), isTrue);
    });

    test('metres along never goes backwards and tracks the route length', () {
      // `metresAlong` is the *polyline's* accumulated length, measured by walking
      // the geometry. The engine's `distanceM` is its own summary figure. They are
      // not the same number and should not be treated as one: on this route the
      // polyline measures 11,335 m against an engine distance of 11,327 m, eight
      // metres apart on 11 km. The difference is the overview geometry and
      // rounding, and it is the right way round -- `metresAlong` is "how far along
      // the line am I", which the line itself answers, and `distanceM` is "how
      // long is this trip", which is the engine's to say.
      //
      // So the bound is a tolerance rather than equality. Half a per cent is far
      // above the real gap and far below anything a driver or a fare could notice.
      const tolerance = 0.005;
      var previous = -1.0;
      for (var i = 0; i < points.length; i += 7) {
        final metres = progressOn(route, points[i]).metresAlong;
        expect(
          metres,
          greaterThanOrEqualTo(previous),
          reason: 'at geometry point $i',
        );
        expect(
          metres,
          lessThanOrEqualTo(route.distanceM * (1 + tolerance)),
          reason:
              'at geometry point $i, ${metres.toStringAsFixed(0)} m along a '
              '${route.distanceM.toStringAsFixed(0)} m route',
        );
        previous = metres;
      }
    });

    test('the step index only ever moves forward down the route', () {
      var previous = -1;
      for (var i = 0; i < points.length; i += 7) {
        final index = progressOn(route, points[i]).stepIndex;
        expect(index, greaterThanOrEqualTo(previous), reason: 'at point $i');
        previous = index;
      }
      // And it ends on the arrival, which is the step worth saying loudly.
      final end = progressOn(route, points.last);
      expect(end.stepIndex, route.steps.length - 1);
      expect(end.step!.isArrival, isTrue);
    });

    test('a driver stopped in traffic is not re-routed', () {
      // On the line, not moving. Re-routing produces an identical route and a
      // banner that says nothing, which is worse than silence.
      final progress = progressOn(route, points[40]);
      expect(
        shouldReRoute(progress, secondsWithoutProgress: 60),
        isFalse,
        reason: 'a minute in traffic is not four',
      );
      expect(
        shouldReRoute(progress, secondsWithoutProgress: 240),
        isTrue,
        reason: 'four minutes is a jam the driver has given up on',
      );
    });
  });

  group('what the banner would actually say', () {
    test('every step renders a distance and a duration', () {
      // `formatDistance` and `formatDuration` are what the banner prints. A
      // negative or non-finite value here is a driver being told to turn left in
      // "-40 m".
      for (final step in route.steps) {
        expect(formatDistance(step.distanceM), isNot('--'));
        expect(formatDistance(step.distanceM), isNot(contains('-')));
      }
      expect(formatDuration(route.durationS), matches(RegExp(r'\d+ min')));
      expect(formatDuration(0), '--');
    });

    test('a named street survives into the instruction', () {
      // The engine gives the street separately; the sentence is what a driver
      // reads, and a route that names nothing is a route with no landmarks.
      final named = route.steps.where((s) => s.name.isNotEmpty).toList();
      expect(
        named.length,
        greaterThan(5),
        reason: 'named streets in the route',
      );
      expect(
        named.any((s) => s.instruction.contains(s.name)),
        isTrue,
        reason: 'at least one instruction carries its street name',
      );
    });
  });
}
