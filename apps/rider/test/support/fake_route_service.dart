import 'dart:async';

import 'package:mng_core/mng_core.dart';
import 'package:meetngo_rider/src/map/rider_route_service.dart';

/// A [RiderRouteService] that answers from a script instead of the network.
///
/// Keyed by `from->to` at five decimals, which is the same key the real
/// implementation's cache uses -- so a test passing here is passing on the same
/// string the app builds, not on a convenient approximation of it.
class FakeRiderRouteService implements RiderRouteService {
  FakeRiderRouteService({
    this.answer,
    this.answers = const {},
    this.failWith,
    this.pending,
  });

  /// Answered for any pair not named in [answers].
  final List<GeoPoint>? answer;

  /// Per-pair answers, keyed `lat,lng->lat,lng`.
  final Map<String, TripRoute> answers;

  /// When set, every call fails instead of answering.
  final Object? failWith;

  /// When set, call *n* returns `pending[n]` and nothing else.
  ///
  /// This is how the stale-response test is made deterministic. Two overlapping
  /// requests whose answers arrive in the "wrong" order is a race, and a race
  /// expressed as `Future.delayed` is a test that passes on a fast machine and
  /// fails on a slow one -- which is a test about the machine, not about the code.
  /// Completing two [Completer]s in the order the code must cope with says
  /// exactly what that order is.
  final List<Completer<TripRoute?>>? pending;

  /// How many times it was asked. Asserted on, because "asked exactly once" is a
  /// requirement: a rebuild loop asking once a second would otherwise be
  /// invisible.
  int calls = 0;

  static String key(GeoPoint from, GeoPoint to) =>
      '${from.lat.toStringAsFixed(5)},${from.lng.toStringAsFixed(5)}'
      '->${to.lat.toStringAsFixed(5)},${to.lng.toStringAsFixed(5)}';

  @override
  Future<TripRoute?> route(GeoPoint from, GeoPoint to) {
    calls++;
    if (failWith != null) return Future<TripRoute?>.error(failWith!);
    final scripted = pending;
    if (scripted != null) return scripted[calls - 1].future;
    final points = answers[key(from, to)]?.points ?? answer;
    if (points == null || points.length < 2) {
      return Future<TripRoute?>.value(null);
    }
    return Future<TripRoute?>.value(routeThrough(points));
  }

  /// A route whose [distanceM] and [geometry] both come from [points].
  ///
  /// [distanceM] is deliberately generous and not derived from the geometry: this
  /// fake is testing what the app *does* with a route, and a distance that
  /// disagreed with its own points would only test the fake.
  static TripRoute routeThrough(List<GeoPoint> points) => TripRoute(
    distanceM: 3100,
    durationS: 600,
    durationFreeFlowS: 315,
    geometry: [
      for (final p in points) [p.lng, p.lat],
    ],
    steps: const [],
    engine: 'osrm',
    degraded: false,
  );
}
