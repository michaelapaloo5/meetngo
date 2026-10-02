import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';
import 'package:meetngo_driver/src/active_trip/active_trip_controller.dart';
import 'package:meetngo_driver/src/active_trip/active_trip_screen.dart';
import 'package:meetngo_driver/src/chat/chat_controller.dart';
import 'package:meetngo_driver/src/chat/chat_screen.dart';
import 'package:meetngo_driver/src/contact/contact_controller.dart';
import 'package:meetngo_driver/src/location/location_controller.dart';
import 'package:meetngo_driver/src/map/driver_map_panel.dart';
import 'package:meetngo_driver/src/map/fullscreen_map_screen.dart';
import 'package:provider/provider.dart';

import '../support/fakes.dart';
import '../support/harness.dart';

/// The two things on the trip screen that used to be invisible, and one of them
/// used to be invisible because of a bug rather than a decision.
///
/// ## Messages
///
/// `_openChat` read `ContactController` out of the provider tree to label the
/// thread with the rider's name. There is no `Provider<ContactController>` in
/// this app -- the controller is an argument to this screen, so the screen can be
/// built in a test with no Supabase client at all. Every tap therefore threw
/// `ProviderNotFoundException` on the line before the push.
///
/// It looked untested because it was untested: grep for `chatRiderButton`
/// returned nothing, so a screen with a button on it that had never once been
/// pressed sat under 633 green tests.
///
/// ## The map
///
/// The panel is 200 pixels tall on the trip screen. The junction the driver is
/// about to take is below the bottom of it, so the panel is a thumbnail and
/// tapping it opens the same panel with the height taken off.
class _RecordingChat implements ChatRepository {
  final opened = <String>[];

  @override
  Stream<List<ChatMessage>> messages(String tripId) {
    opened.add(tripId);
    return Stream<List<ChatMessage>>.value(const <ChatMessage>[]);
  }

  @override
  Future<void> send({required String tripId, required String body}) async {}
}

Widget wrap(ActiveTripController c, {ChatRepository? chat, Contact? contact}) {
  final controller = ContactController(_NoNumber())..adopt(contact);
  return appHarness(
    ChangeNotifierProvider<ActiveTripController>.value(
      value: c,
      child: ActiveTripScreen(
        onFinished: () {},
        location: LocationController(
          StubLocationReader(point: const GeoPoint(5.6037, -0.1870)),
          StubDriverRepository(),
        ),
        contact: controller,
        chatRepository: chat ?? _RecordingChat(),
        driverId: 'driver-1',
      ),
    ),
  );
}

class _NoNumber implements ContactRepository {
  @override
  Future<Contact?> contactFor(String tripId) async => null;
}

ActiveTripController liveTrip() =>
    ActiveTripController(StubDriverRepository())
      ..trip = tripIn(TripState.matched);

