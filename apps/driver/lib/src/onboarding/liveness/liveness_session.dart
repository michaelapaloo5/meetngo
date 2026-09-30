import 'dart:async';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'face_reading.dart';
import 'liveness_verifier.dart';

/// Turns the camera into [FaceReading]s and drives a [LivenessVerifier].
///
/// Everything platform-shaped lives here, so that nothing platform-shaped is in
/// the decision-making. Two things this gets right that are easy to get wrong,
/// and each of which silently destroys a liveness check:
///
///  * **Rotation.** ML Kit reports head yaw relative to the *image*, so a
///    portrait frame fed in with the wrong rotation reads a left turn as a
///    right turn. Every turn challenge then passes or fails for a reason that
///    has nothing to do with the driver.
///  * **The row stride.** `bytesPerRow` is not `width`. Handing the detector a
///    `width` where a stride belongs shears every row of a 4:3 sensor into a
///    16:9 frame, and the head-pose model reports a head tilted at an angle it
///    never was.
///
/// The luminance plane is used, not a colour buffer: the pose and eye models
/// are trained on luminance, and giving them colour yields confident nonsense.
class LivenessSession {
  LivenessSession({required this.verifier});

  final LivenessVerifier verifier;

  CameraController? _controller;
  FaceDetector? _detector;
  Timer? _timer;
  CameraImage? _pending;

  /// True while a frame is being analysed, so the next one is dropped rather
  /// than queued. A backlog of frames judged long after they were captured is a
  /// liveness check assessing the past, and the queue grows without bound when
  /// the detector is slower than the camera -- which accurate mode, on a budget
  /// phone, is.
  bool _busy = false;
  bool _disposed = false;

  /// Set when the camera or the detector refused.
  ///
  /// Surfaced rather than swallowed: a driver left watching a screen that
  /// never advances has no way to tell a broken check from a broken phone.
  String? error;

  /// The still taken the instant the check passed, for the admin to compare
  /// against the licence photo.
  ///
  /// Taken with `takePicture` rather than kept from the analysis stream,
  /// because the analysis buffer is a raw luma plane and not an image any
  /// viewer can open. The bucket's mime allow-list is `image/jpeg` and an
  /// admin opening a corrupt file learns nothing about the driver.
  File? proofFrame;

  /// Whether the proof still needs taking, so a passing check takes exactly one.
  bool _tookProof = false;

  /// Starts analysing. The camera must already be initialised and ready.
  ///
  /// [intervalMs] throttles the analysis rather than taking every frame: ML
  /// Kit's accurate mode cannot keep up with 30fps, and 120ms is about 8Hz,
  /// which is far more than a 12-second challenge needs to see a 20-degree turn
  /// happen.
  Future<void> start({int intervalMs = 120}) async {
    final controller = _controller;
    if (controller == null || !controller.value.isStreamingImages) {
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
        // openness the blink challenge is built from.
        enableContours: true,
        enableClassification: true,
        // Off. The verifier judges each frame on its own merits, and a tracked
        // id would invite trusting a face seen a moment ago -- which is exactly
        // what a printed photograph is: still, and confidently the same face.
        enableTracking: false,
        // A face smaller than this gives confident nonsense from the pose and
        // eye models. The default of 0.1 is roughly 1% of frame width, which
        // on a phone held at arm's length is somebody across the room.
        minFaceSize: 0.25,
      ),
    );

    unawaited(controller.startImageStream(_onFrame));
    _timer?.cancel();
    _timer = Timer.periodic(
      Duration(milliseconds: intervalMs),
      (_) => unawaited(_drainPending()),
    );
  }

  void attach(CameraController controller) => _controller = controller;

  void _onFrame(CameraImage image) {
    if (_disposed || _busy) return;
    _pending = image;
  }

  Future<void> _drainPending() async {
    final image = _pending;
    _pending = null;
    final detector = _detector;
    if (image == null || detector == null || _busy || _disposed) return;

    _busy = true;
    try {
      final faces = await detector.processImage(_toInputImage(image));
      if (_disposed) return;
      verifier.observe(_toReading(faces));
      if (verifier.outcome == LivenessOutcome.passed && !_tookProof) {
        _tookProof = true;
        proofFrame = await _takeProof();
      }
    } on Object catch (e) {
      error = 'The camera could not be read. Try again.';
      if (kDebugMode) debugPrint('liveness frame failed: $e');
    } finally {
      _busy = false;
    }
  }

  Future<File?> _takeProof() async {
    try {
      final xFile = await _controller?.takePicture();
      if (xFile == null) return null;
      return File(xFile.path);
    } on Object {
      // A still that fails to save does not undo a passed check: the liveness
      // result stands, and the driver is asked for the face check again only
      // if there is no frame for an admin to look at. Reported rather than
      // hidden, because a check that passes with nothing to review is a check
      // that cannot be audited.
      error = 'The check passed but the photo could not be saved.';
      return null;
    }
  }

  /// The camera rotation, for ML Kit.
  ///
  /// `sensorOrientation` is the sensor's angle and the device rotation is how
  /// far the phone has been turned since; they compose. The front camera's
  /// image is mirrored relative to the sensor and the back camera's is not,
  /// which is why they differ by a quarter turn from each other. Using the
  /// wrong one of these is the most common way an ML Kit liveness check ends
  /// up judging left as right.
  ///
  /// A named constructor and not a bare `~/ 90`, because the result indexes
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

  InputImage _toInputImage(CameraImage image) {
    final d = _controller?.description;
    return InputImage.fromBytes(
      bytes: image.planes.first.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: d == null
            ? InputImageRotation.rotation0deg
            : rotationFor(d),
        format: InputImageFormat.yuv_420_888,
        // The stride, not the width. See the class comment.
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
  }

  /// Reduces ML Kit's faces to one reading, or to a no-face reading.
  FaceReading _toReading(List<Face> faces) {
    if (faces.isEmpty) return FaceReading.noFace(DateTime.now());
    // Largest face, not the first. With more than one face the verifier fails
    // the check outright, so this only decides what the few frames before the
    // count trips report -- and the nearest face is the least surprising
    // thing to report for those.
    faces.sort((a, b) => (b.boundingBox.width * b.boundingBox.height)
        .compareTo(a.boundingBox.width * a.boundingBox.height));
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
