import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';
import 'package:meetngo_rider/src/map/rider_route_map.dart';
import 'package:meetngo_rider/src/map/rider_route_service.dart';

import '../support/fake_route_service.dart';

/// A stand-in for the map, so these tests are about fetching and staleness
/// rather than about MapLibre.
///
/// Records every shape it is handed. `last` is read through [_last] because an
/// empty log would otherwise raise a `StateError` that reads like a failure of
/// the thing under test.
Widget _mapSpy(List<GeoPoint>? shape, List<List<GeoPoint>?> log) => Builder(
  builder: (context) {
    log.add(shape);
    return const SizedBox.shrink();
  },
);

List<GeoPoint>? _last(List<List<GeoPoint>?> log) =>
    log.isEmpty ? null : log.last;

void main() {
  const from = GeoPoint(5.55692, -0.172147);
  const to = GeoPoint(5.6052, -0.166);

  /// Deliberately not a straight line, so a test cannot pass whether the shape
  /// was used or ignored: a two-point "road" would look the same as the fallback.
  final road = <GeoPoint>[
    const GeoPoint(5.55692, -0.172147),
    const GeoPoint(5.57, -0.169),
    const GeoPoint(5.59, -0.171),
    const GeoPoint(5.6052, -0.166),
  ];

  Widget wrap(RiderRouteMap map) =>
      Directionality(textDirection: TextDirection.ltr, child: map);

  group('the route wrapper', () {
    testWidgets('draws the straight line, then the road', (tester) async {
      // The pending completer is what makes the two states separately
      // observable. An answer that resolves in a microtask is already delivered
      // by the time the first frame is built, so the "no road yet" state cannot
      // be asserted against one -- the test would be asserting a frame that never
      // happens on a real device either.
      final log = <List<GeoPoint>?>[];
      final answer = Completer<TripRoute?>();
      final service = FakeRiderRouteService(pending: [answer]);

      await tester.pumpWidget(
        wrap(
          RiderRouteMap(
            from: from,
            to: to,
            service: service,
            builder: (context, shape) => _mapSpy(shape, log),
          ),
        ),
      );
      await tester.pump();

      expect(_last(log), isNull, reason: 'straight line while in flight');

      answer.complete(FakeRiderRouteService.routeThrough(road));
      await tester.pumpAndSettle();

      expect(_last(log), road, reason: 'the road once it arrives');
    });

    testWidgets('stays on the straight line when routing fails', (
      tester,
    ) async {
      final log = <List<GeoPoint>?>[];
      final service = FakeRiderRouteService(failWith: Exception('503'));

      await tester.pumpWidget(
        wrap(
          RiderRouteMap(
            from: from,
            to: to,
            service: service,
            builder: (context, shape) => _mapSpy(shape, log),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Never a throw and never an error widget. A map that cannot get directions
      // still has to be a map.
      expect(tester.takeException(), isNull);
      expect(_last(log), isNull, reason: 'no road, so the straight line stays');
    });

    testWidgets('discards an answer to a destination left behind', (
      tester,
    ) async {
      // The bug this exists to prevent: the rider drags the destination, two
      // requests go out, the *first* answers last, and the map ends up drawing
      // the road to where the destination used to be. Confidently wrong, and
      // wrong about the thing the rider is choosing.
      //
      // Both completers are resolved by hand, newest first, so the ordering under
      // test is the ordering the test declares. Expressed as a delay instead,
      // this would be a test about how fast the machine is.
      final log = <List<GeoPoint>?>[];
      final first = Completer<TripRoute?>();
      final second = Completer<TripRoute?>();
      final service = FakeRiderRouteService(pending: [first, second]);

      await tester.pumpWidget(
        wrap(
          RiderRouteMap(
            from: from,
            to: to,
            service: service,
            builder: (context, shape) => _mapSpy(shape, log),
          ),
        ),
      );
      await tester.pump();
      expect(service.calls, 1);

      // The destination moves while the first request is still open.
      await tester.pumpWidget(
        wrap(
          RiderRouteMap(
            from: from,
            to: const GeoPoint(5.58, -0.166),
            service: service,
            builder: (context, shape) => _mapSpy(shape, log),
          ),
        ),
      );
      await tester.pump();
      expect(service.calls, 2, reason: 'the destination moved, so it re-asked');

      second.complete(FakeRiderRouteService.routeThrough(road));
      await tester.pumpAndSettle();
      expect(_last(log), road, reason: 'the new destination answered');

      first.complete(
        FakeRiderRouteService.routeThrough(const [
          GeoPoint(5.55692, -0.172147),
          GeoPoint(5.56, -0.17),
        ]),
      );
      await tester.pumpAndSettle();

      expect(
        _last(log),
        road,
        reason: 'the late answer must not replace the current route',
      );
    });

    testWidgets('asks once for one pair, however often it rebuilds', (
      tester,
    ) async {
      // A rebuild per GPS fix would otherwise put a routing request on the wire
      // once a second, against a service with no SLA.
      final answer = Completer<TripRoute?>();
      final service = FakeRiderRouteService(pending: [answer]);
      Widget build() => wrap(
        RiderRouteMap(
          from: from,
          to: to,
          service: service,
          builder: (context, shape) => _mapSpy(shape, []),
        ),
      );

      await tester.pumpWidget(build());
      await tester.pump();
      answer.complete(FakeRiderRouteService.routeThrough(road));
      await tester.pumpAndSettle();

      await tester.pumpWidget(build());
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();

      expect(service.calls, 1);
    });

    testWidgets('uses a cached shape without asking', (tester) async {
      final service = FakeRiderRouteService(answer: road);
      final cache = RouteShapeCache()..remember(from, to, road);
      final log = <List<GeoPoint>?>[];

      await tester.pumpWidget(
        wrap(
          RiderRouteMap(
            from: from,
            to: to,
            service: service,
            cache: cache,
            builder: (context, shape) => _mapSpy(shape, log),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(service.calls, 0, reason: 'already known');
      expect(_last(log), road);
    });

    testWidgets('a shape from before the move is not reused', (tester) async {
      // The other half of the cache: it must not answer the *new* question with
      // the *old* journey.
      final service = FakeRiderRouteService(answer: road);
      final cache = RouteShapeCache()..remember(from, to, road);
      final log = <List<GeoPoint>?>[];

      await tester.pumpWidget(
        wrap(
          RiderRouteMap(
            from: from,
            to: const GeoPoint(5.58, -0.166),
            service: service,
            cache: cache,
            builder: (context, shape) => _mapSpy(shape, log),
          ),
        ),
      );
      await tester.pump();

      expect(service.calls, 1, reason: 'a different pair is a different route');
    });
  });

  group('RouteShapeCache', () {
    test('remembers and returns the same pair', () {
      final cache = RouteShapeCache()..remember(from, to, road);
      expect(cache.shapeFor(from, to), road);
    });

    test('does not confuse a reversed pair', () {
      // A ride the other way is a different road, and a cache that ignored the
      // order would draw the outbound route backwards.
      final cache = RouteShapeCache()..remember(from, to, road);
      expect(cache.shapeFor(to, from), isNull);
    });

    test('refuses a shape that is not a line', () {
      final cache = RouteShapeCache()
        ..remember(from, to, [const GeoPoint(5.5, -0.17)]);
      expect(cache.shapeFor(from, to), isNull);
    });

    test('is bounded', () {
      final cache = RouteShapeCache();
      for (var i = 0; i < 40; i++) {
        cache.remember(from, GeoPoint(5.5 + i * 0.01, -0.17), road);
      }
      expect(
        cache.shapeFor(from, GeoPoint(5.5 + 39 * 0.01, -0.17)),
        road,
        reason: 'the newest pair survived an unbounded run of remembers',
      );
    });
  });
}
