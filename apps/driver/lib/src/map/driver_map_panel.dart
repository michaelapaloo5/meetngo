import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:mng_core/mng_core.dart';

/// The bundled map style, shared with the rider app.
///
/// Was a remote style URL, and moving it into the app's own assets is a
/// deliberate change: a remote style is a remote dependency on somebody else's
/// taste, which can be repainted overnight, can lose a layer this app depends
/// on, and is not reviewable in a diff. Shipping the JSON means the map's whole
/// appearance is a file in this repository.
///
/// `mng_core` also fixes the palette the rider app's overlays are matched to.
/// Two apps that draw the same streets in two different greys are visibly two
/// different products, and neither is a decision anybody made.
///
/// OpenStreetMap vector tiles through MapLibre, with no API key, no account
/// and no card. Google Maps needs a key whose Maps SDK for Android is billed to
/// a card, and this pilot has no card; Mapbox has the same problem past its
/// free tier. MapLibre plus OpenFreeMap is what is left that still draws real
/// 3D, and unlike the raster tiles it replaced it carries building geometry
/// rather than pre-rendered pixels, which is what makes the tilt below worth
/// having.
///
/// The OSM tile usage policy still requires visible attribution, and
/// [kOsmAttribution] is on the map at all times rather than behind a tap.
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
    this.driverHeading,
    this.pickup,
    this.dropoff,
    this.height = 220,
    this.drawRoute = true,
    this.routeGeometry,
    this.startFollowing,
  });

  /// Where the driver is, or null when there is no fix.
  final GeoPoint? driverPoint;

  /// Which way the driver is facing, degrees clockwise from north, or null.
  ///
  /// Separate from [driverPoint] because the two are independently available:
  /// a phone in a car park has a position and often no compass. A null heading
  /// draws no car rather than one pointing north, because on the driver's own
  /// map a car pointing the wrong way is a thing they would act on.
  final double? driverHeading;

  /// Where the trip starts. Null on the offer queue, where the driver is
  /// choosing between several trips and one pin would be a lie.
  final GeoPoint? pickup;

  /// Where the trip ends.
  final GeoPoint? dropoff;

  final double height;

  /// Whether to draw a line between the points. Off on the offer queue: a line
  /// to a pickup that has not been accepted is a route the driver is not on.
  final bool drawRoute;

  /// The route to draw, as the routing engine returned it.
  ///
  /// Optional and preferred over [drawRoute]'s two-point fallback, because a line
  /// from the driver to the pickup crosses buildings. A navigator that draws a
  /// straight line and tells the driver to follow it is worse than one that draws
  /// nothing, so this is the whole of what "navigate" means visually.
  final List<GeoPoint>? routeGeometry;

  /// Seeds whether the camera starts out following the driver.
  ///
  /// Test-only, and null in every real call so the behaviour is simply "follow".
  /// It exists because the thing that *stops* following is `onCameraIdle`, and
  /// MapLibre draws through a native view: under `flutter test` there is no
  /// platform view, so that callback can never fire and the recentre button could
  /// never be rendered by a test at all. Null means "not specified", which is not
  /// the same as true.
  @visibleForTesting
  final bool? startFollowing;

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
  /// Whether a camera that has come to rest at [cameraTarget] is still framing the
  /// driver at [driver].
  ///
  /// Static and public rather than private state, because MapLibre draws through a
  /// native view and `onCameraIdle` can therefore never fire under `flutter test`.
  /// The rule this decides -- does the app take the camera away from a driver who
  /// deliberately moved it -- is the whole behaviour, and it was untestable while
  /// it lived on the State.
  ///
  /// The threshold is the distance the camera may settle from the driver and still
  /// count as following: generous enough that GPS noise and a pinch while
  /// stationary do not switch it off, small enough that a deliberate pan does. At
  /// the zoom this panel opens at, 150 m is about a sixth of the way across the
  /// screen, so the driver is still comfortably in frame that far out -- losing
  /// follow at that distance means somebody meant to move it.
  static const double followSlackKm = 0.15;

  static bool stillFollowing({
    required GeoPoint cameraTarget,
    required GeoPoint driver,
  }) => cameraTarget.distanceKmTo(driver) <= followSlackKm;

  static bool disabledForTest = false;

  @override
  State<DriverMapPanel> createState() => _DriverMapPanelState();
}

