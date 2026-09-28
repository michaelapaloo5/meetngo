import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:latlong2/latlong.dart';
import 'package:mng_core/mng_core.dart';

/// OpenStreetMap's public raster tiles. No key, no account, no card.
///
/// Google Maps needs an API key whose Maps SDK for Android is billed to a card,
/// and this pilot has no card, so a `google_maps_flutter` build could not be
/// pointed at a project at all. `tile.openstreetmap.org` is the free endpoint
/// and is what the OSM tile usage policy asks apps to use; it was confirmed to
/// answer `200 image/png` from the build host before this template was chosen.
/// `a`/`b`/`c` subdomains are deliberately not used -- `flutter_map` itself
/// warns that the OSM servers have asked apps to stop sharding across them.
///
/// Retained on purpose: the OSM tile usage policy requires visible
/// attribution, and [kOsmAttribution] is on the map at all times rather than
/// behind a tap.
const kOsmTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

const kOsmAttribution = '© OpenStreetMap contributors';

/// The map, drawn for the driver.
///
/// OpenStreetMap raster tiles through `flutter_map`, with the driver's own
/// position, the pickup and -- when the trip has a leg to draw -- a line
/// between them. It takes the three points as arguments rather than reaching
/// for a controller, so the map is a view and not a place with rules in it:
/// every rule about what to do when there is no fix lives in
/// `LocationController`, and this widget's only job is to never render a blank
/// rectangle. A caller with nothing to show gets a labelled, tinted panel that
/// says so.
///
/// The [tileProvider] seam exists for tests. `TileLayer` otherwise fetches over
/// the network through `NetworkTileProvider`, and a widget test has no network
/// and a 2.7 GB machine.
class DriverMapPanel extends StatelessWidget {
  const DriverMapPanel({
    super.key,
    this.driverPoint,
    this.pickup,
    this.dropoff,
    this.height = 220,
    this.drawRoute = true,
    this.tileProvider,
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

  final TileProvider? tileProvider;

  /// Supplies the tile provider when a caller did not name one.
  ///
  /// A test seam, and the reason it is a static rather than a required argument:
  /// `ActiveTripScreen` and `DriverHomeScreen` both render this panel on a live
  /// trip, and threading a test-only parameter through both of them to reach
  /// the bottom of the tree would put test scaffolding in two production
  /// signatures. `flutter_test` answers every HTTP request with an empty 400,
  /// which `NetworkImage` turns into a load exception, and an `Image` with no
  /// `errorBuilder` reports that to `FlutterError.onError` -- so an unmocked
  /// map fails the test that happens to render it. Set from
  /// `test/support/harness.dart`, which is why it is reset there too.
  ///
  /// An explicit [tileProvider] argument still wins: production passes nothing
  /// and gets the network provider.
  static TileProvider Function()? tileProviderOverride;

  TileProvider? get _tiles => tileProvider ?? tileProviderOverride?.call();

  /// Every point worth fitting the camera to, in that order.
  List<LatLng> get _points => [
        if (driverPoint != null) _latLng(driverPoint!),
        if (pickup != null) _latLng(pickup!),
        if (dropoff != null) _latLng(dropoff!),
      ];

  /// The line to draw, if there is one worth drawing.
  ///
  /// Driver to pickup while collecting, pickup to dropoff once the rider is
  /// aboard, and a single leg rather than two once both ends are known: drawing
  /// both would put a segment through the pickup pin and make the route look
  /// like it doubles back.
  List<LatLng>? get _route {
    if (!drawRoute) return null;
    if (driverPoint != null && pickup != null) {
      return [_latLng(driverPoint!), _latLng(pickup!)];
    }
    if (pickup != null && dropoff != null) {
      return [_latLng(pickup!), _latLng(dropoff!)];
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final points = _points;
    return SizedBox(
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(MngRadius.large),
        child: DecoratedBox(
          decoration: const BoxDecoration(color: MngColors.muted),
          child: points.isEmpty
              ? const _NoLocationYet()
              : Stack(
                  children: [
                    Positioned.fill(child: _map(points)),
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

  Widget _map(List<LatLng> points) {
    final route = _route;
    return FlutterMap(
      key: const Key('driverMap'),
      options: MapOptions(
        // `initialCameraFit` rather than a hard-coded centre: the driver's
        // position and the pickup are a few hundred metres apart in a dense
        // city and can be most of the country apart on a long trip, and one
        // fixed centre cannot frame both. The padding leaves room for the
        // attribution strip along the bottom.
        initialCameraFit: CameraFit.coordinates(
          coordinates: points,
          padding: const EdgeInsets.fromLTRB(48, 48, 48, 64),
          maxZoom: 16,
          minZoom: 3,
        ),
        // A fallback for the frame before the fit is applied, and the map's
        // background colour: the muted token, so a tile that has not loaded is
        // the same colour as the panel behind it rather than a grey box.
        initialCenter: points.first,
        initialZoom: 14,
        backgroundColor: MngColors.muted,
        interactionOptions: const InteractionOptions(
          // Pan and pinch, deliberately without rotation: a driver dragging a
          // map one-handed on a phone should not be able to end up looking at
          // one of the other three ways up.
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
      ),
      children: [
        TileLayer(
          urlTemplate: kOsmTileUrl,
          userAgentPackageName: 'dev.meetngo.driver',
          tileProvider: _tiles,
        ),
        if (route != null && route.length > 1)
          PolylineLayer(
            key: const Key('mapRouteLine'),
            polylines: [
              Polyline(
                points: route,
                strokeWidth: 4,
                color: MngColors.primary,
                borderStrokeWidth: 1,
                borderColor: MngColors.onPrimary,
              ),
            ],
          ),
        MarkerLayer(markers: _markers()),
      ],
    );
  }

  List<Marker> _markers() => [
        if (driverPoint != null)
          Marker(
            key: const Key('mapDriverMarker'),
            point: _latLng(driverPoint!),
            width: 32,
            height: 32,
            child: const _Pin(
              key: Key('driverPin'),
              icon: Icons.navigation,
              color: MngColors.info,
            ),
          ),
        if (pickup != null)
          Marker(
            key: const Key('mapPickupMarker'),
            point: _latLng(pickup!),
            width: 32,
            height: 32,
            child: const _Pin(
              key: Key('pickupPin'),
              icon: Icons.trip_origin,
              color: MngColors.primary,
            ),
          ),
        if (dropoff != null)
          Marker(
            key: const Key('mapDropoffMarker'),
            point: _latLng(dropoff!),
            width: 32,
            height: 32,
            child: const _Pin(
              key: Key('dropoffPin'),
              icon: Icons.place,
              color: MngColors.success,
            ),
          ),
      ];
}

/// `mng_core` keeps its own [GeoPoint] so the shared package does not have to
/// depend on `latlong2`. The conversion happens here, at the widget edge, and
/// nowhere else: a `LatLng` escaping into a controller would be a second
/// coordinate type for the same two numbers.
LatLng _latLng(GeoPoint point) => LatLng(point.lat, point.lng);

class _Pin extends StatelessWidget {
  const _Pin({super.key, required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: MngColors.onPrimary, width: 2),
      ),
      child: Icon(icon, size: 16, color: MngColors.onPrimary),
    );
  }
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
