import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

import 'face_reading.dart';
import 'liveness_detector.dart';
import 'liveness_verifier.dart';

/// Turns the camera into [FaceReading]s and drives a [LivenessVerifier].
///
/// Everything platform-shaped lives here, so that nothing platform-shaped is in
/// the decision-making.
///
/// ## How a frame reaches the detector
///
/// From a still on disk, by way of `takePicture`, at about 3Hz. That is not the
/// obvious design and the reasons are worth writing down, because the obvious
/// one cost several build cycles.
///
/// The obvious route is a CameraX image stream straight into a detector, at
/// 30Hz. It was tried first and does not work, for two separate reasons.
///
/// The first was ML Kit. `InputImage.fromBytes` is the only way a live frame
/// reaches it, and it is broken in the versions available here: decompiling
/// `vision-common` shows `fromByteArray` delegating to
/// `InputImage(ByteBuffer, int, int, int, int)`, whose format check accepts
/// **only** NV21 (17) and YV12 (842094169). `YUV_420_888` (35), which is what a
/// camera actually delivers, falls through to `Preconditions.checkArgument
/// (false)` -- a bare `IllegalArgumentException` with no message. Asking for
/// NV21 does get a correct frame past that check, and it then fails one layer
/// deeper with a `NullPointerException` in Google's own runtime, as does
/// `fromFilePath`, and as does the plugin on both of its versions, and as does a
/// thirty-line MethodChannel calling the same native API with the marshalling
/// removed entirely. That is what ended it: the fault was not in anything the
/// app passed in.
///
/// ML Kit is gone, so the first reason no longer applies.
///
/// The second reason still does, and it is the one that keeps this at 3Hz. Each
/// still now costs a full JPEG encode, a full decode, a mesh pass and an
/// anti-spoof pass -- about 8 ms plus about 12 ms, on top of camera latency. The
/// camera is configured for NV21 for exactly the reason above, and
/// `face_detection_tflite`'s own `detectFacesFromCameraImage` would take the
/// YUV stream directly, so streaming is available. It is not used because a
/// 3Hz sampler is what [LivenessChallenge] and [LivenessVerifier] are built and
/// tested against, and 30Hz would change the meaning of every threshold in
/// there. Changing the sample rate is a deliberate decision with its own tests,
/// not something to arrive at by accident while replacing a camera library.
///
/// Every consequence of 3Hz is accounted for in [start] and in
/// [liveCapableChallenges].
class LivenessSession {
  LivenessSession({required this.verifier, LivenessDetector? detector})
    : _detector = detector ?? LivenessDetector();

  final LivenessVerifier verifier;

  final LivenessDetector _detector;
  CameraController? _controller;
  Timer? _timer;

  /// True while a still is being captured and analysed, so the next tick is
  /// skipped rather than queued. A backlog of stills judged long after they
  /// were taken is a liveness check assessing the past, and the queue grows
  /// without bound when capture is slower than the tick -- which it is.
  bool _busy = false;
  bool _disposed = false;

  /// Set when the camera or the detector refused.
  ///
  /// Surfaced rather than swallowed: a driver left watching a screen that never
  /// advances has no way to tell a broken check from a broken phone.
  String? error;

  /// The still taken on the frame that passed, for the admin to compare against
  /// the licence photo.
  ///
  /// It is the picture the check was actually judged on, not a second capture
  /// afterwards. Taken separately it would be a different instant, a different
  /// expression, and one more thing that can fail on a driver who has just
  /// passed.
  File? proofFrame;

  /// Whether a camera is ready to be analysed.
  ///
  /// Readiness is `isInitialized` and nothing else. In particular it is **not**
  /// `isStreamingImages`: `startImageStream` is what makes a controller
  /// streaming, so a guard that tests for streaming is testing for the thing
  /// this method is about to do, is therefore always false, and silently stops
  /// the check from ever running.
  ///
  /// That is not hypothetical. It is what the first version did, found on the
  /// device: the screen opened, the preview was live and correct, and the
  /// detector never received a single frame, so a driver sat being asked to
  /// tilt their head by a check that was not running. Nothing in the widget
  /// tests could see it, because a real `CameraController` cannot be built in a
  /// test, which is the whole reason this is a one-line predicate.
  @visibleForTesting
  static bool canStart(bool isInitialized) => isInitialized;

