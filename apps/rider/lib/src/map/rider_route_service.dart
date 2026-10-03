import 'dart:async';

import 'package:mng_core/mng_core.dart';

/// A road route between two points, for the rider's map.
///
/// ## Why this calls a function rather than a routing engine
///
/// The `route` Edge Function already exists, is already deployed, and already
/// holds the engine choice behind a server-side boundary: it tries the keyed
/// OpenRouteService and falls through to the keyless public OSRM server, so no
/// routing credential is ever inside the APK. The driver app has been calling it
/// all along. The rider app was drawing `[pickup, dropoff]` -- two points, one
/// straight line -- while the same function sat there answering with the real
/// road. So this adds no engine, no key, no account and no cost.
///
/// ## Why it returns null and never throws
///
/// A map that shows nothing is worse than a map that shows a straight line. If
/// the function is down, rate-limited, or the two points are a few metres apart,
/// the honest thing to draw is the line the rider already understands, and the
/// honest thing to show about it is nothing at all. So a failure is `null`, and
/// the caller falls back.
///
/// Throwing here would push the decision -- what a rider sees when the network
/// lets them down -- into every screen that draws a route, and each of them would
/// decide it differently.
class RiderRouteService {
  RiderRouteService(this._client);

  /// The Supabase client, typed `dynamic` to match the other repositories in this
  /// app. Every one of them does, and changing the convention in one file would
  /// be a change nobody asked for.
  final dynamic _client;

  /// How long to wait before treating the call as failed.
  ///
  /// The same 15 seconds the driver app allows, and for the same reason: a call
  /// that never answers must not leave a rider looking at a straight line
  /// forever. The straight line is the fallback, so the timeout is how long the
  /// fallback is delayed, not how long anything is broken.
  static const Duration timeout = Duration(seconds: 15);

  /// The route from [from] to [to], or null if there isn't one to draw.
  ///
  /// Null covers: both engines refusing, the function erroring, a response that is
  /// not a route object, and a route that leads nowhere.
  Future<TripRoute?> route(GeoPoint from, GeoPoint to) async {
    try {
      final res = await _client.functions
          .invoke('route', body: {'from': from.toJson(), 'to': to.toJson()})
          .timeout(timeout);
      final data = res.data;
      if (data is! Map) return null;
      final route = TripRoute.fromJson(Map<String, dynamic>.from(data));
      // `goesAnywhere`, not `isUsable`: the function answers 200 with two
      // identical points for a route to the same place, which is a line and
      // leads nowhere.
      return route.goesAnywhere ? route : null;
    } catch (_) {
      // Everything. A timeout, a 500, a 503 from "no routing engine could answer
      // right now", a decode failure, a client that is not initialised: all of
      // them mean the same thing to a rider looking at a map, which is draw the
      // straight line.
      return null;
    }
  }
}

/// Remembers the last route asked for, so a rebuild does not re-fetch it.
///
/// A screen that rebuilds on every GPS fix would otherwise put a routing request
/// on the wire once a second, against a service with no SLA. The key is the pair
/// of points, so re-asking the same question is free and moving either end is
/// not.
class RouteShapeCache {
  final Map<String, List<GeoPoint>> _shapes = {};

  /// The shape already fetched for [from]..[to], or null.
  List<GeoPoint>? shapeFor(GeoPoint? from, GeoPoint? to) {
    if (from == null || to == null) return null;
    return _shapes[_key(from, to)];
  }

  /// Remembers [shape] for [from]..[to].
  void remember(GeoPoint from, GeoPoint to, List<GeoPoint> shape) {
    if (shape.length < 2) return;
    _shapes[_key(from, to)] = shape;
    // Bounded, because this is a screen-lifetime cache and a rider who drags
    // their destination around a map would otherwise grow it without limit. Two
    // is enough for the pattern that exists: the previous destination and the
    // current one, so going back does not re-fetch.
    if (_shapes.length > 8) {
      _shapes.remove(_shapes.keys.first);
    }
  }

  String _key(GeoPoint from, GeoPoint to) =>
      '${from.lat.toStringAsFixed(5)},${from.lng.toStringAsFixed(5)}'
      '->${to.lat.toStringAsFixed(5)},${to.lng.toStringAsFixed(5)}';
}
