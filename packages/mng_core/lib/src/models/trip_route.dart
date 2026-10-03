import 'package:flutter/foundation.dart';

import 'geo_point.dart';

/// One instruction from the routing engine.
///
/// The shape of `route`'s `RouteStep`, mirrored. [distanceM] is the length of the
/// road being taken, not the distance to the turn -- that is the difference
/// between "in 400 m, turn left" and "turn left in 400 m", and only one of them
/// is what a driver needs.
@immutable
class RouteStep {
  const RouteStep({
    required this.instruction,
    required this.distanceM,
    required this.maneuver,
    required this.name,
  });

  final String instruction;
  final double distanceM;
  final String maneuver;
  final String name;

  factory RouteStep.fromJson(Map<String, dynamic> json) => RouteStep(
    instruction: (json['instruction'] as String?)?.trim().isNotEmpty ?? false
        ? (json['instruction'] as String).trim()
        // A step with no instruction is a step nobody can act on, so it is given
        // words rather than an empty banner. `arrive` is the one maneuver where
        // that happens legitimately.
        : _fallbackFor((json['maneuver'] as String?) ?? ''),
    distanceM: ((json['distanceM'] as num?) ?? 0).toDouble(),
    maneuver: (json['maneuver'] as String?) ?? '',
    name: (json['name'] as String?) ?? '',
  );

  static String _fallbackFor(String maneuver) {
    switch (maneuver) {
      case 'arrive':
        return 'You have arrived';
      case 'depart':
        return 'Head out';
      case 'turn':
      case 'end of road':
      case 'fork':
      case 'roundabout':
        return 'Continue';
      default:
        return 'Continue';
    }
  }

  /// Whether this is the last step, which is the one worth announcing loudly.
  bool get isArrival => maneuver == 'arrive';

  @override
  bool operator ==(Object other) =>
      other is RouteStep &&
      other.instruction == instruction &&
      other.distanceM == distanceM &&
      other.maneuver == maneuver &&
      other.name == name;

  @override
  int get hashCode => Object.hash(instruction, distanceM, maneuver, name);
}

/// A whole route, as the `route` Edge Function answered it.
///
/// **Shared, and that is the change.** This model used to live in the driver app
/// (`src/navigation/route_progress.dart`) because the driver app was the only
/// thing that asked for directions. The rider app needs the same answer for the
/// same reason -- to draw the road instead of a straight line between two pins --
/// so it lives here, next to the function that produces it.
///
/// Two copies of a model mirroring one JSON response is two places for them to
/// drift, and the drift would be silent: a rider drawing a line from a geometry
/// the driver app's copy would have rejected, with no error anywhere.
///
/// The rider uses [points] and [distanceM]. The driver additionally uses [steps],
/// [durationS] and the navigation that reads them.
@immutable
class TripRoute {
  const TripRoute({
    required this.distanceM,
    required this.durationS,
    required this.durationFreeFlowS,
    required this.geometry,
    required this.steps,
    required this.engine,
    required this.degraded,
  });

  /// **Along the road**, in metres. Not as the crow flies.
  ///
  /// Worth being explicit about, because the fare is not computed from this.
  /// `trips.distance_km` comes from the `trip_distance_km` RPC, which is
  /// `st_distance(a::geography, b::geography)` -- straight-line, server-side. So a
  /// route that follows roads is *longer* than the distance the rider is billed
  /// for, by roughly a quarter in Accra. The map and the bill are both honest and
  /// they do not match, which is a deliberate choice for now and not an oversight;
  /// see the note in `apps/rider/lib/src/map/rider_route_service.dart`.
  final double distanceM;

  /// Seconds to show, already scaled for city traffic by the server.
  final int durationS;

  /// What the engine actually reported, kept so the app can show one and reason
  /// about the other.
  final int durationFreeFlowS;

  /// `[lng, lat]`, GeoJSON order, straight from the engine.
  final List<List<double>> geometry;
  final List<RouteStep> steps;

  /// `osrm` or `openrouteservice`. Which engine answered is a diagnostic, not
  /// something a rider is shown.
  final String engine;

  /// True when the primary engine was refused and a fallback answered.
  final bool degraded;

  /// [geometry] as points, which is what the map wants.
  ///
  /// Malformed pairs are dropped rather than throwing. A geometry point that is
  /// not two finite numbers is a bug in whatever produced it, and the rider
  /// should get a line missing one vertex rather than a black screen.
  List<GeoPoint> get points {
    final out = <GeoPoint>[];
    for (final pair in geometry) {
      if (pair.length < 2) continue;
      final lng = pair[0], lat = pair[1];
      if (!lat.isFinite || !lng.isFinite) continue;
      if (lat.abs() > 90 || lng.abs() > 180) continue;
      out.add(GeoPoint(lat, lng));
    }
    return out;
  }

  /// Whether the geometry is a line at all.
  ///
  /// Two points and no more questions. Whether it *goes anywhere* is
  /// [goesAnywhere], and keeping them apart matters: a route from a point to
  /// itself is a perfectly well-formed two-point line, and the reason to refuse it
  /// is that it leads nowhere -- not that it is malformed.
  bool get isUsable => points.length >= 2;

  /// Whether this route goes anywhere.
  ///
  /// Separate from [isUsable], and the distinction is not academic: asked to route
  /// from a point to itself, the live function answers **200** with two identical
  /// geometry points and two steps of `distanceM: 0` --
  ///
  ///   {"distanceM":0,"geometry":[[-0.172147,5.55692],[-0.172147,5.55692]],
  ///    "steps":[{"instruction":"Head out on Otswe Street","distanceM":0,...},
  ///             {"instruction":"You have arrived ...","distanceM":0,...}]}
  ///
  /// which passes a two-point test. A driver shown that gets a banner reading
  /// "Head out on Otswe Street, 0 m" and follows it until they give up. Measured,
  /// not assumed: `toolchain/verify-navigation.mjs` sends identical points and
  /// reads the response back.
  bool get goesAnywhere {
    if (!isUsable) return false;
    // The distance is the engine's, and a route whose own `distanceM` is zero is
    // not a route whatever its geometry says.
    if (distanceM <= 0) return false;
    return points.first != points.last;
  }

  factory TripRoute.fromJson(Map<String, dynamic> json) {
    final steps = <RouteStep>[];
    for (final raw in (json['steps'] as List<dynamic>? ?? const [])) {
      if (raw is Map<String, dynamic>) {
        steps.add(RouteStep.fromJson(raw));
      }
    }
    final geometry = <List<double>>[];
    for (final raw in (json['geometry'] as List<dynamic>? ?? const [])) {
      if (raw is List)
        geometry.add(raw.map((v) => (v as num).toDouble()).toList());
    }
    return TripRoute(
      distanceM: ((json['distanceM'] as num?) ?? 0).toDouble(),
      durationS: ((json['durationS'] as num?) ?? 0).round(),
      durationFreeFlowS: ((json['durationFreeFlowS'] as num?) ?? 0).round(),
      geometry: geometry,
      steps: steps,
      engine: (json['engine'] as String?) ?? 'osrm',
      degraded: json['degraded'] == true,
    );
  }
}
