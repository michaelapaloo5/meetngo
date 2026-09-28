import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:latlong2/latlong.dart';
import 'package:mng_core/mng_core.dart';

import '../data/location_service.dart';

/// The OpenStreetMap raster tile template this app draws from.
///
/// OpenStreetMap is a deliberate choice, not a default one: its tile servers
/// need no API key, no account and no billing, and this project has none of
/// those. The trade is the [OSM tile usage policy](https://operations.osmfoundation.org/policies/tiles/)
/// — a bulk or offline download of these tiles is not allowed, and a
/// production app would move to a paid or self-hosted provider at scale. For a
/// pilot's worth of tile requests it is the right side of that trade.
const kOsmTileUrlTemplate = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

/// Passed to the tile layer so the server sees which app is asking. OSM's
/// policy asks for an identifying User-Agent, and an unidentifiable one is
/// exactly what that policy is written about.
const kOsmUserAgentPackageName = 'com.meetngo.rider';

/// Zoom used when the map has a single point and no second point to fit to.
const double kRideMapSinglePointZoom = 14.0;

/// Above this, the two ends of a route are so close together that the pins
/// overlap and the rider cannot read either. Accra's Osu-to-Airport-Residential
/// demo route is about 2.4 km, which fits well inside it.
const double kRideMapRouteMaxZoom = 16.0;

/// A rider's ride drawn on real OpenStreetMap tiles.
///
/// Replaces the flat `MngColors.muted` box that stood in for a map on
/// [TrackingScreen] and [FindingDriverScreen]. There is no API key anywhere in
/// this file and nothing to configure per environment, which is what makes the
/// map work on a build with only the Supabase anon key compiled in.
///
/// The camera is placed with [MapOptions.initialCameraFit] rather than a
/// `MapController.move` in `initState`. A controller needs a `camera` to be
/// ready, and moving before the first layout throws; a declarative initial fit
/// cannot be called too early, and it also means a rebuilt widget re-fits
/// instead of fighting the rider's own panning.
class RideMap extends StatelessWidget {
  const RideMap({
    super.key,
    required this.pickup,
    this.dropoff,
    this.location,
    this.height = 280,
    this.tileProvider,
  });

  /// Where the rider is being collected. A trip row always carries one, but it
  /// is not trusted to be a coordinate the map can draw — see [_isPlottable].
  final GeoPoint? pickup;

  /// Where the rider is going. Null renders a single-point map, which is what
  /// the finding-a-driver screen wants: there is no dropoff to show yet.
  final GeoPoint? dropoff;

  /// The device fix, when there is one. Drawn as a separate dot and paired
  /// with [DeviceLocation.riderMessage] so a rider who refused location is told
  /// so on the same screen rather than being left to wonder why the map is
  /// somewhere else.
  final DeviceLocation? location;

  final double height;

  /// Swapped for a silent provider under test, where every real tile request
  /// would go to the network and fail.
  final TileProvider? tileProvider;

