/// One analysed camera frame, reduced to what a liveness check actually uses.
///
/// The important thing about this type is that it is *plain*. It is not a
/// MediaPipe `Face` and not an anti-spoof model output, and this file imports
/// nothing at all. The detectors are wired in at the edge and produce these;
/// everything that decides whether a driver passed is then ordinary arithmetic
/// over doubles.
///
/// That split is the reason the liveness logic is testable: a real face
/// detector needs a camera, a model and a real head, and none of those can
/// assert anything. A verifier that consumed a model's types directly could
/// only ever be tested by a human holding their phone up, which is exactly the
/// arrangement under which a liveness check is never actually tested.
library;

class FaceReading {
  const FaceReading({
    required this.at,
    required this.faceCount,
    this.yaw,
    this.pitch,
    this.roll,
    this.leftEyeOpen,
    this.rightEyeOpen,
    this.smile,
    this.contourPoints = 0,
    this.spoofScore,
  });

  /// When the frame was analysed.
  ///
  /// Carried on the reading rather than read from a clock inside the verifier,
  /// so that time is an input to the decision and not a side effect of it. A
  /// liveness check that can time out has to be testable without waiting.
  final DateTime at;

  /// How many faces the detector found.
  ///
  /// Not a bool, because the count is the whole of one of the attacks: a driver
  /// holding up a photograph of themselves is one real face plus one printed
  /// one, and the detector is perfectly happy to report two.
  final int faceCount;

  /// Head yaw in degrees. Positive is the subject's right.
  ///
  /// Null when the detector was in fast mode, which does not compute it. The
  /// verifier treats null as "cannot satisfy a head-turn challenge" rather than
  /// as zero, because treating a missing measurement as a measurement is how a
  /// face is passed for turning its head when the angle was never known.
  final double? yaw;

  /// Head pitch in degrees. Positive is looking up.
  final double? pitch;

  /// Head roll in degrees. Positive is counter-clockwise.
  final double? roll;

  /// Per-eye openness, 0 to 1.
  ///
  /// Derived from MediaPipe's blendshape coefficients: `1 - eyeBlinkLeft` for
  /// the subject's left eye. Null in anything below full detection mode, where
  /// the blendshape model does not run.
  final double? leftEyeOpen;

  final double? rightEyeOpen;

  /// 0 to 1. The mean of the two `mouthSmile` blendshapes.
  ///
  /// A blendshape coefficient rather than a trained classifier, which is worth
  /// knowing when reading the threshold below: it is a statement about geometry
  /// ("the mouth corners are raised") and not a learned opinion about
  /// happiness, so it holds up at angles where a classifier would not.
  final double? smile;

  /// How many points the face oval contour had.
  ///
  /// Carried because it is the evidence that a mesh was actually computed, and
  /// a reading with zero contour points is a detection from a configuration
  /// that will never produce head pose. Asserted in the verifier rather than
  /// trusted, so a detector left in fast mode fails loudly on the first frame
  /// instead of failing every driver silently.
  final int contourPoints;

  /// The anti-spoof model's probability that this face is live, 0 to 1.
  ///
  /// Null when the model did not run or could not decide. Null is not zero: a
  /// zero is a confident statement that a driver is holding up a photograph,
  /// and it has to be impossible for "the model had nothing to say" to be read
  /// as that.
  ///
  /// Read against [kLiveScoreThreshold] by the verifier, which is why the
  /// threshold lives in this file rather than in the detector. This is the
  /// contract between them, and the one file both can import without dragging a
  /// model into the other's dependency graph.
  final double? spoofScore;

  /// Whether the anti-spoof model says this is a real face.
  ///
  /// False when the score is null, so an unmeasured frame never counts as
  /// evidence in either direction. The verifier keeps the counts separately for
  /// exactly this reason.
  bool get looksLive {
    final s = spoofScore;
    return s != null && s >= kLiveScoreThreshold;
  }

