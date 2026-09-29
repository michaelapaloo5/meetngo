import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:mng_core/mng_core.dart';

import '../data/location_service.dart';

/// The free OpenStreetMap vector style this app draws from, via OpenFreeMap.
///
/// No key, no account, no card — the same constraint that ruled out Google Maps
/// rules out Mapbox, and this is what is left that still gives real 3D.
///
/// The style is chosen from measured responses, not from a list of names.
/// OpenFreeMap publishes several and they are not interchangeable for this
/// purpose: `liberty` is the only one carrying a `fill-extrusion` layer over
/// the `building` source-layer, which is where the 3D actually comes from.
/// `positron` and `bright` have **zero** fill-extrusion layers, so swapping to
/// either for taste would silently flatten the map back to 2D and nothing
/// would say so.
const kMapStyleUrl = 'https://tiles.openfreemap.org/styles/liberty';

/// The credit the OSM tile usage policy requires to be visible, matching
/// `kOsmAttribution` in the driver app's `DriverMapPanel`.
///
/// Still required, and still drawn by this file's own widget. MapLibre's own
/// attribution option is off (`logoEnabled` and the attribution toggle), because
/// MapLibre by default prints a Mapbox-branded badge, which would be a false
/// claim about who drew the map and is not this app's to display.
const kOsmAttribution = '© OpenStreetMap contributors';

/// How far the camera is tipped back from straight-down, in degrees.
///
/// This is the whole difference between a 2D map and a 3D one, and it is worth
/// stating why 45 and not 0. A tilt of 0 is a plan view: no buildings, no
/// perspective, nothing that reads as a city. MapLibre clamps tilt by zoom —
/// at low zoom there is nothing to extrude and a steep angle just smears the
/// tiles — so this is paired with a zoom that is high enough for the
/// `liberty` style's building layer to have data.
const double kRideMapTilt = 45.0;

/// A little rotation off north, so the map is not a grid.
///
/// Bearing 0 with a tilt is still recognisably a map; 20 degrees reads as a
/// view of a place. Combined with [kRideMapTilt] this is what makes the panel
/// look like a 3D city rather than a tilted rectangle.
const double kRideMapBearing = 20.0;

/// Zoom used when the map has a single point and no second point to fit to.
const double kRideMapSinglePointZoom = 14.0;

/// Above this, the two ends of a route are so close together that the pins
/// overlap and the rider cannot read either. Accra's Osu-to-Airport-Residential
/// demo route is about 2.4 km, which fits well inside it.
const double kRideMapRouteMaxZoom = 16.0;