class _DriverMapPanelState extends State<DriverMapPanel> {
  MapLibreMapController? _controller;

  /// The bundled style's text, loaded once and cached across instances.
  ///
  /// `styleString` is a plain `String` and the style lives in the asset bundle,
  /// so it has to be read before the map is built. A `FutureBuilder` would
  /// throw the camera away and rebuild the map the moment it arrived; a
  /// placeholder for the frame or two it takes is better than a flash of
  /// blank map.
  static String? _styleText;

  /// Unique per instance: the offer queue and the live trip each build a panel,
  /// and MapLibre source and layer ids are global to a style.
  late final String _uid = 'driver-${identityHashCode(this)}';

  @override
  void initState() {
    super.initState();
    if (widget.startFollowing == false) _following = false;
    if (_styleText == null) {
      // A failure leaves `_styleText` null and the build below shows the
      // "no location yet" panel rather than a silently blank rectangle.
      premiumMapStyleJson().then((text) {
        _styleText = text;
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _controller = null;
    super.dispose();
  }

  /// Whether the sources exist yet, so an update cannot race the first load.
  bool _sourcesAdded = false;

  /// Pushes new geometry into sources that already exist.
  ///
  /// The overlays are created once, in `onStyleLoadedCallback`, because a
  /// MapLibre source cannot be added before the style has loaded. But the
  /// driver's own position changes every few seconds -- `LocationController`
  /// streams it and this panel is rebuilt with a new `driverPoint` each time --
  /// so creating them once and never touching them again would leave the blue
  /// dot frozen wherever the driver was when the map loaded. A live map whose
  /// dot does not move is worse than no map at all.
  ///
  /// `setGeoJsonSource` is the update counterpart of `addGeoJsonSource`: the
  /// same id with new data and no layer churn. Guarded on [_sourcesAdded],
  /// because calling it before the style has loaded targets a source that does
  /// not exist yet.
  @override
  void didUpdateWidget(DriverMapPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sourcesAdded) return;
    if (oldWidget.driverPoint == widget.driverPoint &&
        // The heading changes while the position stands still: a driver at a
        // set of lights turns on the spot, and a gate that ignored it would
        // leave their car pointing the way they were facing when they arrived.
        oldWidget.driverHeading == widget.driverHeading &&
        oldWidget.pickup == widget.pickup &&
        oldWidget.dropoff == widget.dropoff &&
        oldWidget.drawRoute == widget.drawRoute &&
        // The geometry is compared too, and it is the most important line in this
        // gate. A re-routed trip hands the panel a whole new list of several
        // hundred points, and without this the map keeps drawing the route the
        // driver was on before they left it -- which is the one thing a navigator
        // must never show. Compared by length and by element, not by identity,
        // because `progressOn` builds a fresh list on every tick.
        _sameGeometry(oldWidget.routeGeometry, widget.routeGeometry)) {
      return;
    }
    _pushOverlays();
  }

  /// Whether two geometries are the same line.
  ///
  /// By value, and tolerating either side being null. The panel re-renders on every
  /// position fix, so this runs a few hundred times a minute and comparing a list
  /// of `GeoPoint`s is cheaper than redrawing a `LineLayer`.
  static bool _sameGeometry(List<GeoPoint>? a, List<GeoPoint>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _pushOverlays() async {
    final controller = _controller;
    if (controller == null) return;
    final route = _route;
    if (route != null && route.length >= 2) {
      await controller.setGeoJsonSource('route-src-$_uid', _lineGeoJson(route));
    }
    await controller.setGeoJsonSource('pins-src-$_uid', _pinsGeoJson(_points));
    await _pushVehicle(controller);
    // Follow, if still following. This is the whole reason the camera moves: a
    // marker that walks off the top of a fixed frame is a map with no driver on
    // it, which is the thing this was all for.
    if (_following) _cameraOnDriver();
  }

  /// Every point worth placing the camera over, in order.
  ///
  /// The driver's own position is included so the camera frames it, but it is
  /// not tagged with a `role` and so is not drawn as a circle -- see
  /// [_pushVehicle], which draws it as a rotated car instead.
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
    // Real geometry first. A navigated route is the engine's polyline, which is
    // hundreds of points along actual roads; the two-point line below is only for
    // a trip that has no route fetched yet.
    if (!widget.drawRoute) return null;
    final geometry = widget.routeGeometry;
    if (geometry != null && geometry.length >= 2) return geometry;
    if (widget.driverPoint != null && widget.pickup != null) {
      return [widget.driverPoint!, widget.pickup!];
    }
    if (widget.pickup != null && widget.dropoff != null) {
      return [widget.pickup!, widget.dropoff!];
    }
    return null;
  }

  /// Whether the camera is following the driver.
  ///
  /// True until the driver moves the camera themselves, and the driver can put it
  /// back with the recentre button.
  ///
  /// The choice asked for explicitly: following while navigating and stopping the
  /// moment the driver looks somewhere else. A camera that keeps yanking back is
  /// worse than one that stays put, and "where am I" is only useful if there is a
  /// way to answer it after deliberately looking away.
  ///
  /// "Touched the map" is worked out from where the camera came to rest rather than
  /// from a gesture callback: MapLibre 0.27 exposes no public gesture-start event,
  /// and its `onCameraMove` fires for the panel's own animations too, so
  /// distinguishing the two would mean inferring intent from timing. If the camera
  /// settles somewhere that is not framing the driver, the driver moved it.
  bool _following = true;

  bool get following => _following;


  /// Re-centre on the driver and resume following.
  void recentre() {
    setState(() => _following = true);
    _cameraOnDriver();
  }

  /// Puts the camera on the driver, keeping whatever zoom, tilt and bearing they
  /// have chosen.
  ///
  /// Zoom, tilt and bearing are read back rather than set to constants, so
  /// following does not undo a driver who has pitched the map or spun it round.
  void _cameraOnDriver() {
    final controller = _controller;
    final point = widget.driverPoint;
    if (controller == null || point == null) return;
    final current = controller.cameraPosition;
    // `newLatLngZoom` rather than a full camera position: an update that names
    // a target and a zoom leaves bearing and tilt untouched, so following cannot
    // undo a driver who has pitched the map or spun it round.
    controller.animateCamera(
      CameraUpdate.newLatLngZoom(_ll(point), current?.zoom ?? 14),
      // Short enough to read as the map keeping up rather than as a flight. A
      // driver watching for their next turn should not have to wait out a long
      // easing every time the GPS reports a metre.
      duration: const Duration(milliseconds: 600),
    );
  }

  /// Called when the camera comes to rest: if it is no longer framing the driver,
  /// the driver moved it, so stop following until they ask to be picked up again.
  void _onCameraIdle() {
    if (!_following) return;
    final point = widget.driverPoint;
    final current = _controller?.cameraPosition;
    if (point == null || current == null) return;
    if (!DriverMapPanel.stillFollowing(
      cameraTarget: GeoPoint(current.target.latitude, current.target.longitude),
      driver: point,
    )) {
      setState(() => _following = false);
    }
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
                    const Positioned(left: 0, bottom: 0, child: _Attribution()),
                    // The recentre button, over the map and only while following
                    // is off.
                    //
                    // No `IgnorePointer` over the map underneath, deliberately, so a
                    // tap that misses the button still pans the map as the driver
                    // expects. Top-right, opposite the compass MapLibre draws,
                    // because the bottom of this panel is where the pickup and
                    // drop-off sit.
                    if (!_following)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: Material(
                          color: MngColors.surface,
                          shape: const CircleBorder(),
                          elevation: 2,
                          child: InkWell(
                            key: const Key('recentreMapButton'),
                            customBorder: const CircleBorder(),
                            onTap: recentre,
                            child: const Padding(
                              padding: EdgeInsets.all(10),
                              child: Icon(Icons.my_location, size: 20),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildMap(List<GeoPoint> points) {
    final route = _route;
    final style = _styleText;
    // The style is not ready for the first frame or two. A map built with an
    // empty style string renders a black rectangle with nothing to explain it,
    // so the panel's own "no location" state stands in for those frames.
    if (style == null || style.isEmpty) return const _NoLocationYet();
    return MapLibreMap(
      key: const Key('driverMap'),
      styleString: style,
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
      onCameraIdle: _onCameraIdle,
      onStyleLoadedCallback: () => _addOverlays(points, route),
    );
  }

  /// The driver's own car, as the style's `vehicles` source wants it.
  ///
  /// The same GeoJSON shape the rider's app writes for the driver it is
  /// watching, from the same layer in the same style, so a car is drawn the
  /// same way on both sides of the trip.
  ///
  /// Only pushed when the driver has a compass reading. A feature with no
  /// `bearing` draws the car pointing north, which on the driver's own map
  /// would be a vehicle apparently driving the wrong way up their own street;
  /// no car is the honest alternative to that.
  ///
  /// That reasoning was about the *rider's* map, where a car graphic pointing the
  /// wrong way is actively misleading. It does not hold for this panel, which
  /// only the driver ever sees, and it was the reason the driver's own position
  /// sometimes did not appear on the map at all: geolocator hands back no heading
  /// whenever the phone has no fix on a magnetometer -- a flat dashboard, a table,
  /// indoors -- and a driver in exactly those places was left with no marker while
  /// their trip ran. A north-pointing car the driver can see themselves inside is
  /// worth more than no car, so the heading is optional here and 0 when absent.
  Future<void> _pushVehicle(MapLibreMapController controller) async {
    final point = widget.driverPoint;
    if (point == null) return;
    final bearing = widget.driverHeading ?? 0;
    await controller.addImage(kCarTopdownIconName, carTopdownPng());
    await controller.addGeoJsonSource(kVehicleSourceId, {
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'properties': {kVehicleBearingProperty: bearing},
          'geometry': {
            'type': 'Point',
            'coordinates': [point.lng, point.lat],
          },
        },
      ],
    });
  }

  Future<void> _addOverlays(
    List<GeoPoint> points,
    List<GeoPoint>? route,
  ) async {
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
    // Pickup and dropoff only. The driver's own position is the car, drawn by
    // the style's `moving-car-icon` layer from its `bearing`; a circle under it
    // as well would put a blue dot in the middle of the car, which is the exact
    // ambiguity the car was introduced to remove.
    for (final role in const ['pickup', 'dropoff']) {
      await controller.addCircleLayer(
        'pins-src-$_uid',
        '$role-core-$_uid',
        CircleLayerProperties(
          circleRadius: 6,
          circleColor: _css(_roleColor(role)),
        ),
        filter: _roleIs(role),
      );
    }

    await _pushVehicle(controller);

    // Set last, once every source is in place, so `didUpdateWidget` can never
    // call `setGeoJsonSource` against a source that has not been added yet.
    _sourcesAdded = true;
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
  ///
  /// The driver's own position is skipped. It is drawn as the car and not as a
  /// pin, and tagging it `driver` here would put a coloured dot under the car
  /// as well -- which is the ambiguity the car exists to remove.
  Map<String, GeoPoint> _roles(List<GeoPoint> points) {
    final roles = <String, GeoPoint>{};
    var next = 0;
    if (widget.driverPoint != null) next++;
    if (points.length > next) roles['pickup'] = points[next++];
    if (points.length > next) roles['dropoff'] = points[next];
    return roles;
  }

  /// A style filter matching features whose `role` is [role]. The plugin types
  /// `filter` as `dynamic` and has no helper for it, so the expression is built
  /// once here rather than hand-written at each call site.
  static List<dynamic> _roleIs(String role) => [
    '==',
    ['get', 'role'],
    role,
  ];

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
  Widget build(BuildContext context) =>
      const ColoredBox(key: Key('driverMapStandIn'), color: MngColors.muted);
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
