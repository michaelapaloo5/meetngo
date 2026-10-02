import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:mng_core/mng_core.dart';

import '../data/location_service.dart';

/// The credit the OSM tile usage policy requires to be visible, matching
/// `kOsmAttribution` in the driver app's `DriverMapPanel`.
///
/// Still required, and still drawn by this file's own widget. MapLibre's own
/// attribution option is off (`logoEnabled` and the attribution toggle),
/// because MapLibre by default prints a Mapbox-branded badge, which would be a
/// false claim about who drew the map and is not this app's to display.
const kOsmAttribution = '© OpenStreetMap contributors';

/// How far the camera is tipped back from straight-down, in degrees.
///
/// This is the whole difference between a 2D map and a 3D one, and it is worth
/// stating why 45 and not 0. A tilt of 0 is a plan view: no buildings, no
/// perspective, nothing that reads as a city. MapLibre clamps tilt by zoom —
/// at low zoom there is nothing to extrude and a steep angle just smears the
/// tiles — so this is paired with a zoom that is high enough for the style's
/// `building` source-layer to have data. That layer is minzoom 13, which is
/// where the style's own `building-3d` layer starts for the same reason.
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
    this.driver,
    this.height = 280,
    this.fill = false,
    this.interactive = false,
    this.onTapPoint,
    this.pickupLabel,
    this.dropoffLabel,
  });

  /// The place name to print beside the pickup pin, when there is one.
  ///
  /// A pin with no label is a coloured dot the rider has to match to a street by
  /// shape, and matching a dot to a street from memory is the one thing a map is
  /// supposed to remove. The name comes from the trip's own `TripStop.label`,
  /// which is a real place name and never a coordinate -- there is a regex in
  /// `trip_copy.dart` whose entire job is to stop a coordinate reaching a rider.
  ///
  /// Null is a real state -- a trip row written before labels existed, and the
  /// finding-a-driver screen which has a pickup but no destination yet -- and the
  /// layer is simply not added, rather than drawing an empty label.
  final String? pickupLabel;

  /// The place name to print beside the dropoff pin.
  ///
  /// A null on both [pickupLabel] and [dropoffLabel] means no symbol layers are
  /// added at all, so a caller that has nothing to say pays nothing.
  final String? dropoffLabel;

  /// Where the assigned driver is and which way it is facing, when the trip has
  /// a driver with a position.
  ///
  /// A [VehicleFix] rather than a [GeoPoint], because the car is drawn pointing
  /// the way the driver is driving and a coordinate cannot say which way that
  /// is. See the `moving-car-icon` layer in the shared style.
  final VehicleFix? driver;

  /// Let the rider move the map: drag, pinch to zoom, twist to rotate, two
  /// fingers to tilt.
  ///
  /// Off on the tracking card's map, where a vertical drag has to scroll the
  /// details rather than move the map out from under the rider, and on while
  /// the rider is choosing a pickup -- and on the searching screen, where
  /// nothing else scrolls, so with the gestures off a drag does nothing at all
  /// and the map feels broken.
  final bool interactive;

  /// A tap on the map, in coordinates.
  ///
  /// Only fires when [interactive] is set: MapLibre reports taps as part of
  /// its gesture handling, so with the gestures off a tap callback would
  /// silently never fire, which is worse than not offering one.
  final void Function(GeoPoint point)? onTapPoint;

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

  /// Fill whatever box the parent gives this, instead of [height].
  ///
  /// For the screens where the map is the screen: behind the tracking card and
  /// behind the searching copy, rather than a 280px rectangle at the top of a
  /// scrolling column. [height] is ignored when this is set, so a caller cannot
  /// ask for both.
  ///
  /// The rounded corners go with it too. A full-bleed map inside a `ClipRRect`
  /// with a 20px radius leaves a sliver of the page background down each edge,
  /// which on a screen-sized map is two dark stripes the rider sees on every
  /// swipe.
  final bool fill;

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
  State<RideMap> createState() => RideMapState();
}

/// Public so a parent can drive the camera through a `GlobalKey`.
///
/// The live-location button has to move the camera back to the rider, and the
/// controller MapLibre hands out only exists after the map is built and lives
/// inside this widget. A `GlobalKey<RideMapState>` is the ordinary way for a
/// parent to reach a child's controller without passing it down through every
/// screen in between.
class RideMapState extends State<RideMap> {
  MapLibreMapController? _controller;

