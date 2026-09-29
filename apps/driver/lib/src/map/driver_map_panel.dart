import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:mng_core/mng_core.dart';

/// The free OpenStreetMap vector style, via OpenFreeMap. No key, no account,
/// no card.
///
/// Google Maps needs an API key whose Maps SDK for Android is billed to a card,
/// and this pilot has no card, so a `google_maps_flutter` build could not be
/// pointed at a project at all. Mapbox has the same problem past its free tier.
/// MapLibre plus OpenFreeMap is what is left that still draws real 3D, and
/// unlike the raster tiles it replaced it carries building geometry rather than
/// pre-rendered pixels, which is what makes the tilt below worth having.
///
/// `liberty` specifically: measured against the three styles OpenFreeMap
/// publishes, it is the only one with a `fill-extrusion` layer over the
/// `building` source-layer. `positron` and `bright` have none, so choosing
/// either would silently flatten the map to 2D.
///
/// The OSM tile usage policy still requires visible attribution, and
/// [kOsmAttribution] is on the map at all times rather than behind a tap.
const kOsmStyleUrl = 'https://tiles.openfreemap.org/styles/liberty';

const kOsmAttribution = '© OpenStreetMap contributors';

/// Camera tilt, in degrees. The whole difference between a 2D map and a 3D one.
const double kDriverMapTilt = 50.0;

/// Rotation off north, so the view reads as a place rather than a grid.
const double kDriverMapBearing = 20.0;

/// The map, drawn for the driver, in 3D.
///
/// OpenStreetMap vector tiles through MapLibre, with the driver's own position,
/// the pickup and -- when the trip has a leg to draw -- a line between them. It
/// takes the three points as arguments rather than reaching for a controller,
/// so the map is a view and not a place with rules in it: every rule about what
/// to do when there is no fix lives in `LocationController`, and this widget's
/// only job is to never render a blank rectangle. A caller with nothing to show
/// gets a labelled, tinted panel that says so.
///
/// Unlike the rider's map, this one leaves the gestures on. A driver following
/// a route is the one place in this app where moving the map is the point, and
/// the panel is not inside a scroll view, so a drag here is not eating anyone's
/// scroll.
class DriverMapPanel extends StatefulWidget {
  const DriverMapPanel({
    super.key,
    this.driverPoint,
    this.pickup,
    this.dropoff,
    this.height = 220,
    this.drawRoute = true,
  });

  /// Where the driver is, or null when there is no fix.
  final GeoPoint? driverPoint;

  /// Where the trip starts. Null on the offer queue, where the driver is
  /// choosing between several trips and one pin would be a lie.
  final GeoPoint? pickup;

  /// Where the trip ends.
  final GeoPoint? dropoff;

  final double height;

  /// Whether to draw a line between the points. Off on the offer queue: a line
  /// to a pickup that has not been accepted is a route the driver is not on.
  final bool drawRoute;

  /// Replaces the live map engine with an inert stand-in, under test.
  ///
  /// A test seam, and static rather than an argument because `ActiveTripScreen`
  /// and `DriverHomeScreen` both render this panel from their own layouts.
  ///
  /// Needed for a stronger reason than the old `flutter_map` seam was: that
  /// engine drew with Flutter widgets and only failed because it fetched tiles,
  /// so swapping the tile source was enough. MapLibre draws through a native
  /// view, and under `flutter test` there is no platform view to create, so the
  /// widget cannot be built at all.
  static bool disabledForTest = false;

  @override
  State<DriverMapPanel> createState() => _DriverMapPanelState();
}

class _DriverMapPanelState extends State<DriverMapPanel> {
  MapLibreMapController? _controller;

  /// Unique per instance: the offer queue and the live trip each build a panel,
  /// and MapLibre source and layer ids are global to a style.
  late final String _uid = 'driver-${identityHashCode(this)}';

  @override
  void dispose() {
    _controller = null;
    super.dispose();
  }

  /// Every point worth placing the camera over, in order.
  List<GeoPoint> get _points => [
        if (widget.driverPoint != null) widget.driverPoint!,
        if (widget.pickup != null) widget.pickup!,
        if (widget.dropoff != null) widget.dropoff!,
      ];