void main() {
  setUpAll(() => DriverMapPanel.disabledForTest = true);
  tearDownAll(() => DriverMapPanel.disabledForTest = false);

  group('messages open', () {
    testWidgets('tapping Message rider opens the thread', (tester) async {
      await tester.pumpWidget(wrap(liveTrip()));
      await tester.pump();

      expect(find.byType(ChatScreen), findsNothing);
      await tester.tap(find.byKey(const Key('chatRiderButton')));
      await tester.pumpAndSettle();

      expect(
        find.byType(ChatScreen),
        findsOneWidget,
        reason:
            'the push happens after the rider name is resolved, so a throw '
            'in resolving it means the driver taps a button and nothing happens',
      );
    });

    testWidgets('the thread is labelled with the rider, not a uuid', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          liveTrip(),
          contact: Contact(
            role: ContactRole.rider,
            phone: '+233201234567',
            callable: true,
            name: 'Michael',
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('chatRiderButton')));
      await tester.pumpAndSettle();

      expect(find.text('Michael'), findsOneWidget);
    });

    testWidgets('the thread is still reachable when the rider has no number', (
      tester,
    ) async {
      // The case that matters most. A rider with no phone on file has no name
      // either, so `contact.contact` is null and the label falls back. If the
      // label were not here -- or were a provider read that throws -- this
      // button would be dead exactly for the drivers who most need another way
      // to reach the rider.
      await tester.pumpWidget(wrap(liveTrip()));
      await tester.tap(find.byKey(const Key('chatRiderButton')));
      await tester.pumpAndSettle();

      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.text('Rider'), findsOneWidget);
    });

    testWidgets('with no repository the screen says so rather than opening', (
      tester,
    ) async {
      final controller = ContactController(_NoNumber());
      await tester.pumpWidget(
        appHarness(
          ChangeNotifierProvider<ActiveTripController>.value(
            value: liveTrip(),
            child: ActiveTripScreen(
              onFinished: () {},
              location: LocationController(
                StubLocationReader(point: const GeoPoint(5.6037, -0.1870)),
                StubDriverRepository(),
              ),
              contact: controller,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('chatRiderButton')));
      await tester.pump();

      expect(find.byType(ChatScreen), findsNothing);
      expect(find.textContaining('Messages are not available'), findsOneWidget);
    });
  });

  group('the map opens full screen', () {
    testWidgets('tapping the panel pushes the full-screen map', (tester) async {
      await tester.pumpWidget(wrap(liveTrip()));
      await tester.pump();

      expect(find.byType(FullscreenMapScreen), findsNothing);
      await tester.tap(find.byKey(const Key('expandMapGesture')));
      await tester.pumpAndSettle();

      expect(find.byType(FullscreenMapScreen), findsOneWidget);
      // The whole point: bigger than the 200-pixel strip it was tapped from.
      final full = tester.getSize(find.byKey(const Key('fullscreenDriverMap')));
            // skipOffstage: false, because the strip is underneath the pushed route
      // and therefore offstage -- which is exactly the pair of panels this test
      // is comparing.
      final strip = tester.getSize(
        find.byKey(const Key('tripStripMap'), skipOffstage: false),
      );
      expect(full.height, greaterThan(strip.height));
    });

    testWidgets('the full-screen map carries the same points', (tester) async {
      // A second map implementation is how the two end up disagreeing about
      // where the driver is, so the larger one is the same widget with the
      // height taken off.
      await tester.pumpWidget(wrap(liveTrip()));
      await tester.pump();
      await tester.tap(find.byKey(const Key('expandMapGesture')));
      await tester.pumpAndSettle();

      final full = tester.widget<DriverMapPanel>(
        find.byKey(const Key('fullscreenDriverMap')),
      );
      final strip = tester.widget<DriverMapPanel>(
        find.byKey(const Key('tripStripMap'), skipOffstage: false),
      );
      expect(full.pickup, strip.pickup);
      expect(full.dropoff, strip.dropoff);
      expect(full.driverPoint, strip.driverPoint);
    });

    testWidgets('the full-screen map closes and returns to the trip', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(liveTrip()));
      await tester.pump();
      await tester.tap(find.byKey(const Key('expandMapGesture')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('closeFullscreenMapButton')));
      await tester.pumpAndSettle();

      expect(find.byType(FullscreenMapScreen), findsNothing);
      // Back on the trip screen, with the controls the driver opened the map to
      // think away from.
      expect(find.byKey(const Key('chatRiderButton')), findsOneWidget);
    });

    testWidgets('a panel with no expand callback has no tap layer', (
      tester,
    ) async {
      // The offer queue shows several pins at once and has no larger map to go
      // to, so the affordance is opt-in rather than always on.
      await tester.pumpWidget(
        appHarness(
          DriverMapPanel(
            driverPoint: const GeoPoint(5.6037, -0.1870),
            pickup: const GeoPoint(5.6050, -0.1900),
            dropoff: const GeoPoint(5.6100, -0.1950),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('expandMapGesture')), findsNothing);
    });
  });
}
