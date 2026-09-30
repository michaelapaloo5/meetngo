import 'dart:io';

import 'package:face_detection_tflite/face_detection_tflite.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'face_reading.dart';
import 'spoof_detector.dart';

/// Turns a still on disk into a [FaceReading] and a [SpoofReading].
///
/// ## Why this file is not a MethodChannel
///
/// It was one. `google_mlkit_face_detection` is a thin marshaller over ML
/// Kit's native API, and on this app -- a release build on a Samsung A06,
/// Android 16 -- `detector.processImage` threw a `NullPointerException` out of
/// Google's own pre-obfuscated runtime on every single frame. Reproduced
/// through the plugin on two versions (0.15.1 and 0.13.1), through both of its
/// input paths, and then through a thirty-line `LivenessChannel.kt` that called
/// `FaceDetection.getClient` and `InputImage.fromFilePath` directly, with the
/// same throw. Decompiling `vision-common` 17.3.0 put it in the detector's own
/// construction path, one layer below anything a caller passes in. ML Kit was
/// not usable here and the marshalling was never the cause.
///
/// So there is no plugin and no bridge. [face_detection_tflite] is MediaPipe's
/// models on LiteRT: Apache 2.0, bundled in the APK, no model download, no
/// network, and it runs inference on a background isolate so the live preview
/// keeps moving. It is also about 5.5x faster than ML Kit and produces the
/// same values, with the same sign conventions, which is why
/// `LivenessVerifier` is unchanged: it still reads `headEulerAngleY`, still
/// reads the eye and smile probabilities, still wants a contour.
///
/// ## What the app does with what comes back
///
/// The mesh and the anti-spoof score are two different questions and both are
/// answered. The challenges need pose, which comes from the mesh. Whether the
/// thing in front of the camera is flat comes from MiniFASNet, run over a crop of
/// the same still, in [SpoofDetector].
///
/// Neither is a strong check alone: a replay video defeats pose, and a model
/// alone is defeated by a good photograph at a good angle. Together they are
/// the check.
class LivenessDetector {
  LivenessDetector({FaceDetector? faceDetector, SpoofDetector? spoofDetector})
    : _faces = faceDetector,
      _spoof = spoofDetector ?? SpoofDetector();

  /// Kept behind a nullable so a test can hand in a detector it built itself.
  FaceDetector? _faces;
  final SpoofDetector _spoof;

  /// Set when the detector refused, which is not the same as "no face".
  ///
  /// Surfaced rather than swallowed: "there is nobody in front of the camera"
  /// and "the face check is broken" are opposites, and a driver told the wrong
  /// one stops trying.
  String? error;

  bool _disposed = false;

  Future<FaceDetector> _detector() async {
    final existing = _faces;
    if (existing != null) return existing;

    // `frontCamera`, not the default. The model is the one trained for
    // close-up frontal faces, which is what a driver holding a phone at arm's
    // length is, and the default is tuned for group shots where the faces are
    // small.
    //
    // `minFaceSize` is 0.0, the package's default, deliberately: the package
    // filters strictly after detection, so a threshold here can only remove
    // faces the detector already found. `minFacePresenceConfidence` stays at
    // MediaPipe's 0.5, which drops the hand-and-palm false positives.
    final created = await FaceDetector.create(
      model: FaceDetectionModel.frontCamera,
    );
    _faces = created;
    return created;
  }

  /// Reads one still.
  ///
  /// Returns both readings for the same frame rather than making the caller ask
  /// twice, because asking twice would mean two decodes of the same file and
  /// two chances for the driver to move between them.
  Future<Detection> detect(String path, {DateTime? at}) async {
    final when = at ?? DateTime.now();
    if (_disposed) {
      return Detection(
        face: FaceReading.noFace(when),
        spoof: SpoofReading(at: when, verdict: SpoofVerdict.unknown),
      );
    }

    // The file has to be read here rather than handed over as a path, because
    // the crop for the anti-spoof model needs decoded RGB pixels and only this
    // side has the file. One read, two uses.
    final Uint8List encoded;
    try {
      encoded = await File(path).readAsBytes();
    } on Object catch (e) {
      debugPrint('liveness: the still could not be read: $e');
      error = 'The camera could not be read. Try again.';
      return Detection(
        face: FaceReading.noFace(when),
        spoof: SpoofReading(at: when, verdict: SpoofVerdict.unknown),
      );
    }
    if (encoded.isEmpty) {
      error = 'The camera could not be read. Try again.';
      return Detection(
        face: FaceReading.noFace(when),
        spoof: SpoofReading(at: when, verdict: SpoofVerdict.unknown),
      );
    }

    List<Face> faces;
    try {
      final detector = await _detector();
      // `full` rather than `standard`, and the difference matters: the eye-open
      // and smile probabilities the verifier reads are only computed in `full`,
      // where the blendshape model runs. In `standard` they are null and the
      // verifier would refuse the smile and the eye challenges. The mode costs
      // about 3 ms more per face.
      faces = await detector.detectFacesFromBytes(
        encoded,
        mode: FaceDetectionMode.full,
      );
    } on Object catch (e, st) {
      // Logged, not gated on `kDebugMode`. Gating it on that looked tidy and
      // was exactly wrong: it made the one failure nobody can reproduce on a
      // desk invisible on every real build.
      debugPrint('liveness: the face could not be read: $e\n  $st');
      error =
          'The face check is not working on this phone right now. Please '
          'try again later.';
      return Detection(
        face: FaceReading.noFace(when),
        spoof: SpoofReading(at: when, verdict: SpoofVerdict.unknown),
      );
    }

    if (faces.isEmpty) {
      // Not an error. Nobody in front of the camera is an ordinary thing for a
      // front camera to report, and the driver is told to move into frame rather
      // than that the check is broken.
      error = null;
      return Detection(
        face: FaceReading.noFace(when),
        spoof: SpoofReading(at: when, verdict: SpoofVerdict.unknown),
      );
    }

    // The largest face, not the first. The verifier fails the check outright on
    // more than one face, so this only decides what the samples before the count
    // trips report, and the nearest face is the least surprising thing to report
    // for those.
    final sorted = [...faces]
      ..sort(
        (a, b) => (b.boundingBox.width * b.boundingBox.height).compareTo(
          a.boundingBox.width * a.boundingBox.height,
        ),
      );
    final face = sorted.first;

    final reading = _reading(face, when);
    final spoof = await _judgeSpoof(encoded, face, when);

    // Cleared on the first still that reads. Left set, one dropped frame during
    // a check would show a red message for the rest of it, and a driver who
    // reads that has stopped trying.
    error = null;
    return Detection(face: reading, spoof: spoof);
  }