  void attach(CameraController controller) => _controller = controller;

  /// Starts sampling. The camera must already be initialised and ready.
  ///
  /// [intervalMs] is the gap between samples: 350ms is about 3Hz, which is what
  /// a hardware still costs on a budget phone and still fast enough to watch a
  /// 20-degree head turn happen.
  ///
  /// 3Hz is also why a blink is not one of the challenges. A blink lasts a few
  /// hundred milliseconds; a 3Hz sampler misses most of them. Asking for one
  /// would fail drivers who did it perfectly, intermittently, with no visible
  /// cause -- the worst kind of verification bug there is.
  Future<void> start({int intervalMs = 350}) async {
    final controller = _controller;
    if (controller == null || !canStart(controller.value.isInitialized)) {
      error = 'The camera is not ready yet.';
      return;
    }
    _timer?.cancel();
    _timer = Timer.periodic(
      Duration(milliseconds: intervalMs),
      (_) => unawaited(_sample()),
    );
  }

  /// Captures one still, judges it, and throws the file away.
  Future<void> _sample() async {
    final controller = _controller;
    if (controller == null || _busy || _disposed) return;
    if (!canStart(controller.value.isInitialized)) return;

    _busy = true;
    File? shot;
    try {
      final xFile = await controller.takePicture();
      shot = File(xFile.path);
      // One read of the still, two readings out of it: the mesh and the
      // anti-spoof score are computed from the same bytes. Asking the detector
      // twice would mean two decodes of the same file and two chances for the
      // driver to move between the two judgements, which is a check deciding
      // whether a face was real at two different instants.
      final detection = await _detector.detect(shot.path, at: DateTime.now());
      if (_disposed) return;
      // Cleared on the first still that reads. Left set, one dropped frame
      // during a check would show a red message for the rest of it, and a
      // driver who reads that has stopped trying.
      error = _detector.error;
      verifier.observe(detection.face.withSpoof(detection.spoof.score));
      if (verifier.outcome == LivenessOutcome.passed && proofFrame == null) {
        // Kept rather than deleted: the upload needs it, and the verdict is
        // about this instant and no other.
        proofFrame = shot;
        shot = null;
      }
    } on Object catch (e, st) {
      error = 'The camera could not be read. Try again.';
      // Logged, not gated on `kDebugMode`: gating it on that looked tidy and
      // was exactly wrong, because it made the one failure nobody can reproduce
      // on a desk invisible on every real build.
      debugPrint('liveness: still could not be read: $e\n  $st');
    } finally {
      _busy = false;
      // Every still is deleted except the one kept as proof. They land in the
      // app's own cache, and a check sampled at 3Hz for a minute is a couple of
      // hundred files of somebody's face that nobody asked to keep.
      final leftover = shot;
      if (leftover != null) {
        unawaited(leftover.delete().catchError((Object _) => leftover));
      }
    }
  }

  /// The camera rotation, for the overlay and for any coordinate mapping.
  ///
  /// `sensorOrientation` is the sensor's angle and the device rotation is how
  /// far the phone has been turned since; they compose. The front camera's
  /// image is mirrored relative to the sensor and the back camera's is not,
  /// which is why they differ by a quarter turn from each other.
  ///
  /// A named lookup and not a bare `~/ 90`, because the result indexes an enum
  /// and an out-of-range integer there is a range error on a driver's phone
  /// rather than a wrong-but-working answer.
  static int degreesFor(CameraDescription d) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return ((d.sensorOrientation + 90) % 360) ~/ 90 * 90;
    }
    final device = d.lensDirection == CameraLensDirection.front
        ? (d.sensorOrientation - 90) % 360
        : (d.sensorOrientation + 90) % 360;
    final wrapped = device < 0 ? device + 360 : device;
    return wrapped ~/ 90 * 90;
  }

  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    await _detector.close();
  }
}
