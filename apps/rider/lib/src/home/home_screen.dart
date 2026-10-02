import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

import '../data/booked_trip.dart';
import '../data/location_service.dart';
import '../data/place_service.dart';
import 'widgets/recent_rides.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.riderName,
    this.location,
    this.place,
    this.recentRides,
    this.onRideTap,
    this.onSearchTap,
    this.onNotificationsTap,
  });

  /// The signed-in rider's own first name.
  ///
  /// Null or blank when `profiles.full_name` is empty, which is a real value
  /// for every account created before sign-up began persisting it, and also
  /// when the profile row has not loaded or could not be read. The greeting
  /// falls back rather than rendering ", ", because a screen that greets a
  /// rider with a comma is worse than one that does not name them.
  final String? riderName;
  /// The rider's own position, as read by the shell.
  ///
  /// Null until the first read comes back, which is a real state rather than a
  /// loading one to be papered over: this line used to be the literal
  /// `'Osu, Accra, Ghana'`, printed on every launch for every rider anywhere,
  /// which is a lie whenever the rider is not in Osu and is worse than saying
  /// nothing at all.
  final DeviceLocation? location;

  /// The place name for [location], when the geocoder has answered.
  ///
  /// Null for three separate reasons that the screen cannot tell apart and does
  /// not need to: the geocoder has not been asked yet, it has not answered, or
  /// it failed. All three render the coordinates, which are always true.
  final PlaceName? place;

  /// The rider's recent trips, newest first.
  ///
  /// Null while the first read is in flight, which is a different state from
  /// empty and draws nothing at all -- there is no point showing a "Recent
  /// rides" heading over nothing.
  final List<BookedTrip>? recentRides;

  /// A recent ride was tapped.
  final void Function(BookedTrip ride)? onRideTap;

  /// `Where would you go?` was pressed, or the promo was.
  ///
  /// [promo] is true when the offer was the thing that was pressed, so the
  /// route page can apply the discount rather than making the rider remember
  /// the code they were shown.
  final void Function(BuildContext context)? onSearchTap;

  final void Function(BuildContext context)? onNotificationsTap;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String get _greeting {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  }

  /// The line under the greeting.
  ///
  /// It used to be the constant `'Osu, Accra, Ghana'`. That string is the app's
  /// default pickup, not the rider's position, so it named a place the rider was
  /// not in for every rider who was not standing in Osu -- and a demo shown
  /// outside Accra would have displayed it as though it were a live reading.
  /// [DeviceLocation.riderMessage] is the existing honest copy for the states
  /// where there is no fix, so it is reused here rather than rewritten.
  ///
  /// Never coordinates. `"5.6037, -0.1870"` is true and useless, and a rider
  /// cannot do anything with it: it is not a place, it does not read as a
  /// location, and it is the one string on this screen that looks like a bug to
  /// anyone who does not know what it is. So the fallback is a sentence about
  /// the situation -- [DeviceLocation.riderMessage] where there is a reason,
  /// and "Your location" where the geocoder simply has not answered or cannot.
  /// The exact point belongs on the map, and it is on the map.
  String get _locationLine {
    final loc = widget.location;
    if (loc == null) return 'Finding your location';
    if (!loc.hasFix) return loc.riderMessage;
    final place = widget.place;
    if (place != null && place.line.isNotEmpty) return place.line;
    return 'Your location';
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.riderName?.trim() ?? '';
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name.isEmpty ? _greeting : '$_greeting, $name',
                          key: const Key('greeting'),
                          style: MngTheme.light.textTheme.titleLarge,
                        ),
                        SizedBox(height: 2.h),
                        Text(
                          _locationLine,
                          key: const Key('locationLine'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: MngTheme.light.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const Key('notificationsButton'),
                    onPressed: () => widget.onNotificationsTap?.call(context),
                    icon: const Icon(Icons.notifications_none),
                    tooltip: 'Notifications',
                  ),
                ],
              ),
              SizedBox(height: 20.h),
              GestureDetector(
                key: const Key('searchField'),
                onTap: () => widget.onSearchTap?.call(context),
                child: Container(
                  constraints: BoxConstraints(minHeight: 52.h),
                  padding: EdgeInsets.symmetric(
                    horizontal: 16.w,
                    vertical: 14.h,
                  ),
                  decoration: BoxDecoration(
                    color: MngColors.muted,
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.search, color: MngColors.textSub),
                      SizedBox(width: 10.w),
                      Expanded(
                        child: Text(
                          'Where would you go?',
                          overflow: TextOverflow.ellipsis,
                          style: MngTheme.light.textTheme.bodyMedium?.copyWith(
                            color: MngColors.textSub,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: 12.h),
              // No category chips. Choosing Lite, Standard or Premium here was
              // choosing a tier before there was a trip, and then choosing it
              // again on the next screen -- two controls for one decision, with
              // the first one easy to forget. The tier is picked once, on the
              // ride page, where the distance and fare that depend on it sit on
              // the same screen.
              //
              // Below the search field, the rider's own last few trips.
              // `BookedTrip` is a real row from `trips`, so these are rides
              // that happened -- unlike the vehicle list that used to sit
              // here. Null while loading and empty forever for a rider who has
              // never booked, and neither state draws a heading.
              RecentRides(
                rides: widget.recentRides ?? const [],
                onOpen: widget.onRideTap,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