  /// The bundled style's text, loaded once and cached.
  ///
  /// Needed because `MapLibreMap.styleString` is a plain `String` and
  /// [premiumMapStyleJson] reads the asset bundle, which is asynchronous. A
  /// `FutureBuilder` around the map would rebuild the whole map the moment the
  /// style arrived, throwing away the camera; loading in `initState` and
  /// rendering a labelled placeholder for the one or two frames it takes is
  /// better than a flicker of blank map.
  ///
  /// Cached across instances because the style never changes for the life of
  /// the process and more than one map can be alive at once.
  static String? _styleText;

  /// Whether the engine is up and the camera can be moved.
  ///
  /// True under [RideMap.disabledForTest], because the stand-in has no engine
  /// to wait for. A test seam that reported "not ready" forever would leave the
  /// live-location button permanently disabled and make it untestable, which is
  /// the one thing the seam exists to prevent.
  bool get isReady => RideMap.disabledForTest || _controller != null;

  /// Where the last recentre was asked to go, for tests.
  ///
  /// Set before the engine is consulted, so a test can assert that a button
  /// press reached the map and targeted the right point without needing a
  /// native map to exist. Read it as "what was asked for", not "what happened":
  /// a real camera move is not observable from here.
  @visibleForTesting
  GeoPoint? lastRecentredOn;

