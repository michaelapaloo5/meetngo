import 'package:flutter/foundation.dart';
import 'package:mng_core/mng_core.dart';

import 'navigation_controller.dart';

/// Holds the navigation controller for the trip currently on screen.
///
/// ## Why this is not a field on the trip screen
///
/// `ActiveTripScreen` is a `StatelessWidget`, and navigation has to outlive a
/// build: the controller holds the route, the last-spoken step index, the stuck
/// timer and the last position along the line, and rebuilding a screen drops every
/// one of those. That would restart the voice mid-sentence and re-announce the
/// first instruction on every position fix.
///
/// The shell owns it, for the same reason it owns the contact controller: the
/// shell outlives the screen, and it is the only thing that knows when a trip ends
/// and the navigation should be dropped. `_contactFor` is the existing precedent
/// and this follows it rather than inventing a second pattern.
///
/// ## Why it is a ChangeNotifier
///
/// So the banner rebuilds when the route or the current step changes, without the
/// trip screen rebuilding the map. The map redraws on every position fix and the
/// banner changes a few times per minute; sharing one notifier would put the
/// hundred-per-minute rebuild on the banner too.
class NavigationHost extends ChangeNotifier {
  NavigationHost({RouteRepository? repository, SpeechPort? speech, DateTime Function()? clock})
    : _repository = repository,
      _speech = speech,
      _clock = clock;

  RouteRepository? _repository;
  final SpeechPort? _speech;
  final DateTime Function()? _clock;

  NavigationController? _controller;

  /// The controller, or null before navigation has been started.
  NavigationController? get controller => _controller;

  bool get isRunning => _controller != null;

  void attach(RouteRepository repository) => _repository = repository;

  /// Start (or restart) navigation to [destination] from [at].
  ///
  /// Reuses the existing controller when there is one, so the driver's voice
  /// setting survives a re-route and the banner does not flicker back to "working
  /// out the route".
  Future<void> start({required GeoPoint at, required GeoPoint destination}) async {
    final repo = _repository;
    if (repo == null) return;
    final existing = _controller;
    if (existing == null) {
      _controller = NavigationController(
        from: at,
        to: destination,
        speech: _speech,
        clock: _clock,
      )..attach(repo);
    } else if (existing.to_ != destination) {
      // A destination change is the rider getting in. Retargeting rather than
      // making a new controller keeps the driver's voice setting, and a navigator
      // that has no route for one destination has no reason to believe it has none
      // for the next.
      existing.retarget(destination);
      existing.from = at;
    } else {
      existing.from = at;
    }
    notifyListeners();
    await _controller!.start(at: at);
  }

  /// Feed one position update. Silent when navigation is not running, so the
  /// shell's poll can call this unconditionally.
  Future<void> onMoved(GeoPoint point) async {
    await _controller?.onMoved(point);
  }

  void setSpeaking(bool on) {
    _controller?.setSpeaking(on);
    notifyListeners();
  }

  bool get speakInstructions => _controller?.speakInstructions ?? false;

  /// Drop the route. Called when the trip ends, so the next trip does not inherit
  /// the last one's destination.
  void stop() {
    if (_controller == null) return;
    _controller = null;
    notifyListeners();
  }
}