/// A rider's ride drawn as a 3D city, on free OpenStreetMap vector tiles.
///
/// Replaces the flat `MngColors.muted` box that stood in for a map, and then a
/// 2D raster map that a rider rejected as not looking like the product. There is
/// no API key anywhere in this file, so a build with only the Supabase anon key
/// compiled in still gets a real map.
///
/// The camera is a [CameraPosition] rather than a fit-then-move: it carries a
/// `tilt` and a `bearing`, which is what makes the view three-dimensional, and
/// declaring it in the constructor means a rebuild re-frames correctly instead
/// of fighting whatever the rider did with their own gestures.
class RideMap extends StatefulWidget {
  const RideMap({
    super.key,
    required this.pickup,
    this.dropoff,
    this.location,
    this.height = 280,
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

  /// Replaces the live map engine with an inert stand-in, under test.
  ///
  /// A test seam, and the reason it is static rather than an argument: three
  /// screens build a [RideMap] inside their own layout, so threading a test-only
  /// parameter through all three would put test scaffolding in three production
  /// signatures.
  ///
  /// It is needed for a different reason than the old `flutter_map` seam was.
  /// `flutter_map` drew with Flutter widgets and only failed because it fetched
  /// tiles, so swapping the tile source was enough. MapLibre draws through a
  /// native view: under `flutter test` there is no platform view to create, so
  /// the widget cannot be built at all. The stand-in keeps every test that
  /// renders a screen working, and what it costs is stated plainly — the map's
  /// own drawing is no longer covered by the automated suite, only its framing
  /// and the layout around it. See `HANDOFF.md`.
  static bool disabledForTest = false;

  /// `(0, 0)` is in the Gulf of Guinea, which is not a mistake anyone makes
  /// when they are standing in Accra, and lat/lng of exactly zero is what a
  /// `request-ride` row with an unparsed pickup looks like. It is rejected
  /// rather than drawn, because a map centred on the Atlantic with a pin in
  /// it looks broken and the rider has no way to know it is their data.
  static bool isPlottable(GeoPoint p) {
    if (p.lat.abs() > 90 || p.lng.abs() > 180) return false;
    if (p.lat == 0 && p.lng == 0) return false;
    return true;
  }

  @override
  State<RideMap> createState() => _RideMapState();
}

class _RideMapState extends State<RideMap> {
  MapLibreMapController? _controller;

  /// Unique per instance. Two maps can be alive at once on the driver side, and
  /// MapLibre source and layer ids are global to a style, so a shared id would
  /// have one map's pins drawn onto the other.
  late final String _uid = 'ride-${identityHashCode(this)}';

  @override
  void dispose() {
    _controller = null;
    super.dispose();
  }

  /// Whether the sources exist yet, so an update cannot race the first load.
  bool _sourcesAdded = false;

  /// Pushes new geometry into sources that already exist.
  ///
  /// Same reason as the driver panel: sources can only be added once the style
  /// has loaded, so the overlays are created in `onStyleLoadedCallback` and
  /// refreshed from here. The rider's own dot is the one that moves -- the
  /// shell re-reads the position and rebuilds this widget with a new `here`.
  @override
  void didUpdateWidget(RideMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sourcesAdded) return;
    if (oldWidget.pickup == widget.pickup &&
        oldWidget.dropoff == widget.dropoff &&
        oldWidget.location?.point == widget.location?.point) {
      return;
    }
    _pushOverlays();
  }

  Future<void> _pushOverlays() async {
    final controller = _controller;
    if (controller == null) return;
    final from = widget.pickup != null && RideMap.isPlottable(widget.pickup!)
        ? widget.pickup
        : null;
    if (from == null) return;
    final to = widget.dropoff != null && RideMap.isPlottable(widget.dropoff!)
        ? widget.dropoff
        : null;
    if (to != null) {
      await controller.setGeoJsonSource(
        'route-src-$_uid',
        _lineGeoJson([from, to]),
      );
    }
    await controller.setGeoJsonSource(
      'pins-src-$_uid',
      _pinsGeoJson(<GeoPoint>[from, ?to, ?widget.location?.point]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final from =
        widget.pickup != null && RideMap.isPlottable(widget.pickup!)
            ? widget.pickup
            : null;
    final to = widget.dropoff != null && RideMap.isPlottable(widget.dropoff!)
        ? widget.dropoff
        : null;
    final here = widget.location?.point;
    final note = widget.location?.riderMessage ?? '';

    if (from == null) {
      return _Fallback(
        height: widget.height,
        message: 'The pickup point for this ride is not known yet',
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(MngRadius.large),
      child: SizedBox(
        height: widget.height,
        child: Stack(
          children: [
            Positioned.fill(
              child: RideMap.disabledForTest
                  ? _MapStandIn()
                  : _buildMap(from: from, to: to, here: here),
            ),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _Attribution(),
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

  Widget _buildMap({
    required GeoPoint from,
    required GeoPoint? to,
    required GeoPoint? here,
  }) {
    // `?` rather than `if (x != null) x`: same order, same list, and the
    // analyzer's `use_null_aware_elements` is an error under --fatal-infos.
    final points = <GeoPoint>[from, ?to, ?here];
    // A route needs two ends; the single-point case is the finding screen.
    final hasRoute = to != null;

    return MapLibreMap(
      key: const Key('rideMap'),
      styleString: kMapStyleUrl,
      initialCameraPosition: CameraPosition(
        target: _ll(from),
        zoom: hasRoute ? kRideMapRouteMaxZoom : kRideMapSinglePointZoom,
        tilt: kRideMapTilt,
        bearing: kRideMapBearing,
      ),
      // A rider is not given the map to drag. Leaving the gestures on means a
      // vertical drag on the map scrolls nothing and eats the scroll of the
      // screen behind it, and a rider who has found the pickup and been
      // scrolled away from it is worse off than one who cannot move it.
      scrollGesturesEnabled: false,
      zoomGesturesEnabled: false,
      rotateGesturesEnabled: false,
      tiltGesturesEnabled: false,
      // No Mapbox badge: this map is OpenStreetMap's data, drawn by MapLibre,
      // and a Mapbox logo on it would be a false claim about who did the work.
      // MapLibre still draws its own small attribution *button*, which it does
      // not offer a way to switch off; that is a MapLibre control rather than a
      // vendor claim, and the visible credit below is what satisfies the OSM
      // tile usage policy.
      logoEnabled: false,
      onMapCreated: (controller) => _controller = controller,
      // Layers can only be added once the style is loaded, so this is where the
      // route and the pins go. The camera is already placed by
      // `initialCameraPosition`, so nothing has to be moved here.
      onStyleLoadedCallback: () => _addOverlays(points, hasRoute: hasRoute),
    );
  }

  Future<void> _addOverlays(
    List<GeoPoint> points, {
    required bool hasRoute,
  }) async {
    final controller = _controller;
    if (controller == null) return;

    if (hasRoute && points.length >= 2) {
      await controller.addGeoJsonSource(
        'route-src-$_uid',
        _lineGeoJson(points.take(2).toList()),
      );
      await controller.addLineLayer(
        'route-src-$_uid',
        'route-line-$_uid',
        LineLayerProperties(
          lineColor: _css(MngColors.info),
          lineWidth: 5,
          // `dynamic` in the plugin, so these are the style's own string
          // values rather than an enum from this package.
          lineCap: 'round',
          lineJoin: 'round',
          // A white casing under the line so it stays readable over both pale
          // city blocks and dark parkland, which is what the 2D map's border
          // stroke was for.
          lineGapWidth: 2,
        ),
        // Deliberately no `belowLayerId`. The `liberty` style has both a 2D
        // `building` layer and a `building-3d` extrusion, so anchoring the route
        // under either one puts it *behind* the extrusions -- and on a tilted
        // camera that means the rider's own route disappears behind the city
        // it runs through. A route is drawn on top of everything, as it is in
        // every map app worth copying.
      );
    }

    await controller.addGeoJsonSource('pins-src-$_uid', _pinsGeoJson(points));
    await controller.addCircleLayer(
      'pins-src-$_uid',
      'pin-halo-$_uid',
      CircleLayerProperties(
        circleRadius: 9,
        circleColor: _css(MngColors.page),
      ),
    );
    await controller.addCircleLayer(
      'pins-src-$_uid',
      'pin-core-$_uid',
      CircleLayerProperties(
        circleRadius: 6,
        circleColor: _css(MngColors.primary),
      ),
      // One layer per pin colour, picked by a feature property, so the pickup,
      // the dropoff and the rider's own dot are told apart at a glance. The
      // filter is a raw style expression -- the plugin types it as `dynamic` and
      // its own tests pass the bare list.
      filter: _roleIs('pickup'),
    );
    await controller.addCircleLayer(
      'pins-src-$_uid',
      'dropoff-core-$_uid',
      CircleLayerProperties(
        circleRadius: 6,
        circleColor: _css(MngColors.error),
      ),
      filter: _roleIs('dropoff'),
    );
    await controller.addCircleLayer(
      'pins-src-$_uid',
      'device-core-$_uid',
      CircleLayerProperties(
        circleRadius: 5,
        circleColor: _css(MngColors.info),
      ),
      filter: _roleIs('device'),
    );

    // Set last, once every source is in place, so `didUpdateWidget` can never
    // call `setGeoJsonSource` against a source that has not been added yet.
    _sourcesAdded = true;
  }

  /// A route as one GeoJSON `LineString`.
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

  /// The pins as one GeoJSON `MultiPoint`, tagged with a `role` so one source
  /// feeds three colour layers.
  Map<String, dynamic> _pinsGeoJson(List<GeoPoint> points) => {
        'type': 'FeatureCollection',
        'features': [
          for (final entry in _pinRoles(points).entries)
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

  /// Which pin is which, in the order they are drawn.
  ///
  /// A `Map` so the ordering is the insertion order: pickup, then dropoff, then
  /// the device. GeoJSON is built from this, and a `HashMap` would make the
  /// feature order arbitrary.
  Map<String, GeoPoint> _pinRoles(List<GeoPoint> points) {
    final roles = <String, GeoPoint>{};
    if (points.isNotEmpty) roles['pickup'] = points[0];
    if (points.length > 1) roles['dropoff'] = points[1];
    if (points.length > 2) roles['device'] = points[2];
    return roles;
  }

  /// A style filter matching features whose `role` property is [role].
  ///
  /// Written once because the plugin's `filter` is `dynamic` and has no helper
  /// type for it: the expression is a bare list, and three hand-written copies
  /// of `['==', ['get', 'role'], ...]` is three chances to mistype the property
  /// name. A pin that silently loses its filter would render in the pickup's
  /// colour, which is exactly the kind of wrong-but-plausible map this file has
  /// already had one of.
  static List<dynamic> _roleIs(String role) => ['==', ['get', 'role'], role];

  /// MapLibre takes colours as CSS strings, not `Color`, and it does not accept
  /// Flutter's `Color.toARGB32()` output for every channel order — so the hex
  /// is built here rather than with a `toString()` that happens to work.
  static String _css(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  static LatLng _ll(GeoPoint p) => LatLng(p.lat, p.lng);
}

/// The visible OpenStreetMap credit, over the bottom-left of the map.
///
/// A `Text` rather than a `Row`, so it wraps instead of overflowing: the map
/// panel is as narrow as the screen allows, and a fixed-width credit at a large
/// text scale is what pushed a previous attribution off the edge.
class _Attribution extends StatelessWidget {
  const _Attribution();

  @override
  Widget build(BuildContext context) {
    // The `Positioned` that holds this spans the map's width, which is what
    // gives the `Text` a finite constraint to wrap against. `Align` then pulls
    // the strip back to the width the credit actually needs, so the backing
    // panel does not become a full-width bar across the map.
    return Align(
      alignment: Alignment.bottomLeft,
      child: DecoratedBox(
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
      ),
    );
  }
}

/// Stands in for the native map under test.
///
/// Deliberately an empty tinted box and nothing else: a stand-in that drew
/// pins and a route would let a test assert on its own fiction, which is how a
/// test suite comes to believe a map is covered when it is not.
class _MapStandIn extends StatelessWidget {
  @override
  Widget build(BuildContext context) => const ColoredBox(
        key: Key('rideMapStandIn'),
        color: MngColors.muted,
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
