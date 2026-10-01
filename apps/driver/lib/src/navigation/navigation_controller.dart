import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mng_core/mng_core.dart';

import 'route_progress.dart';

/// Why a route could not be fetched, in the driver's terms.
class NavigationFailure implements Exception {
  const NavigationFailure(this.message, {this.offline = false});

  final String message;

  /// True when the routing engine could not be reached at all, as opposed to
  /// answering with something unusable.
  final bool offline;

  @override
  String toString() => 'NavigationFailure($message)';
}

/// The default when no [RouteRepository] was provided.
///
/// Refuses every route, for the same reason `NoContactRepository` answers null:
/// the `DriverFlow(...)` calls in the test suite are about offers, earnings and
/// location. A repository that answered with a fabricated route would be worse
/// than one that refuses, because the banner would then show confident directions
/// to nowhere.
class NoRouteRepository implements RouteRepository {
  const NoRouteRepository();

  @override
  Future<TripRoute> route(GeoPoint from, GeoPoint to) async {
    throw const NavigationFailure('Directions are not available right now.');
  }
}

/// Where routes come from.
abstract class RouteRepository {
  /// A route from [from] to [to], or throws a [NavigationFailure].
  Future<TripRoute> route(GeoPoint from, GeoPoint to);
}

/// The one thing this controller needs from a speech engine.
///
/// An interface rather than `flutter_tts` directly, for the same reason everything
/// else here takes a repository: the rules about *when* to speak are the part worth
/// testing, and they should not need a platform channel to be tested. [speak]
/// returns when the utterance has been handed over, not when it has finished --
/// nothing here cares how long a sentence takes.
abstract class SpeechPort {
  Future<void> speak(String text);
  Future<void> stop();
}

/// A [SpeechPort] that says nothing.
///
/// The default, for two reasons. A driver who has not turned voice on should get
/// silence rather than a failure, and a test that forgets to inject a voice should
/// not start talking.
class SilentSpeech implements SpeechPort {
  const SilentSpeech();

  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> stop() async {}
}

/// Drives the screen: fetches a route, follows it, and re-routes when the driver
/// leaves it.
///
/// ## Why the clock is injected
///
/// Two of the three decisions here are time questions rather than geometry
/// questions -- "how long has the driver been stuck" and "what time do they
/// arrive" -- and a widget's own clock makes both untestable without pumping time.
/// So the controller takes a [clock] function and a [speech] port, and every rule
/// about when to re-route and when to speak is a plain unit test.
///
/// ## Why it re-routes at all
///
/// Because the alternative is a driver following a line that is visibly wrong. A
/// banner saying "turn left in 200 m" while the driver is on a road that is not on
/// the route is worse than no banner at all: it is confident, and it is wrong. So
/// the controller watches distance-from-the-line and refetches once it grows past
/// [kOffRouteM], and the screen says "recalculating" while it does.
class NavigationController extends ChangeNotifier {
  NavigationController({
    required this.from,
    required GeoPoint to,
    RouteRepository? repository,
    SpeechPort? speech,
    DateTime Function()? clock,
    this.speakInstructions = false,
  })  : to_ = to,
        _repository = repository,
        _speech = speech ?? const SilentSpeech(),
        _clock = clock ?? DateTime.now;

  /// Where the route starts, and where every *refetch* starts from too.
  ///
  /// Mutable on purpose: after the first fetch the driver has moved, and a route
  /// from the point they set off is a route to somewhere they left.
  GeoPoint from;

  /// Where the route is going.
  ///
  /// Also mutable, because the destination changes mid-trip -- the pickup becomes
  /// the drop-off the moment the rider gets in -- and a navigator that keeps
  /// pointing at the pickup afterwards is sending the driver back where they came
  /// from. Renamed through [retarget] rather than assigned inline, so the two
  /// fields can never be updated in one go and disagree about which is which.
  GeoPoint to_;

  /// Where the route is going.
  GeoPoint get to => to_;

  /// Point the route at a new destination and treat it as a new trip.
  void retarget(GeoPoint destination) {
    to_ = destination;
    _route = null;
    _progress = null;
    _lastSpokenIndex = null;
  }

  /// Whether to voice instructions.
  ///
  /// A flag rather than unconditional because it is the setting a driver turns off
  /// after one loud bus, and a navigator that cannot be silenced gets uninstalled.
  bool speakInstructions;

  RouteRepository? _repository;
  final SpeechPort _speech;
  final DateTime Function() _clock;

  TripRoute? _route;
  RouteProgress? _progress;
  NavigationFailure? _failure;
  bool _loading = false;
  bool _recalculating = false;
  DateTime? _lastMovedAt;
  double _lastAlong = -1;
  int? _lastSpokenIndex;

  TripRoute? get route => _route;

  /// Where the driver is on it and what comes next. Null before the first route.
  RouteProgress? get progress => _progress;

  /// The instruction to show, or null when there is nothing to show yet.
  RouteStep? get currentStep => _progress?.step;

  /// Metres to that instruction.
  double get distanceToStepM => _progress?.distanceToStepM ?? 0;

  NavigationFailure? get failure => _failure;

  /// True during the very first fetch. A later refetch sets [recalculating], which
  /// is a different message: the driver already has a route, and taking it away
  /// would be worse than not refreshing it.
  bool get loading => _loading;