  /// The anti-spoof pass, over the same still.
  ///
  /// Skipped rather than failed when the still will not decode. The face
  /// reading is the one the challenges need and it has already succeeded by
  /// this point, so throwing away a good challenge reading over a decode
  /// failure would be a worse outcome than reporting no spoof score, and the
  /// verifier treats an unknown score as "not evidence" rather than as a fail.
  Future<SpoofReading> _judgeSpoof(
    Uint8List encoded,
    Face face,
    DateTime when,
  ) async {
    try {
      final decoded = img.decodeImage(encoded);
      if (decoded == null) {
        return SpoofReading(at: when, verdict: SpoofVerdict.unknown);
      }
      final box = face.boundingBox;
      if (box.width <= 0 || box.height <= 0) {
        // A detection with no area. Clamping it would produce a 1x1 crop,
        // which the model would judge confidently and wrongly, so this reports
        // nothing measured instead.
        return SpoofReading(at: when, verdict: SpoofVerdict.unknown);
      }
      // The bounding box is in the coordinate space the detector reports, which
      // is the still's own pixels. Clamped here rather than trusting the box:
      // a face at the edge of the frame produces a box that runs past it, and
      // an out-of-range index into the pixel buffer is a crash on a driver's
      // phone.
      final left = box.left.round().clamp(0, decoded.width - 1);
      final top = box.top.round().clamp(0, decoded.height - 1);
      final right = box.right.round().clamp(left + 1, decoded.width);
      final bottom = box.bottom.round().clamp(top + 1, decoded.height);

      return await _spoof.judge(
        pixels: decoded.getBytes(order: img.ChannelOrder.rgb),
        width: decoded.width,
        height: decoded.height,
        left: left,
        top: top,
        right: right,
        bottom: bottom,
        at: when,
      );
    } on Object catch (e) {
      debugPrint('liveness: the anti-spoof pass was skipped: $e');
      return SpoofReading(at: when, verdict: SpoofVerdict.unknown);
    }
  }

  /// A detected face as the plain reading type the verifier consumes.
  ///
  /// Every probability is a nullable double on purpose, and the package's own
  /// nulls are passed through rather than defaulted. A null yaw has to reach
  /// the verifier as a null, because a zero there is a head that is
  /// demonstrably facing forwards when in fact nothing was measured, and the
  /// verifier refuses to pass a head turn on the second.
  FaceReading _reading(Face face, DateTime at) {
    // 36 points on the face oval. The verifier asks "was a mesh computed at
    // all" and not how many points it held, so this is a presence flag with a
    // number on it. Zero in fast mode, where there is no mesh, which becomes a
    // clear failure rather than every driver being asked to move their head for
    // nothing.
    final contour = face.getContour(FaceContourType.face);
    return FaceReading(
      at: at,
      faceCount: 1,
      yaw: face.headEulerAngleY,
      pitch: face.headEulerAngleX,
      roll: face.headEulerAngleZ,
      leftEyeOpen: face.leftEyeOpenProbability,
      rightEyeOpen: face.rightEyeOpenProbability,
      smile: face.smilingProbability,
      contourPoints: contour == null ? 0 : contour.length,
    );
  }

  /// The last detected face's area, as a fraction of frame width, for the
  /// "come closer" hint. Zero when nothing was detected.
  double lastFaceWidthFraction = 0;

  /// Whether the anti-spoof model is loaded and usable.
  ///
  /// The screen asks before it starts, because a check that begins and then
  /// cannot confirm anybody wastes a driver’s time and ends in a failure they
  /// did nothing to cause. A false here is a broken build -- the model is a
  /// bundled asset, so it is either in the APK or it is not.
  bool get hasSpoofModel => _spoof.isReady;

  /// Releases the model.
  ///
  /// Called on the way out of the check. The detector holds native memory, and
  /// a driver opening the face check three times in a row would otherwise hold
  /// three of them at once.
  Future<void> close() async {
    _disposed = true;
    await _faces?.dispose();
    _faces = null;
    await _spoof.dispose();
  }
}

/// One frame's two readings.
class Detection {
  const Detection({required this.face, required this.spoof});

  final FaceReading face;
  final SpoofReading spoof;
}
