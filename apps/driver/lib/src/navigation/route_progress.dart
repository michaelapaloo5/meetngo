import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mng_core/mng_core.dart';

/// One instruction from the routing engine.
///
/// The shape of `route`'s `RouteStep`, mirrored. [distanceM] is the length of the
/// road the driver is being told to take, not the distance to the turn -- that is
/// the difference between "in 400 m, turn left" and "turn left in 400 m", and only
/// one of them is what a driver needs.
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
        // A step with no instruction is a step the driver cannot act on, so it is
        // given words rather than an empty banner. `arrive` is the one maneuver
        // where that happens legitimately.
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

/// A whole route, as the routing engine answered it.
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
  /// not two finite numbers is a bug in whatever produced it, and a driver should
  /// get a line missing one vertex rather than a black screen.
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
/// [goesAnywhere], and keeping them apart matters: a route from a point to itself
/// is a perfectly well-formed two-point line, and the reason to refuse it is that
/// it leads nowhere -- not that it is malformed.
bool get isUsable => points.length >= 2;

  /// Whether this route goes anywhere.
  ///
  /// Separate from [isUsable], and the distinction is not academic: asked to route
  /// from a point to itself, the live function answers **200** with two identical
  /// geometry points and two steps of `distanceM: 0` --
  ///
  ///   {"distanceM":0, "geometry":[[-0.172147,5.55692],[-0.172147,5.55692]],
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
      if (raw is Map<String, dynamic>) steps.add(RouteStep.fromJson(raw));
    }
    final geometry = <List<double>>[];
    for (final raw in (json['geometry'] as List<dynamic>? ?? const [])) {
      if (raw is List) geometry.add(raw.map((v) => (v as num).toDouble()).toList());
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

/// Where the driver is on the route, and what they should be doing.
///
/// This is the whole of navigation that is not a map and not a network call, and
/// it is pure: it takes a route and a position and answers. That matters more than
/// usual here, because the alternative is unit-testing turn logic through a
/// widget, which either needs a live `MapLibreMapController` or proves nothing.

/// The next instruction, and how far along it the driver is.
@immutable
class RouteProgress {
  const RouteProgress({
    required this.step,
    required this.stepIndex,
    required this.distanceToStepM,
    required this.distanceToRouteM,
    required this.metresAlong,
  });

  /// Null only when there is no route at all.
  final RouteStep? step;
  final int stepIndex;

  /// Metres to the manoeuvre this step describes.
  final double distanceToStepM;

  /// How far the driver is from the line, in metres.
  ///
  /// This is the off-route signal, and it is measured to the *nearest point on the
  /// polyline* rather than to the nearest vertex: at 20 m per geometry point, a
  /// driver on the road beside the line would read as 20 m off it, which is inside
  /// the threshold but a quarter of it, spent on nothing.
  final double distanceToRouteM;

  /// Metres travelled along the route so far, by the geometry's own ordering.
  final double metresAlong;

  bool get hasStep => step != null;
}

/// Where [point] sits on [route]'s line, and what it should be doing next.
///
/// Walks the geometry once, accumulating segment lengths, and keeps the point that
/// projects closest to [point]. Then the step is the first one whose cumulative
/// end lies ahead of that point.
///
/// Two decisions:
///
/// **Projection, not nearest vertex.** Projecting each segment gives a true
/// distance to the line and a true position along it, for about six extra
/// operations per point.
///
/// **Steps are matched on distance along the line**, using each step's
/// `distanceM` accumulated from the start. OSRM's `steps` are in order and their
/// distances sum to the route distance, so the running total is a sound index into
/// them. A driver who is 400 m along is in the first step whose cumulative end
/// passes 400 m.
RouteProgress progressOn(TripRoute route, GeoPoint point) {
  final pts = route.points;
  if (pts.length < 2 || route.steps.isEmpty) {
    return RouteProgress(
      step: null,
      stepIndex: -1,
      distanceToStepM: 0,
      distanceToRouteM: double.infinity,
      metresAlong: 0,
    );
  }

  var bestDistance = double.infinity;
  var bestAlong = 0.0;
  var travelled = 0.0;

  for (var i = 0; i < pts.length - 1; i++) {
    final a = pts[i];
    final b = pts[i + 1];
    final segmentM = a.distanceKmTo(b) * 1000;
    final along = _projectOntoSegmentM(a, b, point);
    final onLine = GeoPoint(
      a.lat + (b.lat - a.lat) * along,
      a.lng + (b.lng - a.lng) * along,
    );
    final distance = point.distanceKmTo(onLine) * 1000;

    if (distance < bestDistance) {
      bestDistance = distance;
      bestAlong = travelled + segmentM * along;
    }
    travelled += segmentM;
  }

  final total = travelled;

  // Find the step this position belongs to. The running total is the sum of the
  // steps' own distances, which the engine guarantees equals the route distance;
  // if the two disagree (a truncated route, a step list that got cut off), the
  // clamp below keeps the index in range rather than throwing.
  var cumulative = 0.0;
  var index = 0;
  for (var i = 0; i < route.steps.length; i++) {
    final stepEnd = cumulative + route.steps[i].distanceM;
    if (bestAlong <= stepEnd) {
      index = i;
      break;
    }
    cumulative = stepEnd;
    index = i;
  }
  index = index.clamp(0, route.steps.length - 1);

  final distanceToStepM = math.max(0.0, route.steps[index].distanceM - (bestAlong - cumulative))
      .clamp(0.0, double.infinity);

  return RouteProgress(
    step: route.steps[index],
    stepIndex: index,
    distanceToStepM: distanceToStepM,
    distanceToRouteM: bestDistance,
    metresAlong: bestAlong.clamp(0.0, total),
  );
}

/// How far along segment `a`..`b` the projection of [point] falls, 0 to 1.
///
/// A plain linear projection in degrees. Over a segment of a few tens of metres
/// the difference between degrees and a projected Mercator is far below the noise
/// of the GPS fix itself, and this keeps the arithmetic to one dot product.
double _projectOntoSegmentM(GeoPoint a, GeoPoint b, GeoPoint point) {
  final dx = b.lng - a.lng;
  final dy = b.lat - a.lat;
  final lengthSquared = dx * dx + dy * dy;
  if (lengthSquared == 0) return 0;
  final t = ((point.lng - a.lng) * dx + (point.lat - a.lat) * dy) / lengthSquared;
  return t.clamp(0.0, 1.0);
}

/// Whether [distanceToRouteM] counts as off the route.
///
/// 60 m, and the number is a judgement with a specific shape: a phone's fix in a
/// city is routinely 20-30 m out, and a vehicle on a road whose geometry was
/// snapped to the nearest street centreline can be a car width off it while
/// entirely on it. So a threshold that reacts to GPS noise re-routes a driver who
/// is doing nothing wrong, and re-routing twice in a row on the same corner is
/// worse than being briefly off the line.
///
/// Twice the fix noise is the floor; anything lower is reacting to the receiver.
const double kOffRouteM = 60;

/// Whether a route needs re-fetching for [progress].
///
/// Two conditions, and both are needed:
///
/// - **Off the line** by more than [kOffRouteM]. The driver has gone somewhere the
///   route does not describe.
/// - **Stuck.** A driver on the line who has not moved along it is not off-route,
///   they are in traffic, and re-routing them produces a new route that is
///   identical and a banner that says nothing. `secondsWithoutProgress` is
///   supplied by the caller because it is a clock question, not a geometry one.
bool shouldReRoute(RouteProgress progress, {required int secondsWithoutProgress}) {
  if (progress.distanceToRouteM > kOffRouteM) return true;
  // Long enough to be a jam rather than a set of traffic lights. Four minutes is
  // about the point where a driver in Accra traffic has concluded the app is
  // broken, and short enough that a genuine detour is caught while it matters.
  return secondsWithoutProgress >= 240;
}

/// "400 m", "1.2 km", "350 m".
///
/// Rounded to a distance a driver can act on. Under a kilometre, to the nearest
/// 10 m, because a banner reading "387 m" implies a precision that turns as soon as
/// the next fix arrives. Over a kilometre, to the nearest 100 m with one decimal
/// under 10 km, because a tenth of a kilometre is about what a street is.
String formatDistance(double metres) {
  if (metres.isNaN || metres.isInfinite) return '--';
  if (metres < 1000) return '${(metres / 10).round() * 10} m';
  if (metres < 10000) return '${(metres / 1000).toStringAsFixed(1)} km';
  return '${(metres / 1000).round()} km';
}

/// "12 min", "1 h 05".
///
/// Deliberately not "1h 5m" or "65 min": a driver reading an arrival time is
/// doing arithmetic against the clock, and the hours-and-minutes form with a
/// leading zero is the one that needs none.
String formatDuration(int seconds) {
  if (seconds <= 0) return '--';
  final minutes = (seconds / 60).round();
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return '$hours h ${rest.toString().padLeft(2, '0')}';
}

/// The arrival clock, for a banner: "14:35".
String formatArrivalClock(DateTime now, int seconds) {
  final at = now.add(Duration(seconds: seconds));
  final h = at.hour.toString().padLeft(2, '0');
  final m = at.minute.toString().padLeft(2, '0');
  return '$h:$m';
}