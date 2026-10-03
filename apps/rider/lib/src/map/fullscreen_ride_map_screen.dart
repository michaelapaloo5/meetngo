import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

import '../data/location_service.dart';
import 'ride_map.dart';
import 'rider_route_map.dart';

/// The rider's map, filling the screen.
///
/// The tracking screen's map is a card at the bottom of a column of ride details,
/// and a rider watching it to see where they are gets a strip of city with the
/// pickup and the driver in it. That is enough to know *roughly* where they are
/// and not enough to check which side of the road they are on, or what the next
/// junction is called.
///
/// This is the same [RideMap] with the height taken off, so it draws from the
/// same code and cannot drift from the card underneath it -- a second map
/// implementation is exactly how the two would end up disagreeing about where the
/// driver is.
///
/// Gestures are **on** here and the card leaves them off. That is not an
/// inconsistency: on the card a vertical drag has to scroll the ride details
/// rather than move the map out from under the rider, and on this screen there
/// is nothing to scroll, so with the gestures off a drag did nothing at all.
class FullscreenRideMapScreen extends StatelessWidget {
  const FullscreenRideMapScreen({
    super.key,
    this.pickup,
    this.pickupLabel,
    this.dropoff,
    this.dropoffLabel,
    this.location,
    this.driver,
  });

  final GeoPoint? pickup;
  final String? pickupLabel;
  final GeoPoint? dropoff;
  final String? dropoffLabel;
  final DeviceLocation? location;
  final VehicleFix? driver;

  static Future<void> show(
    BuildContext context, {
    GeoPoint? pickup,
    String? pickupLabel,
    GeoPoint? dropoff,
    String? dropoffLabel,
    DeviceLocation? location,
    VehicleFix? driver,
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => FullscreenRideMapScreen(
          pickup: pickup,
          pickupLabel: pickupLabel,
          dropoff: dropoff,
          dropoffLabel: dropoffLabel,
          location: location,
          driver: driver,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The screen's own height less the app bar. Hard-coded rather than
    // `double.infinity` because the panel is a `SizedBox` with a fixed height by
    // design, and that is the number this screen is deciding.
    final height = MediaQuery.of(context).size.height - kToolbarHeight;

    return Scaffold(
      backgroundColor: MngColors.page,
      appBar: AppBar(
        backgroundColor: MngColors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        leading: IconButton(
          key: const Key('closeFullscreenRideMapButton'),
          icon: const Icon(Icons.close),
          tooltip: 'Close map',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text('Map', style: MngTheme.light.textTheme.titleLarge),
      ),
      body: Padding(
        padding: EdgeInsets.all(12.w),
        // Only wrapped when there are two ends. A single point is the finding-a-
        // driver case, and there is no road to fetch between a point and nothing.
        child: (pickup != null && dropoff != null)
            ? RiderRouteMap(
                from: pickup!,
                to: dropoff!,
                builder: (context, shape) => _map(shape, height),
              )
            : _map(null, height),
      ),
    );
  }

  /// The map itself, with or without a road already fetched for it.
  ///
  /// A method rather than an inline widget because the wrapper calls it once with
  /// a shape and once with null, and writing the twenty lines twice is how the
  /// two copies end up different.
  Widget _map(List<GeoPoint>? shape, double height) => RideMap(
    key: const Key('fullscreenRideMap'),
    pickup: pickup,
    pickupLabel: pickupLabel,
    dropoff: dropoff,
    dropoffLabel: dropoffLabel,
    routeShape: shape,
    location: location,
    driver: driver,
    height: height,
    // On, because this is the screen the rider came here to move.
    interactive: true,
  );
}
