import 'package:flutter/material.dart';
import 'package:mng_core/mng_core.dart';

import 'ride_map.dart';

/// The button that puts the camera back on the rider.
///
/// Exists because the map is not something a rider is *given* on these screens:
/// the finding-driver map is full-bleed and draggable, and the route page's
/// picker is draggable and zoomable, so a rider who has panned away to look at
/// something has no way back except the gesture they already know is inverted.
/// Uber and Bolt both put this on every map, and they are right: a map that can
/// be moved and cannot be recentred is a map that can be lost.
///
/// Not drawn at all without a fix, rather than drawn disabled. A greyed-out
/// button tells a rider it exists and cannot be used, which invites a second tap
/// and then a support question; the map's own location note already says *why*
/// there is no position, in the sentence that tells them what to do about it.
/// A button that is absent and a note that explains it is one message; a dead
/// button plus a note is two.
///
/// The refusal to be tapped-and-forgotten matters more here than on almost any
/// other control. This button's whole promise is "go back to me", so a press
/// that silently does nothing is the worst version of this feature.
class LiveLocationButton extends StatefulWidget {
  const LiveLocationButton({super.key, required this.mapKey, required this.point});

  /// The map to move.
  ///
  /// A `GlobalKey` rather than a `RideMapState`, and that is not a style
  /// choice. A parent builds *before* its children, so `key.currentState` is
  /// still null in the first frame and only becomes non-null once the map
  /// underneath has been built. A parent that passed the state down would
  /// therefore hand over null and — nothing else changing — never rebuild, so
  /// the button would be permanently unbound. The button reads the key itself
  /// and asks for another frame until the state turns up.
  final GlobalKey<RideMapState>? mapKey;

  /// Where "me" is. Null means there is no fix and nothing is drawn.
  final GeoPoint? point;

  /// How far above the bottom edge the button sits.
  ///
  /// Clear of the OS gesture bar and of the attribution strip along the bottom
  /// of the map, which is there because the OpenStreetMap tile usage policy
  /// requires it visible rather than behind a tap.
  static const double bottomInset = 88;

  static const double size = 44;

  /// How many extra frames to wait for the map's state to appear.
  ///
  /// Bounded because an unbounded retry is an infinite frame loop, and five
  /// frames is several hundred milliseconds — far longer than a native map view
  /// takes, and short enough that a rider has not finished the tap they were
  /// about to make.
  static const int maxBindingFrames = 5;

  @override
  State<LiveLocationButton> createState() => _LiveLocationButtonState();
}

class _LiveLocationButtonState extends State<LiveLocationButton> {
  /// Frames spent waiting for the map. Reset when the key changes, so a screen
  /// that swaps one map for another gets a fresh chance.
  int _waited = 0;

  RideMapState? get _map => widget.mapKey?.currentState;

  @override
  void didUpdateWidget(LiveLocationButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mapKey != widget.mapKey) _waited = 0;
  }

  /// Asks for one more frame while the map has not registered yet.
  ///
  /// `setState` from inside `build` is not allowed, so the rebuild is scheduled
  /// for after the frame rather than done inline.
  void _keepWaiting() {
    if (_map != null || _waited >= LiveLocationButton.maxBindingFrames) return;
    _waited++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final here = widget.point;
    // Nothing to centre on, so nothing is drawn at all. The map's own note
    // says why; see the class doc.
    if (here == null) return const SizedBox.shrink();

    _keepWaiting();
    final ready = _map?.isReady ?? false;

    return Padding(
      padding: const EdgeInsets.only(bottom: LiveLocationButton.bottomInset),
      child: Align(
        alignment: Alignment.bottomRight,
        child: Padding(
          padding: const EdgeInsets.only(right: 16),
          child: Semantics(
            button: true,
            enabled: ready,
            label: ready
                ? 'Centre the map on your location'
                : 'Centre the map on your location. The map is still loading.',
            child: Material(
              color: MngColors.surface,
              elevation: 3,
              shadowColor: Colors.black26,
              borderRadius: BorderRadius.circular(MngRadius.small),
              child: InkWell(
                key: const Key('liveLocationButton'),
                borderRadius: BorderRadius.circular(MngRadius.small),
                onTap: ready ? () => _recentre(context, here) : null,
                child: SizedBox(
                  width: LiveLocationButton.size,
                  height: LiveLocationButton.size,
                  child: Icon(
                    Icons.my_location,
                    size: 20,
                    color: ready ? MngColors.textPrimary : MngColors.textSub,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Moves the camera, and says so when it could not.
  Future<void> _recentre(BuildContext context, GeoPoint here) async {
    // The messenger is resolved before the await: a `BuildContext` is not safe
    // to use across an async gap if the screen has since been popped, and a pop
    // is the likely outcome when a rider backs out mid-animation.
    final messenger = ScaffoldMessenger.maybeOf(context);
    final state = _map;
    if (state == null) {
      _say(messenger, 'The map is still loading. Try again in a moment.');
      return;
    }
    if (!await state.recenterOn(here)) {
      _say(messenger, 'The map is still loading. Try again in a moment.');
    }
  }

  void _say(ScaffoldMessengerState? messenger, String message) {
    messenger?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }
}
