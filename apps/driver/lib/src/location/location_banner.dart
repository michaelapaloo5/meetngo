import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

import 'location_controller.dart';

/// What the driver is told when the map has nothing on it.
///
/// Rendered by whichever screen is asking for a position, and only when there is
/// something to say: a fix in hand shows nothing, because a driver who can see
/// the map does not need to be told they can see the map. Every other state --
/// location off, refused, refused permanently, still looking, failed -- gets a
/// sentence and, where retrying could actually help, a button.
///
/// It listens to [location] itself. A screen that reads the controller's state
/// without listening to it is a screen that shows the first value it ever read,
/// which for a location is always "nothing yet".
class LocationBanner extends StatelessWidget {
  const LocationBanner({super.key, required this.location});

  final LocationController location;

  /// Whether a retry can plausibly change the answer.
  ///
  /// Not offered for a denial: the system prompt has already been refused, and
  /// re-running it either does nothing or opens a dialog the driver has learned
  /// to dismiss. The message for those two states names Settings instead,
  /// which is the only place the answer can be changed.
  bool get _canRetry =>
      location.status == DriverLocationStatus.noFix ||
      location.status == DriverLocationStatus.failed ||
      location.status == DriverLocationStatus.serviceOff ||
      location.status == DriverLocationStatus.denied;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: location,
      builder: (context, _) {
        final message = location.message;
        if (message == null) return const SizedBox.shrink();
        final text = MngTheme.light.textTheme;
        return Container(
          key: const Key('locationBanner'),
          width: double.infinity,
          margin: EdgeInsets.symmetric(horizontal: 20.w, vertical: 6.h),
          padding: EdgeInsets.all(12.w),
          decoration: BoxDecoration(
            color: MngColors.muted,
            borderRadius: BorderRadius.circular(MngRadius.small),
            border: Border.all(color: MngColors.divider),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.location_off_outlined,
                size: 18,
                color: MngColors.textSub,
              ),
              SizedBox(width: 10.w),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      message,
                      key: const Key('locationMessage'),
                      style: text.bodySmall,
                    ),
                    if (location.permissionNote != null) ...[
                      SizedBox(height: 4.h),
                      Text(
                        location.permissionNote!,
                        key: const Key('locationPermissionNote'),
                        style: text.bodySmall?.copyWith(color: MngColors.textSub),
                      ),
                    ],
                  ],
                ),
              ),
              if (_canRetry && !location.busy)
                TextButton(
                  key: const Key('locationRetry'),
                  onPressed: location.refresh,
                  child: const Text('Retry'),
                ),
            ],
          ),
        );
      },
    );
  }
}
