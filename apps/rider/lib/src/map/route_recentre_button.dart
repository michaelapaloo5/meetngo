import 'package:flutter/material.dart';
import 'package:mng_core/mng_core.dart';

/// The recentre control drawn over an interactive RideMap.
///
/// Private to `ride_map.dart` and rendered by it, unlike `LiveLocationButton`
/// which the screens host themselves. The difference is not tidiness: this one
/// appears in response to the rider moving the camera, which is an event inside
/// `RideMap`'s own state, and a control hosted by a parent would not learn about
/// it until the parent happened to rebuild.
class RecentreOnRouteButton extends StatelessWidget {
  const RecentreOnRouteButton({super.key, required this.onPressed});

  final Future<bool> Function() onPressed;

  static const double size = 44;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: true,
      label: 'Centre the map on the route',
      child: Material(
        color: MngColors.surface,
        elevation: 3,
        shadowColor: Colors.black26,
        borderRadius: BorderRadius.circular(MngRadius.small),
        child: InkWell(
          key: const Key('routeRecentreButton'),
          borderRadius: BorderRadius.circular(MngRadius.small),
          onTap: () async {
            // Says something when it cannot act. A press that silently does
            // nothing is the worst version of this control, because its whole
            // promise is "put the route back".
            final messenger = ScaffoldMessenger.maybeOf(context);
            if (!await onPressed()) {
              messenger?.showSnackBar(
                const SnackBar(
                  content: Text(
                    'The map is still loading. Try again in a moment.',
                  ),
                  duration: Duration(seconds: 2),
                ),
              );
            }
          },
          child: SizedBox(
            width: size,
            height: size,
            child: const Icon(
              Icons.route_outlined,
              size: 20,
              color: MngColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