  /// Whether the anti-spoof model says this is a flat surface.
  bool get looksSpoofed {
    final s = spoofScore;
    return s != null && s < kLiveScoreThreshold;
  }

  /// Whether there is exactly one face, and it is a usable one.
  bool get hasOneFace => faceCount == 1;

  /// True when both eyes are open, for the "eyes were open" half of a blink.
  ///
  /// Requires both. A half-blink reported as one open eye is a person who is
  /// about to blink, which is the normal state immediately before a blink, so
  /// treating it as "open" would make the blink challenge satisfiable by a face
  /// that happens to be caught mid-blink.
  bool get eyesOpen {
    final l = leftEyeOpen;
    final r = rightEyeOpen;
    return l != null &&
        r != null &&
        l > kEyeOpenThreshold &&
        r > kEyeOpenThreshold;
  }

  /// True when both eyes are shut.
  bool get eyesShut {
    final l = leftEyeOpen;
    final r = rightEyeOpen;
    return l != null &&
        r != null &&
        l < kEyeClosedThreshold &&
        r < kEyeClosedThreshold;
  }

  /// A reading where the detector found nothing at all.
  ///
  /// A named constructor rather than a value built at the call site, because
  /// "no face" is the single most important reading in the whole check and it
  /// must be impossible to construct one accidentally with a stale angle left
  /// over from the previous frame.
  factory FaceReading.noFace(DateTime at) =>
      FaceReading(at: at, faceCount: 0, contourPoints: 0);

  /// The same reading, carrying an anti-spoof score.
  ///
  /// A method rather than a field the detector fills in, because the two
  /// readings come from two different models over the same bytes and the tests
  /// for the challenge logic have no model to draw a score from. A reading with
  /// no score is a normal, tested state: the verifier counts it as unmeasured
  /// and keeps going, and a check that never gets one fails at the end with
  /// [LivenessOutcome.livenessUnproven].
  FaceReading withSpoof(double? score) => FaceReading(
    at: at,
    faceCount: faceCount,
    yaw: yaw,
    pitch: pitch,
    roll: roll,
    leftEyeOpen: leftEyeOpen,
    rightEyeOpen: rightEyeOpen,
    smile: smile,
    contourPoints: contourPoints,
    spoofScore: score,
  );

  @override
  String toString() =>
      'FaceReading($faceCount faces, yaw=$yaw, pitch=$pitch, '
      'eyes=$leftEyeOpen/$rightEyeOpen, smile=$smile, points=$contourPoints, '
      'live=${spoofScore?.toStringAsFixed(2) ?? "n/a"})';
}

/// At or above this, the anti-spoof model is taken at its word that the face is
/// live.
///
/// 0.5 is MiniFASNet's own decision boundary: the model is a two-class softmax,
/// so the score is a probability and 0.5 is the point where it is more likely
/// live than not. Moving it in either direction trades false accepts against
/// false rejects, and there is no evidence here about which is cheaper -- one
/// false accept costs a reviewer a look, one false reject costs a driver their
/// onboarding.
///
/// It lives in this file so the detector and the verifier agree by construction
/// rather than by two constants happening to match. See
/// `liveness_verifier_test.dart` for the behaviour on each side of it.
const double kLiveScoreThreshold = 0.5;

/// Above this, an eye counts as open.
///
/// These are derived from MediaPipe blendshape coefficients, which are geometry
/// and jitter by a few points frame to frame on a cheap sensor in poor light.
/// A threshold at 0.5 flips on that jitter, so a blink challenge keyed to 0.5
/// completes by accident during ordinary blinking noise and proves nothing.
/// 0.55 with a matching closed threshold below gives the hysteresis a blink test
/// needs in order to be more than a coin toss.
const double kEyeOpenThreshold = 0.55;

/// Below this, an eye counts as shut.
const double kEyeClosedThreshold = 0.25;
