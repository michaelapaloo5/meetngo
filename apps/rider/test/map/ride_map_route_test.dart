import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';
import 'package:meetngo_rider/src/map/ride_map.dart';

/// The guard that decides whether the map redraws its route line.
///
/// This is the whole of the straight-line bug. The road arrives from the deployed
/// `route` function as hundreds of real geometry points -- confirmed in logcat,
/// 352 of them -- and if this function says "nothing changed" the map keeps
/// drawing the two-point line it drew on the first frame. Nothing else in the
/// system knows whether the road was applied, so this is the one place the answer
/// lives and the one place worth a test.
void main() {
  final shape = <GeoPoint>[
    const GeoPoint(5.55692, -0.172147),
    const GeoPoint(5.57, -0.169),
    const GeoPoint(5.6052, -0.166),
  ];

  bool push({
    Object? oldPickup,
    Object? newPickup,
    Object? oldDropoff,
    Object? newDropoff,
    Object? oldDriver,
    Object? newDriver,
    Object? oldLocationPoint,
    Object? newLocationPoint,
    List<GeoPoint>? oldShape,
    List<GeoPoint>? newShape,
  }) => mapNeedsOverlayPush(
    oldPickup: oldPickup,
    newPickup: newPickup,
    oldDropoff: oldDropoff,
    newDropoff: newDropoff,
    oldDriver: oldDriver,
    newDriver: newDriver,
    oldLocationPoint: oldLocationPoint,
    newLocationPoint: newLocationPoint,
    oldShape: oldShape,
    newShape: newShape,
  );

  group('a road arriving is a change', () {
    // The case that was broken. On the trip-detail screen the pickup, the
    // dropoff, the driver and the location are all identical across the rebuild
    // that carries the shape, so every other clause is false and the shape clause
    // is the only thing that can save it.
    test('a shape replacing none is a reason to redraw', () {
      expect(push(oldShape: null, newShape: shape), isTrue);
    });

    test('a shape replacing a different shape is a reason to redraw', () {
      expect(push(oldShape: const [], newShape: shape), isTrue);
    });

    test('the same shape twice is not a reason to redraw', () {
      // Otherwise every GPS fix would re-push the whole geometry.
      expect(push(oldShape: shape, newShape: shape), isFalse);
    });
  });

  group('the other things that redraw still redraw', () {
    test('a moved pickup', () {
      expect(
        push(oldPickup: const GeoPoint(1, 2), newPickup: const GeoPoint(3, 4)),
        isTrue,
      );
    });

    test('a moved dropoff', () {
      expect(
        push(
          oldDropoff: const GeoPoint(1, 2),
          newDropoff: const GeoPoint(3, 4),
        ),
        isTrue,
      );
    });

    test('a moved driver', () {
      expect(push(oldDriver: 'a', newDriver: 'b'), isTrue);
    });

    test('a moved rider position', () {
      expect(
        push(
          oldLocationPoint: const GeoPoint(1, 2),
          newLocationPoint: const GeoPoint(3, 4),
        ),
        isTrue,
      );
    });

    test('nothing at all', () {
      expect(push(), isFalse);
    });
  });

  group('the recentre control', () {
    // The button appears only after the rider has moved the camera, because a
    // control offering to fix a map that is not broken invites a tap that does
    // nothing. The "appears" half needs a native map engine to drive a camera
    // event, so only the absent-by-default half is asserted here; the on-screen
    // half was checked on a handset.
    testWidgets('is absent until the camera has moved', (tester) async {
      RideMap.disabledForTest = true;
      addTearDown(() => RideMap.disabledForTest = false);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: RideMap(
            key: Key('m'),
            pickup: GeoPoint(5.55692, -0.172147),
            dropoff: GeoPoint(5.6052, -0.166),
            interactive: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('routeRecentreButton')), findsNothing);
    });

    testWidgets('a map that cannot be moved never offers to be recentred', (
      tester,
    ) async {
      // `interactive: false` means the gestures are off, so the rider cannot move
      // the camera off the route and a recentre control could only ever be
      // decoration.
      RideMap.disabledForTest = true;
      addTearDown(() => RideMap.disabledForTest = false);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: RideMap(
            key: Key('m'),
            pickup: GeoPoint(5.55692, -0.172147),
            dropoff: GeoPoint(5.6052, -0.166),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('routeRecentreButton')), findsNothing);
    });
  });
}
