/// One analysed camera frame, reduced to what a liveness check actually uses.
///
/// The important thing about this type is that it is *plain*. It is not an ML
/// Kit `Face`, and the verifier does not import ML Kit at all. The detector is
/// wired in at the edge and produces these; everything that decides whether a
/// driver passed is then ordinary arithmetic over doubles.
///
/// That split is the reason the liveness logic is testable at all: a real face
/// detector needs a camera, a model and a real head, and none of those can
/// assert anything. A verifier that consumed ML Kit's `Face` directly could
/// only ever be tested by a human holding their phone up, which is exactly the
/// arrangement under which a liveness check is never actually tested.
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

  /// Head yaw in degrees. Positive is the subject's right, as ML Kit defines it.
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

  /// Per-eye openness, 0 to 1. Null when classification was not enabled.
  final double? leftEyeOpen;

  final double? rightEyeOpen;

  /// 0 to 1. Null when classification was not enabled.
  final double? smile;

  /// How many points the face mesh had.
  ///
  /// Carried because it is the evidence that a mesh was actually computed, and
  /// a reading with zero contour points is a detection from a configuration
  /// that will never produce head pose. Asserted in the verifier rather than
  /// trusted, so a detector wired up with `enableContours` left off fails
  /// loudly here instead of failing every driver silently.
  final int contourPoints;

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

  @override
  String toString() => 'FaceReading($faceCount faces, yaw=$yaw, pitch=$pitch, '
      'eyes=$leftEyeOpen/$rightEyeOpen, smile=$smile, points=$contourPoints)';
}

/// Above this, an eye counts as open.
///
/// ML Kit's eye-openness is a classifier probability and it jitters by a few
/// points frame to frame on a cheap sensor in poor light. A threshold at 0.5
/// flips on that jitter, so a blink challenge keyed to 0.5 completes by
/// accident during ordinary blinking noise and proves nothing. 0.55 with a
/// matching closed threshold below gives the hysteresis a blink test needs in
/// order to be more than a coin toss.
const double kEyeOpenThreshold = 0.55;

/// Below this, an eye counts as shut.
const double kEyeClosedThreshold = 0.25;