  /// Move the camera to [point] and back to the default 3D framing.
  ///
  /// Returns false when the engine is not ready yet, so a button pressed in the
  /// first moment after the map appears can be a no-op rather than a crash.
  /// Callers are expected to check [isReady] first and to say something when
  /// this returns false, because a press that silently does nothing is the one
  /// failure mode of a live-location button.
  Future<bool> recenterOn(GeoPoint point) async {
    lastRecentredOn = point;
    final controller = _controller;
    if (controller == null) return false;
    await controller.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: LatLng(point.lat, point.lng),
          zoom: kRideMapSinglePointZoom,
          tilt: kRideMapTilt,
          bearing: kRideMapBearing,
        ),
      ),
    );
    return true;
  }

  @override
  void initState() {
    super.initState();
    _uid = 'ride-${identityHashCode(this)}';
    if (_styleText == null) {
      // Fire and forget into a `setState`, guarded on `mounted`. A failure
      // here leaves `_styleText` null and the build below draws a placeholder
      // that says so, rather than a silently blank map.
      premiumMapStyleJson().then((text) {
        _styleText = text;
        if (mounted) setState(() {});
      });
    }
  }

  /// Unique per instance. Two maps can be alive at once on the driver side, and
  /// MapLibre source and layer ids are global to a style, so a shared id would
  /// have one map's pins drawn onto the other.
  late final String _uid;

  /// Every pin to draw as a circle, in draw order.
  ///
  /// The driver is *not* in this list. It is drawn by the style's own
  /// `moving-car-icon` symbol layer, from the `vehicles` source, because that
  /// is what makes it a rotated car rather than a circle: a circle layer can
  /// only draw circles, and a circle gives a rider no way to tell which way the
  /// driver is approaching from.
  List<GeoPoint> _allPoints(GeoPoint from, GeoPoint? to, GeoPoint? here) =>
      <GeoPoint>[from, ?to, ?here];

  /// The driver's position and heading, as the style's `vehicles` source.
  Map<String, dynamic>? _vehicleGeoJson() => vehicleGeoJson(widget.driver);

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
    // The driver's heading changes even when the position has not -- a car
    // turning at a junction is the same coordinate as one second earlier -- so
    // the vehicle is re-pushed on either having changed.
    if (oldWidget.pickup == widget.pickup &&
        oldWidget.dropoff == widget.dropoff &&
        oldWidget.driver == widget.driver &&
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
      _pinsGeoJson(_allPoints(from, to, widget.location?.point)),
    );
    final vehicle = _vehicleGeoJson();
    if (vehicle != null) {
      await controller.setGeoJsonSource(kVehicleSourceId, vehicle);
    }
  }

  @override
  Widget build(BuildContext context) {
    final from = widget.pickup != null && RideMap.isPlottable(widget.pickup!)
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

    // `fill` drops the SizedBox and the ClipRRect so the map takes the whole
    // box the parent offers it, edge to edge. Everything else -- the pin
    // layers, the attribution, the location note -- is identical either way, so
    // the two modes cannot drift apart.
    final body = Stack(
      children: [
        Positioned.fill(
          child: RideMap.disabledForTest
              ? _MapStandIn(pickup: from, onTapPoint: widget.onTapPoint)
              : _buildMap(from: from, to: to, here: here),
        ),
        const Positioned(left: 0, right: 0, bottom: 0, child: _Attribution()),
        if (note.isNotEmpty)
          Positioned(
            left: 8,
            right: 8,
            top: 8,
            child: _LocationNote(message: note),
          ),
      ],
    );

    if (widget.fill) return SizedBox.expand(child: body);
    return ClipRRect(
      borderRadius: BorderRadius.circular(MngRadius.large),
      child: SizedBox(height: widget.height, child: body),
    );
  }

  Widget _buildMap({
    required GeoPoint from,
    required GeoPoint? to,
    required GeoPoint? here,
  }) {
    // `?` rather than `if (x != null) x`: same order, same list, and the
    // analyzer's `use_null_aware_elements` is an error under --fatal-infos.
    // The driver is last so the car draws over the route and the stop pins.
    final points = _allPoints(from, to, here);
    // A route needs two ends; the single-point case is the finding screen.
    final hasRoute = to != null;

    // The style is loaded from the bundle in `initState` and is not ready for
    // the first frame or two. Drawing the map with an empty style string in
    // that window produces a black rectangle with no explanation, so the
    // placeholder is used instead -- the same one a caller gets when it has
    // nothing honest to draw.
    final style = _styleText;
    if (style == null || style.isEmpty) {
      return _Fallback(height: widget.height, message: 'Loading the map');
    }

    return MapLibreMap(
      key: const Key('rideMap'),
      styleString: style,
      initialCameraPosition: CameraPosition(
        target: _ll(from),
        zoom: hasRoute ? kRideMapRouteMaxZoom : kRideMapSinglePointZoom,
        tilt: kRideMapTilt,
        bearing: kRideMapBearing,
      ),
      // A rider is not given the map to drag while a driver is on the way. With
      // the gestures on, a vertical drag moves the map and the details above it
      // never scroll, so the rider cannot reach the buttons lower down. On the
      // searching screen and the route page it is on, because there is nothing
      // to scroll and a dead map reads as a broken one.
      scrollGesturesEnabled: widget.interactive,
      zoomGesturesEnabled: widget.interactive,
      rotateGesturesEnabled: widget.interactive,
      tiltGesturesEnabled: widget.interactive,
      dragEnabled: widget.interactive,
      // `onMapClick` is delivered through the gesture layer, so it only fires
      // when those are on.
      onMapClick: widget.interactive && widget.onTapPoint != null
          ? (_, latLng) =>
                widget.onTapPoint!(GeoPoint(latLng.latitude, latLng.longitude))
          : null,
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
        // Deliberately no `belowLayerId`. A layer added without one goes on top
        // of everything, and the style has a `building-3d` extrusion — so
        // anchoring the route under it would put the rider's own route
        // *behind* the city, and on a tilted camera that means it disappears
        // behind the buildings it runs through. A route is drawn over
        // everything, as it is in every map app worth copying.
        //
        // The style draws roads at #FFFFFF on #F4F4F6 land, so the route's
        // colour is chosen to be the one thing on the map that is neither:
        // a saturated blue cannot be mistaken for a road, a park or a
        // building at any zoom.
      );
    }

    await controller.addGeoJsonSource('pins-src-$_uid', _pinsGeoJson(points));
    await controller.addCircleLayer(
      'pins-src-$_uid',
      'pin-halo-$_uid',
      CircleLayerProperties(circleRadius: 9, circleColor: _css(MngColors.page)),
    );
    // The rider's own dot stays a dot: it is the rider, not a vehicle.
    await controller.addCircleLayer(
      'pins-src-$_uid',
      'device-core-$_uid',
      CircleLayerProperties(circleRadius: 5, circleColor: _css(MngColors.info)),
      filter: _roleIs('device'),
    );
    await controller.addCircleLayer(
      'pins-src-$_uid',
      'pin-core-$_uid',
      CircleLayerProperties(
        circleRadius: 6,
        circleColor: _css(MngColors.primary),
      ),
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

    // The place names, printed beside the pins.
    //
    // One source already carries a `name` property, so these are two symbol
    // layers over the pins rather than a second source. Added after the circles
    // so the text draws over them, and added only when there is something to
    // print -- an empty label would render as an empty text box with a halo
    // behind it, which is a grey smudge on a map.
    //
    // `text-allow-overlap` is off and `text-optional` on, so two labels that
    // would collide drop one rather than overlapping each other's halos. The
    // rider's own dot is not labelled: they know where they are, and a third
    // label on a three-pin map is the one that collides first.
    if ((widget.pickupLabel ?? '').isNotEmpty) {
      await controller.addSymbolLayer(
        'pins-src-$_uid',
        'pin-label-$_uid',
        _labelProperties(widget.pickupLabel!),
        filter: _roleIs('pickup'),
      );
    }
    if ((widget.dropoffLabel ?? '').isNotEmpty) {
      await controller.addSymbolLayer(
        'pins-src-$_uid',
        'dropoff-label-$_uid',
        _labelProperties(widget.dropoffLabel!),
        filter: _roleIs('dropoff'),
      );
    }

    await _addVehicle(controller);

    // Set last, once every source and image is in place, so `didUpdateWidget`
    // can never call `setGeoJsonSource` against a source that has not been
    // added yet.
    _sourcesAdded = true;
  }

  /// Registers the car's sprite and hands the style its position.
  ///
  /// Two things, and the order matters. `addImage` has to happen before the
  /// source is set, because a symbol layer whose `icon-image` names an image
  /// that does not exist draws nothing at all -- silently, with no error --
  /// and a rider would just see no car.
  ///
  /// The layer itself is *not* added here. It is in the shared style, which is
  /// where the user-facing drawing rules live; adding it from Dart as well
  /// would produce two layers with the same id and no useful error.
  Future<void> _addVehicle(MapLibreMapController controller) async {
    await controller.addImage(kCarTopdownIconName, carTopdownPng());
    final vehicle = _vehicleGeoJson();
    if (vehicle != null) {
      await controller.addGeoJsonSource(kVehicleSourceId, vehicle);
    }
  }

  /// How a place name is drawn beside its pin.
  ///
  /// Written once and used for both pins, because two hand-written copies of a
  /// symbol layer's properties is two chances to give one of them a different
  /// offset and have "the destination label is higher than the pickup label" be
  /// a decision nobody remembers making.
  ///
  /// The three settings that matter, and why:
  ///
  /// - **`text-offset: [0, 1.2]`, `text-anchor: top`.** Below the dot, not above
  ///   it. Above, the pickup's label would sit over the route line on a short
  ///   ride and the rider would be reading the name of the place they are going
  ///   to through the place they are leaving.
  /// - **`text-halo-*`.** The map is pale grey roads on pale grey land, so an
  ///   unhaloed name at this size is unreadable wherever it crosses anything.
  ///   The halo is the label's background and costs no layout.
  /// - **`text-max-width: 11`, `text-optional: true`.** A long place name is
  ///   wrapped to two lines rather than run off the screen, and when two labels
  ///   would collide one of them drops instead of overlapping. `text-optional` is
  ///   what makes the drop happen; without it the second label is placed on top
  ///   of the first and the rider reads the wrong place name.
  SymbolLayerProperties _labelProperties(String fallback) =>
      SymbolLayerProperties(
        textField: [
          'coalesce',
          ['get', 'name'],
          fallback,
        ],
        textFont: const ['Noto Sans Regular'],
        textSize: 11,
        textColor: _css(MngColors.textPrimary),
        textHaloColor: _css(MngColors.page),
        textHaloWidth: 1.4,
        textOffset: const [0, 1.2],
        // The string, not an enum: `SymbolLayerProperties.textAnchor` is
        // `dynamic` and the plugin documents the values as MapLibre's own
        // `top`/`bottom`/`left`/etc. Passing an `Alignment` here would be a
        // type error at the platform channel, not at compile time.
        textAnchor: 'top',
        textMaxWidth: 11,
        textOptional: true,
        // Not set: `text-allow-overlap`. Off is what makes `text-optional`
        // meaningful.
      );

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
  static List<dynamic> _roleIs(String role) => [
    '==',
    ['get', 'role'],
    role,
  ];

  /// MapLibre takes colours as CSS strings, not `Color`, and it does not accept
  /// Flutter's `Color.toARGB32()` output for every channel order — so the hex
  /// is built here rather than with a `toString()` that happens to work.
  static String _css(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  static LatLng _ll(GeoPoint p) => LatLng(p.lat, p.lng);
}

