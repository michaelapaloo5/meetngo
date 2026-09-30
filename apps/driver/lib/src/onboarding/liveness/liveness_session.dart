import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'face_reading.dart';
import 'liveness_verifier.dart';

/// Turns the camera into [FaceReading]s and drives a [LivenessVerifier].
///
/// Everything platform-shaped lives here, so that nothing platform-shaped is in
/// the decision-making.
///
/// ## How frames reach the detector, and why it is this way
///
/// The obvious route -- a CameraX image stream into `InputImage.fromBytes` --
/// does not work, and the reason is worth writing down because it cost several
/// build cycles to find.
///
/// `InputImage.fromBytes` is the only way a live frame reaches ML Kit, and in
/// `vision-common` 17.3.0 it is broken. Decompiling the AAR shows
/// `fromByteArray` delegating to `InputImage(ByteBuffer, int, int, int, int)`,
/// and that constructor's format check accepts **only** NV21 (17) and YV12
/// (842094169); `YUV_420_888` (35), which is what the camera actually
/// delivers, falls through to `Preconditions.checkArgument(false)` -- a bare
/// `IllegalArgumentException` with no message. Two earlier theories, the
/// rotation and the row stride, were both wrong.
///
/// Asking the camera for NV21 does get a correct frame through that first
/// check -- one plane, raw 17, 541,392 bytes for a 720x480 stream. It then
/// fails one layer deeper, in the native validator, with a
/// `NullPointerException` on every frame. That is where this stopped being a
/// formatting problem and became a broken dependency.
///
/// So frames come from `takePicture` and `InputImage.fromFilePath`, which is a
/// documented, supported, first-class entry point. It costs a hardware JPEG per
/// sample rather than a buffer copy, and every consequence of that is
/// accounted for in the interval and in the challenges that get asked. See
/// [LivenessSession.start] and [LivenessChallenge].
class LivenessSession {
  LivenessSession({required this.verifier});

  final LivenessVerifier verifier;

  CameraController? _controller;
  FaceDetector? _detector;
  Timer? _timer;

  /// True while a still is being captured and analysed, so the next tick is
  /// skipped rather than queued. A backlog of stills judged long after they
  /// were taken is a liveness check assessing the past, and the queue grows
  /// without bound when capture is slower than the tick -- which it is.
  bool _busy = false;
  bool _disposed = false;

  /// Set when the camera or the detector refused.
  ///
  /// Surfaced rather than swallowed: a driver left watching a screen that
  /// never advances has no way to tell a broken check from a broken phone.
  String? error;

  /// The still taken on the frame that passed, for the admin to compare
  /// against the licence photo.
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
  /// tests could see it, because a real `CameraController` cannot be built in
  /// a test, which is the whole reason this is a one-line predicate.
  @visibleForTesting
  static bool canStart(bool isInitialized) => isInitialized;

  void attach(CameraController controller) => _controller = controller;

  /// Starts sampling. The camera must already be initialised and ready.
  ///
  /// [intervalMs] is the gap between samples: 350ms is about 3Hz, which is
  /// what a hardware still costs on a budget phone and still fast enough to
  /// watch a 20-degree head turn happen.
  ///
  /// 3Hz is also the reason a blink is not one of the challenges. A blink lasts
  /// a few hundred milliseconds; a 3Hz sampler misses most of them. Asking for
  /// one would be a check that fails drivers who did it perfectly, and the
  /// failures would be intermittent and inexplicable, which is the worst kind
  /// of verification bug there is.
  Future<void> start({int intervalMs = 350}) async {
    final controller = _controller;
    if (controller == null || !canStart(controller.value.isInitialized)) {
      error = 'The camera is not ready yet.';
      return;
    }
    _detector ??= FaceDetector(
      options: FaceDetectorOptions(
        // Accurate, and not negotiable. `headEulerAngleY` -- the yaw the turn
        // challenges are judged on -- is documented as guaranteed only in
        // accurate mode. In fast mode it is null, and the verifier refuses to
        // pass a head turn on a null, so every driver would fail the check
        // with nothing on screen to say why.
        performanceMode: FaceDetectorMode.accurate,
        // For the mesh the verifier insists on seeing, and for the eye
        // openness the smile challenge is cross-checked against.
        enableContours: true,
        enableClassification: true,
        // Off. The verifier judges each still on its own merits, and a tracked
        // id would invite trusting a face seen a moment ago -- which is exactly
        // what a printed photograph is: still, and confidently the same face.
        enableTracking: false,
        // A face smaller than this gives confident nonsense from the pose and
        // eye models. The default of 0.1 is roughly 1% of frame width, which
        // on a phone held at arm's length is somebody across the room.
        minFaceSize: 0.25,
      ),
    );

    _timer?.cancel();
    _timer = Timer.periodic(
      Duration(milliseconds: intervalMs),
      (_) => unawaited(_sample()),
    );
  }

