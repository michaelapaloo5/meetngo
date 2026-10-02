import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

import 'driver_map_panel.dart';

/// The trip map, filling the screen.
///
/// A driver looking at a 200-pixel strip of map is looking at a thumbnail: they
/// cannot read a street name, check which side of the road the pickup is on, or
/// see the junction two hundred metres ahead. This is the same [DriverMapPanel]
/// with the height taken off it, so it draws from the same code and cannot drift
/// from the panel in the trip screen -- a second map implementation is how the
/// two would end up disagreeing about where the driver is.
///
/// Opened by tapping the panel in the trip screen, and closed by the button and
/// the system back gesture. A route that swallowed the back gesture would leave
/// a driver who pressed back in the middle of a trip with no way back to the
/// controls, so the close button is the obvious one rather than an arrow: this is
/// a thing you look at, not a level you went into.
class FullscreenMapScreen extends StatelessWidget {
  const FullscreenMapScreen({
    super.key,
    required this.driverPoint,
    this.driverHeading,
    this.pickup,
    this.dropoff,
    this.routeGeometry,
  });

  final GeoPoint? driverPoint;
  final double? driverHeading;
  final GeoPoint? pickup;
  final GeoPoint? dropoff;
  final List<GeoPoint>? routeGeometry;

  /// Pushes the full-screen map.
  ///
  /// Returns the future so a caller can await the dismissal; nothing is read
  /// from it, because a driver who opened the map to look at a junction is not
  /// a caller waiting on a result.
  static Future<void> show(
    BuildContext context, {
    GeoPoint? driverPoint,
    double? driverHeading,
    GeoPoint? pickup,
    GeoPoint? dropoff,
    List<GeoPoint>? routeGeometry,
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => FullscreenMapScreen(
          driverPoint: driverPoint,
          driverHeading: driverHeading,
          pickup: pickup,
          dropoff: dropoff,
          routeGeometry: routeGeometry,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The screen's own height, less the app bar. Hard-coded rather than
    // `double.infinity` because the panel is a `SizedBox` with a fixed height by
    // design -- every layout that sizes it from its parent would be a second
    // place to change how tall a map is, and this one is where a driver's phone
    // in a mount decides the answer.
    final height = MediaQuery.of(context).size.height - kToolbarHeight;

    return Scaffold(
      backgroundColor: MngColors.page,
      appBar: AppBar(
        backgroundColor: MngColors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        leading: IconButton(
          key: const Key('closeFullscreenMapButton'),
          icon: const Icon(Icons.close),
          tooltip: 'Close map',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text('Map', style: MngTheme.light.textTheme.titleLarge),
      ),
      body: Padding(
        // A margin rather than edge to edge, so the panel's rounded corners are
        // visible against the page and the map reads as a thing on the screen
        // rather than a hole in it.
        padding: EdgeInsets.all(12.w),
        child: DriverMapPanel(
          // Keyed so a test can measure this panel against the strip it was
          // opened from, which is the only way to assert "bigger" rather than
          // "there are two of them".
          key: const Key('fullscreenDriverMap'),
          driverPoint: driverPoint,
          driverHeading: driverHeading,
          pickup: pickup,
          dropoff: dropoff,
          routeGeometry: routeGeometry,
          height: height,
        ),
      ),
    );
  }
}