/// The `vehicles` source for a driver's [fix], in the shape the style's
/// `moving-car-icon` layer reads.
///
/// Top-level rather than a private method on the state, because the parts of it
/// that can be wrong are all silent: GeoJSON orders coordinates longitude
/// first, and this app uses latitude first everywhere else, so a swap puts the
/// car in the Atlantic; and `icon-rotate` is handed the bearing as a value and
/// adds it to an angle, so a string instead of a number fails to parse and
/// leaves the car pointing north. Neither throws. Both are therefore only
/// catchable by a test that can see the data, and the data is here rather than
/// behind a widget that cannot be built under `flutter test`.
///
/// Returns null when there is nothing to draw, which the caller reads as "leave
/// the source alone" rather than as "empty the source" -- a driver with no
/// compass must not make the rider's car blink out of existence.
Map<String, dynamic>? vehicleGeoJson(VehicleFix? fix) {
  if (fix == null || !RideMap.isPlottable(fix.point)) return null;
  return {
    'type': 'FeatureCollection',
    'features': [
      {
        'type': 'Feature',
        'properties': {kVehicleBearingProperty: fix.headingDegrees},
        'geometry': {
          'type': 'Point',
          'coordinates': [fix.point.lng, fix.point.lat],
        },
      },
    ],
  };
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
/// Deliberately an empty tinted box and nothing else: a stand-in that drew pins
/// and a route would let a test assert on its own fiction, which is how a test
/// suite comes to believe a map is covered when it is not.
///
/// It does forward taps, which is the one thing it adds. MapLibre reports map
/// clicks through its own gesture layer, so with no engine a tap never arrives
/// at all — and the code behind that tap (a rider choosing where to be picked
/// up) is ordinary Dart with no engine in it at all. Without this the entire
/// tap-to-pick path would be untestable, and it would be untestable for a
/// reason that has nothing to do with the logic.
class _MapStandIn extends StatefulWidget {
  const _MapStandIn({required this.pickup, this.onTapPoint});

  /// The point taps are measured against, so the offset lands nearby rather
  /// than at an arbitrary coordinate.
  final GeoPoint? pickup;

  final void Function(GeoPoint point)? onTapPoint;

  @override
  State<_MapStandIn> createState() => _MapStandInState();
}

class _MapStandInState extends State<_MapStandIn> {
  /// How far the stand-in's taps can move the point, in degrees.
  ///
  /// About a kilometre across the whole box, which is a few city blocks. It
  /// exists so a test can tell a tap that moved the point from one that did
  /// not, and so the offset is a plausible place rather than an arbitrary
  /// number: this is a real street grid, not a coordinate generator.
  static const double _spanDegrees = 0.01;

  @override
  Widget build(BuildContext context) {
    const box = ColoredBox(key: Key('rideMapStandIn'), color: MngColors.muted);
    final tap = widget.onTapPoint;
    final anchor = widget.pickup;
    if (tap == null || anchor == null) return box;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth <= 0 ? 1.0 : constraints.maxWidth;
        final height = constraints.maxHeight <= 0 ? 1.0 : constraints.maxHeight;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) {
            // The centre of the box is the anchor, so a tap in the middle
            // leaves the point alone and a tap away from the middle moves it
            // in the direction tapped. A stand-in that moved the point no
            // matter where it was tapped could not tell a working tap handler
            // from a broken one.
            final dx = (details.localPosition.dx / width - 0.5) * _spanDegrees;
            final dy = (details.localPosition.dy / height - 0.5) * _spanDegrees;
            tap(GeoPoint(anchor.lat + dy, anchor.lng + dx));
          },
          child: box,
        );
      },
    );
  }
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
            child: Text(message, style: MngTheme.light.textTheme.bodySmall),
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