  /// Captures one still, judges it, and throws the file away.
  Future<void> _sample() async {
    final controller = _controller;
    final detector = _detector;
    if (controller == null || detector == null || _busy || _disposed) return;
    if (!canStart(controller.value.isInitialized)) return;

    _busy = true;
    File? shot;
    try {
      final xFile = await controller.takePicture();
      shot = File(xFile.path);
      final faces = await detector.processImage(
        InputImage.fromFilePath(shot.path),
      );
      if (_disposed) return;
      // Cleared on the first still that reads. Left set, one dropped frame
      // during a check would show a red message for the rest of it, and a
      // driver who reads that has stopped trying.
      error = null;
      verifier.observe(_toReading(faces));
      if (verifier.outcome == LivenessOutcome.passed && proofFrame == null) {
        // Kept rather than deleted: the upload needs it, and the verifier's
        // verdict is about this instant and no other.
        proofFrame = shot;
        shot = null;
      }
    } on Object catch (e, st) {
      error = 'The camera could not be read. Try again.';
      // Logged, not gated on `kDebugMode`.
      //
      // The driver gets the plain sentence above; the reason goes to the
      // platform log unconditionally. Gating this on `kDebugMode` looked tidy
      // and was exactly wrong: it made the one failure nobody can reproduce on
      // a desk invisible on every real build.
      debugPrint('liveness: still could not be read: $e\n  $st');
    } finally {
      _busy = false;
      // Every still is deleted except the one kept as proof. They land in the
      // app's own cache, and a check sampled at 3Hz for a minute is a couple
      // of hundred files of somebody's face that nobody asked to keep.
      final leftover = shot;
      if (leftover != null) {
        unawaited(leftover.delete().catchError((Object _) => leftover));
      }
    }
  }

  /// The camera rotation, for ML Kit.
  ///
  /// `sensorOrientation` is the sensor's angle and the device rotation is how
  /// far the phone has been turned since; they compose. The front camera's
  /// image is mirrored relative to the sensor and the back camera's is not,
  /// which is why they differ by a quarter turn from each other.
  ///
  /// A named lookup and not a bare `~/ 90`, because the result indexes
  /// [InputImageRotation.values] and an out-of-range integer there is a range
  /// error on a driver's phone rather than a wrong-but-working answer.
  static InputImageRotation rotationFor(CameraDescription d) {
    return InputImageRotationValue.fromRawValue(degreesFor(d).round()) ??
        InputImageRotation.rotation0deg;
  }

  /// The composed rotation, in degrees.
  ///
  /// A double because that is what both callers want: `Size` takes one and
  /// `InputImageRotationValue.fromRawValue` takes one, and an int here would
  /// need widening at both ends of the file for no gain.
  @visibleForTesting
  static double degreesFor(CameraDescription d) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return (((d.sensorOrientation + 90) % 360) ~/ 90 * 90).toDouble();
    }
    final device = d.lensDirection == CameraLensDirection.front
        ? (d.sensorOrientation - 90) % 360
        : (d.sensorOrientation + 90) % 360;
    final wrapped = device < 0 ? device + 360 : device;
    return (wrapped ~/ 90 * 90).toDouble();
  }

  /// Reduces ML Kit's faces to one reading, or to a no-face reading.
  FaceReading _toReading(List<Face> faces) {
    if (faces.isEmpty) return FaceReading.noFace(DateTime.now());
    // Largest face, not the first. With more than one face the verifier fails
    // the check outright, so this only decides what the few samples before the
    // count trips report -- and the nearest face is the least surprising thing
    // to report for those.
    faces.sort(
      (a, b) => (b.boundingBox.width * b.boundingBox.height).compareTo(
        a.boundingBox.width * a.boundingBox.height,
      ),
    );
    final face = faces.first;
    return FaceReading(
      at: DateTime.now(),
      faceCount: faces.length,
      yaw: face.headEulerAngleY,
      pitch: face.headEulerAngleX,
      roll: face.headEulerAngleZ,
      leftEyeOpen: face.leftEyeOpenProbability,
      rightEyeOpen: face.rightEyeOpenProbability,
      smile: face.smilingProbability,
      // 132 points across both faces when contours are enabled, and none at
      // all when they are not. The verifier refuses a reading with too few, so
      // a detector wired up without contours becomes one clear failure rather
      // than every driver being asked to move their head for nothing.
      contourPoints: face.contours.isEmpty ? 0 : 132,
    );
  }

  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    try {
      await _controller?.stopImageStream();
    } on Object {
      // Stopping a stream that was never started throws on some devices, and
      // it must not stop the detector being released.
    }
    await _detector?.close();
    _detector = null;
  }
}