  /// `(0, 0)` is in the Gulf of Guinea, which is not a mistake anyone makes
  /// when they are standing in Accra, and lat/lng of exactly zero is what a
  /// `request-ride` row with an unparsed pickup looks like. It is rejected
  /// rather than drawn, because a map centred on the Atlantic with a pin in
  /// it looks broken and the rider has no way to know it is their data.
  static bool _isPlottable(GeoPoint p) {
    if (p.lat.abs() > 90 || p.lng.abs() > 180) return false;
    if (p.lat == 0 && p.lng == 0) return false;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final from = pickup != null && _isPlottable(pickup!) ? pickup : null;
    final to = dropoff != null && _isPlottable(dropoff!) ? dropoff : null;
    final here = location != null && location!.point != null
        ? location!.point
        : null;
    final note = location?.riderMessage ?? '';

    if (from == null) {
      return _Fallback(
        height: height,
        message: 'The pickup point for this ride is not known yet',
      );
    }

    final route = to == null ? null : <GeoPoint>[from, to];
    final bounds = route == null ? null : LatLngBounds.fromPoints(_ll(route));
    // The "you are here" dot joins the fit so a rider who is a long way from
    // their own pickup is not shown a map that is entirely their pickup.
    final fitPoints = <LatLng>[
      ..._ll(route ?? [from]),
      if (here != null) _one(here),
    ];

    return ClipRRect(
      borderRadius: BorderRadius.circular(MngRadius.large),
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            FlutterMap(
              key: const Key('rideMap'),
              options: MapOptions(
                initialCenter: _one(from),
                initialZoom: kRideMapSinglePointZoom,
                initialCameraFit: bounds == null
                    ? null
                    : CameraFit.bounds(
                        bounds: LatLngBounds.fromPoints(fitPoints),
                        padding: const EdgeInsets.all(28),
                        maxZoom: kRideMapRouteMaxZoom,
                      ),
                // A driver moving the map is not something this app offers, and
                // leaving the gestures on means a vertical drag on the map
                // scrolls nothing and eats the scroll of the screen behind it.
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.none,
                ),
              ),
              children: [
                TileLayer(
                  urlTemplate: kOsmTileUrlTemplate,
                  userAgentPackageName: kOsmUserAgentPackageName,
                  tileProvider: tileProvider,
                ),
                if (route != null)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _ll(route),
                        strokeWidth: 4,
                        color: MngColors.info,
                        borderStrokeWidth: 1,
                        borderColor: MngColors.page,
                      ),
                    ],
                  ),
                MarkerLayer(
                  markers: [
                    Marker(
                      key: const Key('pickupPin'),
                      point: _one(from),
                      width: 28,
                      height: 28,
                      child: const _Pin(color: MngColors.success),
                    ),
                    if (to != null)
                      Marker(
                        key: const Key('dropoffPin'),
                        point: _one(to),
                        width: 28,
                        height: 28,
                        child: const _Pin(color: MngColors.error),
                      ),
                    if (here != null)
                      Marker(
                        key: const Key('devicePin'),
                        point: _one(here),
                        width: 18,
                        height: 18,
                        child: const _Pin(
                          color: MngColors.info,
                          bordered: true,
                        ),
                      ),
                  ],
                ),
                // The attribution the OSM tile usage policy requires. Rendered
                // as `SimpleAttributionWidget` rather than the collapsible
                // `RichAttributionWidget` because the simple one always shows
                // its text, and an attribution behind a tap-to-open affordance
                // is not a visible attribution.
                const SimpleAttributionWidget(
                  source: Text('OpenStreetMap contributors'),
                ),
              ],
            ),
            if (note.isNotEmpty)
              Positioned(
                left: 8,
                right: 8,
                top: 8,
                child: _LocationNote(message: note),
              ),
          ],
        ),
      ),
    );
  }

  static LatLng _one(GeoPoint p) => LatLng(p.lat, p.lng);

  static List<LatLng> _ll(List<GeoPoint> points) =>
      points.map(_one).toList(growable: false);
}

/// The end of the route, drawn as a filled circle inside a white ring so it
/// stays readable on top of both pale city blocks and dark parkland.
class _Pin extends StatelessWidget {
  const _Pin({required this.color, this.bordered = false});

  final Color color;
  final bool bordered;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: bordered
              ? Border.all(color: MngColors.page, width: 3)
              : Border.all(color: MngColors.page, width: 2),
        ),
      );
}

/// The rider-facing consequence of not having a fix, over the top of the map.
class _LocationNote extends StatelessWidget {
  const _LocationNote({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('locationNote'),
      padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 8.h),
      decoration: BoxDecoration(
        color: MngColors.page.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(MngRadius.small),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.location_off_outlined, size: 16),
          SizedBox(width: 8.w),
          Expanded(
            child: Text(
              message,
              style: MngTheme.light.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// What the map shows when it has nothing it can honestly draw.
class _Fallback extends StatelessWidget {
  const _Fallback({required this.height, required this.message});

  final double height;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('mapFallback'),
      height: height,
      decoration: BoxDecoration(
        color: MngColors.muted,
        borderRadius: BorderRadius.circular(MngRadius.large),
      ),
      alignment: Alignment.center,
      padding: EdgeInsets.symmetric(horizontal: 24.w),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.map_outlined, size: 32, color: MngColors.textSub),
          SizedBox(height: 8.h),
          Text(
            message,
            textAlign: TextAlign.center,
            style: MngTheme.light.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