  /// The line to draw, if there is one worth drawing.
  ///
  /// Driver to pickup while collecting, pickup to dropoff once the rider is
  /// aboard, and a single leg rather than two once both ends are known: drawing
  /// both would put a segment through the pickup pin and make the route look
  /// like it doubles back.
  List<GeoPoint>? get _route {
    if (!widget.drawRoute) return null;
    if (widget.driverPoint != null && widget.pickup != null) {
      return [widget.driverPoint!, widget.pickup!];
    }
    if (widget.pickup != null && widget.dropoff != null) {
      return [widget.pickup!, widget.dropoff!];
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final points = _points;
    return SizedBox(
      height: widget.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(MngRadius.large),
        child: DecoratedBox(
          decoration: const BoxDecoration(color: MngColors.muted),
          child: points.isEmpty
              ? const _NoLocationYet()
              : Stack(
                  children: [
                    Positioned.fill(
                      child: DriverMapPanel.disabledForTest
                          ? const _MapStandIn()
                          : _buildMap(points),
                    ),
                    const Positioned(
                      left: 0,
                      bottom: 0,
                      child: _Attribution(),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildMap(List<GeoPoint> points) {
    final route = _route;
    return MapLibreMap(
      key: const Key('driverMap'),
      styleString: kOsmStyleUrl,
      initialCameraPosition: CameraPosition(
        target: _ll(points.first),
        zoom: 14,
        tilt: kDriverMapTilt,
        bearing: kDriverMapBearing,
      ),
      // Gestures stay on for the driver: this panel is not in a scroll view,
      // and a driver following a route needs to be able to look around. Tilt
      // and rotate are both on, so the 3D is something they can adjust rather
      // than a fixed camera.
      //
      // No Mapbox logo: the data is OpenStreetMap's, drawn by MapLibre.
      logoEnabled: false,
      onMapCreated: (controller) => _controller = controller,
      onStyleLoadedCallback: () => _addOverlays(points, route),
    );
  }

  Future<void> _addOverlays(List<GeoPoint> points, List<GeoPoint>? route) async {
    final controller = _controller;
    if (controller == null) return;

    if (route != null && route.length >= 2) {
      await controller.addGeoJsonSource('route-src-$_uid', _lineGeoJson(route));
      await controller.addLineLayer(
        'route-src-$_uid',
        'route-line-$_uid',
        LineLayerProperties(
          lineColor: _css(MngColors.primary),
          lineWidth: 5,
          lineCap: 'round',
          lineJoin: 'round',
          // A pale casing so the route stays readable over dark parkland as
          // well as pale blocks.
          lineGapWidth: 2,
        ),
      );
    }

    await controller.addGeoJsonSource('pins-src-$_uid', _pinsGeoJson(points));
    // A white ring under every pin, so a pin reads against any background.
    await controller.addCircleLayer(
      'pins-src-$_uid',
      'pin-halo-$_uid',
      CircleLayerProperties(
        circleRadius: 9,
        circleColor: _css(MngColors.onPrimary),
      ),
    );
    for (final role in const ['driver', 'pickup', 'dropoff']) {
      await controller.addCircleLayer(
        'pins-src-$_uid',
        '$role-core-$_uid',
        CircleLayerProperties(
          // The rider's own dot is smaller: it is context for the pickup, not
          // the thing being looked at.
          circleRadius: role == 'driver' ? 5 : 6,
          circleColor: _css(_roleColor(role)),
        ),
        filter: _roleIs(role),
      );
    }
  }

  /// The colour each role is drawn in, matching what the 2D map used.
  static Color _roleColor(String role) => switch (role) {
        'driver' => MngColors.info,
        'pickup' => MngColors.primary,
        _ => MngColors.success,
      };

  Map<String, dynamic> _lineGeoJson(List<GeoPoint> points) => {
        'type': 'Feature',
        'properties': <String, dynamic>{},
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            for (final p in points) [p.lng, p.lat],
          ],
        },
      };

  Map<String, dynamic> _pinsGeoJson(List<GeoPoint> points) => {
        'type': 'FeatureCollection',
        'features': [
          for (final entry in _roles(points).entries)
            {
              'type': 'Feature',
              'properties': {'role': entry.key},
              'geometry': {
                'type': 'Point',
                'coordinates': [entry.value.lng, entry.value.lat],
              },
            },
        ],
      };

  /// Which point is which, in draw order.
  Map<String, GeoPoint> _roles(List<GeoPoint> points) {
    final roles = <String, GeoPoint>{};
    if (points.isNotEmpty) roles['driver'] = points[0];
    if (points.length > 1) roles['pickup'] = points[1];
    if (points.length > 2) roles['dropoff'] = points[2];
    return roles;
  }

  /// A style filter matching features whose `role` is [role]. The plugin types
  /// `filter` as `dynamic` and has no helper for it, so the expression is built
  /// once here rather than hand-written at each call site.
  static List<dynamic> _roleIs(String role) => ['==', ['get', 'role'], role];

  /// MapLibre takes CSS colour strings rather than `Color`.
  static String _css(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  static LatLng _ll(GeoPoint p) => LatLng(p.lat, p.lng);
}

/// `mng_core` keeps its own [GeoPoint] so the shared package does not have to
/// depend on `maplibre_gl`. The conversion happens here, at the widget edge, and
/// nowhere else: a `LatLng` escaping into a controller would be a second
/// coordinate type for the same two numbers.

/// Stands in for the native map under test. Deliberately an empty tinted box:
/// a stand-in that drew pins would let a test assert on its own fiction.
class _MapStandIn extends StatelessWidget {
  const _MapStandIn();

  @override
  Widget build(BuildContext context) => const ColoredBox(
        key: Key('driverMapStandIn'),
        color: MngColors.muted,
      );
}

/// The visible OpenStreetMap credit the tile usage policy requires.
class _Attribution extends StatelessWidget {
  const _Attribution();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: MngColors.surface),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Text(
          kOsmAttribution,
          key: const Key('osmAttribution'),
          softWrap: true,
          style: const TextStyle(fontSize: 10, color: MngColors.textSub),
        ),
      ),
    );
  }
}

/// What the map area says when there is no position to draw.
///
/// Never an empty panel: a driver who is offline, refused, or still waiting for
/// a satellite needs to read which of those it is, and a blank grey rectangle
/// tells them nothing and looks like a broken build.
class _NoLocationYet extends StatelessWidget {
  const _NoLocationYet();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 20.w),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.location_off_outlined,
              size: 28,
              color: MngColors.textSub,
            ),
            SizedBox(height: 8.h),
            const Text(
              'No location to show yet',
              key: Key('mapNoLocation'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: MngColors.textSub),
            ),
            const Text(
              kOsmAttribution,
              key: Key('osmAttribution'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10, color: MngColors.textSub),
            ),
          ],
        ),
      ),
    );
  }
}
