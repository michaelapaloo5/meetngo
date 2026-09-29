import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:meetngo_driver/src/location/location_controller.dart';
import 'package:mng_core/mng_core.dart';

import '../support/fakes.dart';

void main() {
  late StubLocationReader reader;
  late StubDriverRepository drivers;
  late LocationController controller;

  setUp(() {
    reader = StubLocationReader();
    drivers = StubDriverRepository();
    controller = LocationController(reader, drivers);
  });

  group('the four answers become four different sentences', () {
    // The controller's own claim is that a driver can tell which of these they
    // are, because each state names a different thing to do. Two states sharing
    // a message would make the screen actively unhelpful, so each is asserted
    // for its own wording rather than for "some message".

    test('nothing asked yet says nothing at all', () {
      expect(controller.status, DriverLocationStatus.idle);
      expect(controller.message, isNull);
      expect(controller.hasFix, isFalse);
    });

    test('location switched off says where to switch it on', () async {
      reader.serviceEnabled = false;
      await controller.refresh();

      expect(controller.status, DriverLocationStatus.serviceOff);
      expect(controller.message, contains('switched off'));
      expect(controller.message, contains('Turn it on'));
    });

    test('a refused permission says so and names Settings', () async {
      reader.permission = LocationPermission.denied;
      reader.requested = LocationPermission.denied;
      await controller.refresh();

      expect(controller.status, DriverLocationStatus.denied);
      expect(controller.message, contains('not allowed'));
      expect(controller.message, contains('Settings'));
    });

    test('a permanent refusal names the exact path back', () async {
      // Different from a plain refusal, and deliberately so: the OS will not
      // show the prompt again, so "allow it in Settings" is the only advice
      // that can actually work.
      reader.permission = LocationPermission.deniedForever;
      await controller.refresh();

      expect(controller.status, DriverLocationStatus.deniedForever);
      expect(controller.message, contains('blocked'));
      expect(controller.message, contains('Permissions'));
    });

    test('a permitted device with no fix tells the driver to wait or move', () async {
      reader.pointThrows = TimeoutException('no satellite');
      await controller.refresh();

      expect(controller.status, DriverLocationStatus.noFix);
      expect(controller.message, contains('Still looking'));
      expect(controller.message, contains('Step outside'));
    });

    test('an outright failure is not dressed up as a wait', () async {
      // Different advice from a timeout: a timeout means the phone is still
      // looking and the driver should wait; a failure means the plugin could
      // not be asked, and waiting will not help.
      reader.pointThrows = StateError('platform channel dead');
      await controller.refresh();

      expect(controller.status, DriverLocationStatus.noFix);
      expect(controller.message, contains('Still looking'));
    });

    test('a failure elsewhere names the cause', () async {
      reader.checkPermissionThrows = StateError('boom');
      await controller.refresh();

      expect(controller.status, DriverLocationStatus.failed);
      expect(controller.message, contains('boom'));
    });
  });

  group('the order the checks run in', () {
    test('location off is never followed by a permission prompt', () async {
      // A driver with location switched off can be prompted for a permission
      // they will never use, and the prompt's answer would then be the only
      // thing on screen explaining a map that is empty for a different reason.
      reader.serviceEnabled = false;
      await controller.refresh();

      expect(reader.checkCalls, 0);
      expect(reader.requestCalls, 0);
    });

    test('a driver who has said no is asked again, and the app says where to undo it', () async {
      // The platform is asked each time, because `denied` means the prompt is
      // still allowed and the OS throttles a dialog dismissed a moment ago.
      // What the app owes the driver is the sentence pointing at Settings,
      // which is the only thing that can change the answer.
      reader.permission = LocationPermission.denied;
      reader.requested = LocationPermission.denied;
      await controller.refresh();
      await controller.refresh();

      expect(reader.requestCalls, 2);
      expect(controller.message, contains('Settings'));
    });

    test('a driver who said no and then said yes goes online', () async {
      reader.permission = LocationPermission.denied;
      reader.requested = LocationPermission.whileInUse;
      await controller.refresh();

      expect(controller.status, DriverLocationStatus.ready);
      expect(controller.hasFix, isTrue);
    });

    test('a device that will not say is treated as a refusal, not as unknown', () async {
      reader.permission = LocationPermission.unableToDetermine;
      await controller.refresh();

      expect(controller.status, DriverLocationStatus.denied);
    });

    test('a permanent refusal never asks for a fix', () async {
      reader.permission = LocationPermission.deniedForever;
      await controller.refresh();

      expect(reader.pointCalls, 0);
    });
  });

  group('a fix is published so the matcher can see the driver at all', () {
    // `match_offers_for_trip` requires a `driver_locations` row. A driver the
    // map can draw is not automatically a driver the matcher can see, so this
    // write is what makes going online mean anything.

    test('a fix is written to driver_locations', () async {
      await controller.refresh();

      expect(drivers.updateLocationCalls, 1);
      expect(drivers.lastLocation, const GeoPoint(5.6037, -0.1870));
    });

    test('a write that fails does not un-ready the position', () async {
      // The driver genuinely is where the map says; the write is the only
      // thing lost. Reporting a location failure would send them to fix
      // something that is not broken.
      drivers.locationWriteFails = true;
      await controller.refresh();

      expect(controller.status, DriverLocationStatus.ready);
      expect(controller.hasFix, isTrue);
      expect(controller.failure, contains('could not be published'));
    });

    test('nothing is published when there is no fix', () async {
      reader.pointThrows = TimeoutException('no satellite');
      await controller.refresh();

      expect(drivers.updateLocationCalls, 0);
    });

    test('nothing is published when the permission was refused', () async {
      reader.permission = LocationPermission.deniedForever;
      await controller.refresh();

      expect(drivers.updateLocationCalls, 0);
    });
  });

  group('the compass heading is published with the position', () {
    test('a fix with a heading publishes both', () async {
      // This is the whole point of the heading: it is what the rider's map
      // rotates their car by, and the only place it can come from is here.
      reader.heading = 135;
      await controller.refresh();

      expect(controller.status, DriverLocationStatus.ready);
      expect(controller.heading, 135);
      expect(drivers.lastLocation, const GeoPoint(5.6037, -0.1870));
      expect(drivers.lastHeading, 135);
    });

    test('a device with no compass still goes online, with no heading', () async {
      // A phone flat on a seat, a tablet indoors, a simulator. All ordinary.
      // If a missing compass took the driver offline, the app would be unusable
      // for a large share of the devices it runs on.
      reader.heading = null;
      await controller.refresh();

      expect(controller.status, DriverLocationStatus.ready);
      expect(controller.point, isNotNull);
      expect(controller.heading, isNull);
      // The position is still published; only the heading is absent.
      expect(drivers.lastLocation, isNotNull);
      expect(drivers.lastHeading, isNull);
    });

    test('a compass that throws is not a location failure', () async {
      // Separate from "no compass": the plugin could not be reached. The
      // position is good and the driver is online; only the heading is lost.
      reader.headingThrows = StateError('no magnetometer');
      await controller.refresh();

      expect(controller.status, DriverLocationStatus.ready);
      expect(controller.point, isNotNull);
      expect(controller.heading, isNull);
      expect(drivers.lastLocation, isNotNull);
    });

    test('a heading of -1 means "no compass", not "one degree past north"', () async {
      // The plugin's own "I have no compass" value. Taken at face value it
      // would rotate a car to 359 degrees, which looks like the car is
      // reversing down the road it is driving along.
      reader.heading = -1;
      await controller.refresh();

      expect(controller.heading, isNull);
      expect(drivers.lastHeading, isNull);
    });

    test('the heading is refreshed on every read, not only the first', () async {
      // A driver stopped at lights turns on the spot. A controller that kept
      // the first heading would leave their rider watching a car pointing the
      // way it was facing when it arrived.
      reader.heading = 0;
      await controller.refresh();
      expect(drivers.lastHeading, 0);

      reader.heading = 270;
      await controller.refresh();

      expect(controller.heading, 270);
      expect(drivers.lastHeading, 270);
    });

    test('a refresh that never reaches a fix leaves the heading alone', () async {
      reader.heading = 45;
      await controller.refresh();
      expect(controller.heading, 45);

      // The next attempt fails to get a position, so there is nothing to
      // publish and no reason to believe a stale heading is still current --
      // but it is still the best answer available, and blanking it would make
      // the car spin to north on the rider's map for no stated reason.
      reader.pointThrows = StateError('no fix');
      await controller.refresh();

      expect(controller.status, DriverLocationStatus.noFix);
      expect(controller.heading, 45);
    });
  });

  group('what the driver is told about the permission they hold', () {
    // Without this the one case where the app deliberately holds a position in
    // the background without saying so is invisible.

    test('while-in-use is spelled out', () async {
      reader.permission = LocationPermission.whileInUse;
      await controller.refresh();

      expect(controller.permissionNote, contains('only while'));
    });

    test('always is spelled out as background sharing', () async {
      reader.permission = LocationPermission.always;
      await controller.refresh();

      expect(controller.permissionNote, contains('at all times'));
    });

    test('no note for a device that has not answered', () {
      expect(controller.permissionNote, isNull);
    });
  });

  group('concurrent refreshes', () {
    test('a second refresh while one is running is ignored', () async {
      // A screen that refreshes on a pull gesture and on a button can ask
      // twice at once. Two parallel chains would race on `_point` and could
      // interleave a `serviceOff` from one with a `ready` from the other.
      final gate = Completer<void>();
      reader.gatePoint = gate.future;

      final first = controller.refresh();
      await Future<void>.delayed(Duration.zero);
      await controller.refresh(); // Ignored: `_busy` is set by the first.

      gate.complete();
      await first;

      expect(reader.pointCalls, 1);
      expect(drivers.updateLocationCalls, 1);
    });

    test('busy is cleared even when the chain throws', () async {
      // Otherwise one failure would wedge the controller for the life of the
      // app and every later refresh would be silently dropped.
      reader.checkPermissionThrows = StateError('boom');
      await controller.refresh();

      expect(controller.busy, isFalse);
    });
  });

  group('listeners', () {
    test('a refresh notifies as the state changes, not only at the end', () async {
      // A screen that only rebuilds at the end shows a stale banner for the
      // whole chain; one that rebuilds on every notify can show "Finding your
      // location" honestly.
      var notifications = 0;
      controller.addListener(() => notifications++);

      await controller.refresh();

      expect(notifications, greaterThan(1),
          reason: 'asking, ready, and the final notify');
    });
  });
}
