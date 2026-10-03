import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mng_core/mng_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'rider_route_service.dart';
import 'ride_map.dart';

/// Fetches the road between two points and hands it to a map builder.
///
/// ## Why this exists rather than a fetch inside [RideMap]
///
/// `RideMap` draws. It takes geometry and paints it, it has no network client, and
/// every test that exercises it does so without one. Giving it a service to call
/// would make each of those tests need a fake, for behaviour that has nothing to
/// do with drawing.
///
/// So the fetching lives here, in one place, and the map is built by a callback
/// that receives the shape. Three screens want this -- confirming a route,
/// watching a ride, looking at a finished one -- and none of them should each
/// remember to guard against a stale response.
///
/// ## What it does about the answers arriving out of order
///
/// A rider dragging their destination produces a request per drag, and they do not
/// come back in order. [_generation] counts requests and a response is dropped
/// unless it is still the newest. Without it the map ends up drawing the route to
/// where the destination *used* to be, which is worse than drawing no route: it
/// is confidently wrong, and it is wrong about the thing the rider is choosing.
///
/// ## What it does when routing fails
///
/// Draws the straight line and says nothing. See [RiderRouteService] for why
/// that is a `null` and not an exception: a map with an obvious straight line is
/// usable, a map with an error on it is not.
class RiderRouteMap extends StatefulWidget {
  const RiderRouteMap({
    super.key,
    required this.from,
    required this.to,
    required this.builder,
    this.service,
    this.cache,
  });

  /// Builds the map. [shape] is null until a road arrives, and stays null if none
  /// does -- which is the signal to draw the straight line.
  final Widget Function(BuildContext context, List<GeoPoint>? shape) builder;

  final GeoPoint from;
  final GeoPoint to;

  /// Injected so a test can answer without a network. Null uses a real one built
  /// from the Supabase client.
  final RiderRouteService? service;

  /// Shared across screens so re-opening a trip does not re-fetch it. Optional:
  /// without one, this widget simply has no cache.
  final RouteShapeCache? cache;

  @override
  State<RiderRouteMap> createState() => _RiderRouteMapState();
}

class _RiderRouteMapState extends State<RiderRouteMap> {
  /// Bumped per request. A response whose generation is not the current one is
  /// from a destination the rider has already moved on from.
  int _generation = 0;

  List<GeoPoint>? _shape;

  /// The key of the pair currently drawn or in flight, so `didUpdateWidget` can
  /// tell a new question from a rebuild of the same one.
  String? _askedFor;

  @override
  void initState() {
    super.initState();
    _askedFor = _key;
    unawaited(_load());
  }

  @override
  void didUpdateWidget(RiderRouteMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_key == _askedFor) return;
    // Clear first, so the straight line is on screen while the road is fetched
    // rather than the previous journey's road standing in for this one.
    setState(() {
      _askedFor = _key;
      _shape = null;
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    // Any response still in flight is discarded by the generation check, because
    // `setState` after dispose is the thing that would throw.
    _generation++;
    super.dispose();
  }

  String get _key =>
      '${widget.from.lat.toStringAsFixed(5)},${widget.from.lng.toStringAsFixed(5)}'
      '->${widget.to.lat.toStringAsFixed(5)},${widget.to.lng.toStringAsFixed(5)}';

  Future<void> _load() async {
    final cached = widget.cache?.shapeFor(widget.from, widget.to);
    if (cached != null) {
      setState(() => _shape = cached);
      return;
    }
    final generation = ++_generation;

    // Guarded here as well as inside the service, and the *service construction*
    // is inside the guard too.
    //
    // That is not tidiness. `Supabase.instance` throws when the app has not
    // initialised Supabase, which is true in every widget test and true in the
    // window before `main` finishes initialising. Built outside the `try`, that
    // one throw took down the whole tracking screen's test suite -- twenty-eight
    // tests about the ETA and the driver's name failing because of a line about
    // routing.
    //
    // [RiderRouteService] is written not to throw, so this is a second line of
    // defence rather than a contradiction of it: the wrapper's contract is "the
    // map keeps drawing", and it should not rest on every caller and every
    // implementation keeping a promise made on the wrapper's behalf.
    List<GeoPoint>? points;
    try {
      final service =
          widget.service ?? RiderRouteService(Supabase.instance.client);
      points = (await service.route(widget.from, widget.to))?.points;
    } catch (error) {
      // Reported, though it does not change what is drawn.
      //
      // The catch has to stay -- the map keeping drawing is the whole point --
      // but a silent catch is how a straight line reached a handset with no
      // explanation anywhere: the deployed function was answering 200 with 126
      // real geometry points while the app drew two pins and said nothing. If
      // this ever goes quiet again, `adb logcat` says why instead of the symptom
      // being a line that does not look like a road.
      debugPrint('RiderRouteMap: no road for $_key: $error');
      return;
    }
    // Dropped: this destination has been left behind, or the widget is gone.
    if (!mounted || generation != _generation) return;
    if (points == null || points.length < 2) {
      debugPrint(
        'RiderRouteMap: no usable geometry for $_key '
        '(${points?.length ?? 0} points)',
      );
      return;
    }
    debugPrint('RiderRouteMap: road for $_key is ${points.length} points');
    widget.cache?.remember(widget.from, widget.to, points);
    setState(() => _shape = points);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _shape);
}