  bool get recalculating => _recalculating;

  /// The clock. Exposed so a banner's arrival time and a controller's stuck
  /// timer read the same instant rather than two `now` calls that can straddle a
  /// minute.
  DateTime get now => _clock();

  DateTime? get arrivalAt =>
      _route == null ? null : now.add(Duration(seconds: _route!.durationS));

  /// How long the driver has been going nowhere along this route.
  int get secondsWithoutProgress {
    final last = _lastMovedAt;
    if (last == null) return 0;
    final seconds = now.difference(last).inSeconds;
    return seconds < 0 ? 0 : seconds;
  }

  void attach(RouteRepository repository) => _repository = repository;

  /// Fetch a route, or fetch it again, and start following it from [at].
  ///
  /// [at] rather than [from] on the refetch path: on the first call the driver is
  /// where they said they were and on every later call they are not.
  Future<void> start({GeoPoint? at}) async {
    final repo = _repository;
    if (repo == null) {
      _failure = const NavigationFailure('Directions are not available right now.');
      _loading = false;
      notifyListeners();
      return;
    }
    final origin = at ?? from;
    final hadRoute = _route != null;
    if (hadRoute) {
      _recalculating = true;
    } else {
      _loading = true;
    }
    notifyListeners();

    try {
      final fetched = await repo.route(origin, to);
      // Fewer than two usable points is not a route, and neither is one that goes
      // nowhere. Asked to route from a point to itself the live function answers
      // **200** with two identical geometry points and two steps of
      // `distanceM: 0`, which passes any two-point test -- and would leave a
      // driver reading "Head out on Otswe Street, 0 m" forever. Measured, not
      // assumed: `toolchain/verify-navigation.mjs` sends identical points and reads
      // the response back.
      if (!fetched.goesAnywhere) {
        _failure = NavigationFailure(
          // A zero-length route means the driver is already where they are
          // going, which is worth saying rather than reporting as a failure to
          // find anything.
          fetched.isUsable
              ? 'You are already there.'
              : 'Could not find a route to that address.',
        );
        _route = null;
        _progress = null;
      } else {
        _route = fetched;
        _failure = null;
        _progress = progressOn(fetched, origin);
        _lastAlong = _progress!.metresAlong;
        _lastMovedAt = now;
        _lastSpokenIndex = null;
        // The first instruction is spoken here, not on the first position fix.
        //
        // Without it a driver who taps Navigate while stationary hears nothing at
        // all -- the banner is populated but the voice is not, and `onMoved` is the
        // only other place that speaks. They are then sitting at a kerb with a
        // silent phone and no way to tell whether it is loading or broken.
        _maybeSpeak(_progress!);
      }
    } on NavigationFailure catch (e) {
      // A failed *refetch* keeps the old route. A driver who has gone off-route and
      // is refused a new one is better off on a stale line than with no line.
      _failure = e;
    } catch (_) {
      _failure = const NavigationFailure('Could not find a route to that address.');
    } finally {
      _loading = false;
      _recalculating = false;
      notifyListeners();
    }
  }

  /// The driver has moved. Update the progress, say the next instruction if it
  /// changed, and re-route if they have left the line.
  ///
  /// Returns true when a refetch was started, so a caller can show the
  /// "recalculating" state without watching the controller for it.
  Future<bool> onMoved(GeoPoint point) async {
    final route = _route;
    if (route == null) return false;

    final next = progressOn(route, point);
    _progress = next;

    // "Moved" means moved *along the route*. Distance from the line growing is a
    // separate signal handled below, and without the distinction a driver driving
    // straight away from the route would read as progressing for as long as there
    // was distance left.
    if ((next.metresAlong - _lastAlong).abs() >= 8) {
      _lastAlong = next.metresAlong;
      _lastMovedAt = now;
    }

    if (shouldReRoute(next, secondsWithoutProgress: secondsWithoutProgress)) {
      await start(at: point);
      return true;
    }

    _maybeSpeak(next);
    notifyListeners();
    return false;
  }

  /// Say the instruction when it changes, and only when it changes.
  ///
  /// Speaking on every position update would repeat the same sentence once a
  /// second for four minutes, which is the most reliable way there is to make a
  /// driver uninstall a navigator.
  void _maybeSpeak(RouteProgress next) {
    if (!speakInstructions) return;
    final step = next.step;
    if (step == null) return;
    if (_lastSpokenIndex == next.stepIndex) return;
    _lastSpokenIndex = next.stepIndex;
    final distance = formatDistance(next.distanceToStepM);
    final spoken = distance == '--'
        ? step.instruction
        : 'In $distance, ${_lowerFirst(step.instruction)}';
    unawaited(_speech.speak(spoken));
  }

  static String _lowerFirst(String s) =>
      s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);

  /// Turn the voice off or on, and stop talking when it goes off.
  ///
  /// The stop is the part that is easy to leave out: a driver who turns the voice
  /// off while the last instruction is still being spoken hears it finish and
  /// concludes the button did not work.
  void setSpeaking(bool on) {
    speakInstructions = on;
    if (!on) unawaited(_speech.stop());
    notifyListeners();
  }
}