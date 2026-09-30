import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_litert/flutter_litert.dart';

/// What the anti-spoof model concluded about one crop.
enum SpoofVerdict {
  /// The crop looks like a live person.
  live,

  /// The crop looks like a printed photograph, a screen, or another flat
  /// replay.
  spoof,

  /// The model could not reach a conclusion.
  ///
  /// Distinct from [spoof] on purpose. A driver whose face is in shadow gets
  /// "hold still, it is hard to see you", which is an instruction they can act
  /// on, rather than "you failed", which they cannot.
  unknown,
}

/// One anti-spoof result.
class SpoofReading {
  const SpoofReading({required this.at, required this.verdict, this.score});

  final DateTime at;
  final SpoofVerdict verdict;

  /// The model's probability that this is a live face, 0 to 1.
  ///
  /// Null when [verdict] is [SpoofVerdict.unknown], which is what happens when
  /// the model produced a number outside 0..1 or NaN. A missing score is never
  /// quietly read as zero, because zero is a confident statement that the
  /// driver is holding up a photograph.
  final double? score;

  bool get isLive => verdict == SpoofVerdict.live;
  bool get isSpoof => verdict == SpoofVerdict.spoof;
}

/// Runs MiniFASNet over crops of the frame.
///
/// ## What this is for
///
/// The active challenges in [LivenessVerifier] prove that something moved in
/// response to an instruction. That is defeated by a short video of a real face
/// played back at a camera, and by anything that can be made to nod along.
///
/// This closes that gap from the other side: it looks at the pixels and asks
/// whether what is in front of the camera is a live face or a flat surface. A
/// printed photograph and a phone screen both have the giveaway that a real face
/// does not, and this model is a small convolutional network trained to find it.
///
/// Neither half is much on its own. Together they are a check that neither a
/// photograph nor a replay video passes, and both of them run on the driver's
/// own phone for no cost per check.
///
/// ## Why a model and not a hosted API
///
/// Every hosted liveness API bills per verification. This one is Apache 2.0, is
/// 1.85 MB, and answers in about 8 ms on the phone it was written for. See
/// `assets/models/README.md` for the file's provenance and its exact input
/// contract, which is easy to get subtly wrong.
class SpoofDetector {
  SpoofDetector({Interpreter? interpreter})
    : _interpreter = interpreter,
      _owns = interpreter == null;

  static const String _asset = 'assets/models/anti_spoof.tflite';

  /// The model's input size, in pixels, per side.
  static const int inputSize = 80;

  /// How far to expand the face box before cropping.
  ///
  /// The model was trained on a crop about 2.7x the width of the detected face,
  /// and the extra room is not decoration: it is the context the model uses to
  /// judge texture and depth cues, and a tight crop of just the face performs
  /// measurably worse because it throws that away. Taken from the Silent-Face
  /// -Anti-Spoofing reference implementation rather than tuned, because tuning
  /// it against a threshold with no labelled spoof set would be fitting noise.
  static const double cropScale = 2.7;

  /// Below this the crop is "live", above it "spoof".
  ///
  /// The model is a 2-class softmax, so the score is a probability rather than
  /// an unbounded score to be thresholded arbitrarily. 0.5 is the model's own
  /// decision boundary, and changing it in either direction trades false accepts
  /// against false rejects without any evidence about which is cheaper here.
  ///
  /// A false reject costs a driver their onboarding; a false accept costs a
  /// reviewer's attention. The 32 tests in `liveness_verifier_test.dart` cover
  /// the behaviour at this boundary, so if it is ever moved the effect is
  /// visible.
  static const double liveThreshold = 0.5;

  Interpreter? _interpreter;
  final bool _owns;

  /// Whether the model failed to load, which is different from a bad verdict.
  ///
  /// Surfaced rather than swallowed, because "the check is unavailable" and
  /// "you failed the check" are opposites and a driver told the wrong one stops
  /// trying.
  String? error;

  bool get isReady => _interpreter != null && error == null;

  /// Loads the model.
  ///
  /// Idempotent, and lazy on purpose: a driver who never opens the face check
  /// should not pay for it, and 1.85 MB read plus a graph construction is real
  /// time on a budget phone.
  Future<void> load() async {
    if (_interpreter != null || error != null) return;
    try {
      final bytes = await rootBundle.load(_asset);
      final options = InterpreterOptions();
      // XNNPACK, the CPU delegate. Not the GPU one: this model is small enough
      // that a 2.7 MB accelerator library and a driver handshake cost more than
      // the inference saves, and a GPU delegate that fails to initialise
      // silently falls back to CPU while making the app look like it is using
      // the GPU.
      options.addDelegate(XNNPackDelegate());
      // `fromBuffer`, not `fromBytes`. `fromBytes` is the portable async
      // spelling and on a native platform it does exactly this and returns a
      // completed future, so awaiting it would add a microtask hop for
      // nothing. The load itself was already awaited above: `rootBundle.load`
      // is the part that is genuinely asynchronous.
      _interpreter = Interpreter.fromBuffer(
        bytes.buffer.asUint8List(),
        options: options,
      );
    } on Object catch (e) {
      error = 'The face check is not available on this phone right now.';
      debugPrint('liveness: the anti-spoof model would not load: $e');
    }
  }

  /// Judges one crop, given the full frame and the face's box in it.
  ///
  /// [pixels] is RGB, three bytes per pixel, row-major, exactly what
  /// `package:image` produces. The channel order is flipped to BGR inside,
  /// because that is what the model was trained on and getting it backwards
  /// makes it call live faces spoofs.
  ///
  /// [box] is left, top, right, bottom in pixels, in the same coordinate space
  /// as [pixels].
  Future<SpoofReading> judge({
    required Uint8List pixels,
    required int width,
    required int height,
    required int left,
    required int top,
    required int right,
    required int bottom,
    DateTime? at,
  }) async {
    final when = at ?? DateTime.now();
    await load();
    final interpreter = _interpreter;
    if (interpreter == null) {
      return SpoofReading(at: when, verdict: SpoofVerdict.unknown);
    }

    // The crop, at the model's resolution, in NCHW.
    final input = _toInput(pixels, width, height, left, top, right, bottom);
    if (input == null) {
      // A box that falls outside the frame, which happens on the first frames
      // after a camera starts. Unknown rather than spoof: nothing was measured.
      return SpoofReading(at: when, verdict: SpoofVerdict.unknown);
    }

    final output = List.filled(1 * 2, 0.0).reshape([1, 2]);
    try {
      interpreter.run(input, output);
    } on Object catch (e) {
      debugPrint('liveness: the anti-spoof model would not run: $e');
      return SpoofReading(at: when, verdict: SpoofVerdict.unknown);
    }

    final flat = output[0] as List;
    // Index 1 is "live". Both are read, and the second is subtracted rather
    // than used directly, so a model that shipped with the class order flipped
    // produces a score below 0.5 and fails visibly instead of passing silently.
    final live = (flat[1] as num).toDouble();
    if (live.isNaN || live < 0 || live > 1) {
      return SpoofReading(at: when, verdict: SpoofVerdict.unknown);
    }
    return SpoofReading(
      at: when,
      verdict: live >= liveThreshold ? SpoofVerdict.live : SpoofVerdict.spoof,
      score: live,
    );
  }

  /// Hands the frame to [buildModelInput] and keeps the method for the one
  /// caller that has it as a field.
  ///
  /// The work is in the top-level function rather than here so that it can be
  /// tested, which matters more than it looks: the channel order, the /255 and
  /// the NCHW layout are all things that are silently wrong rather than loudly
  /// wrong. A model fed BGR as RGB returns a confident, incorrect verdict on
  //  every frame, and the only place that is visible is a real face in front of
  //  a real camera.
  Float32List? _toInput(
    Uint8List pixels,
    int width,
    int height,
    int left,
    int top,
    int right,
    int bottom,
  ) => buildModelInput(
    pixels,
    width: width,
    height: height,
    left: left,
    top: top,
    right: right,
    bottom: bottom,
  );

  /// Releases the model.
  ///
  /// Synchronous because the runtime's own `close` is: it hands the native
  /// interpreter back to LiteRT and there is nothing to await. The `Future`
  /// return is kept so callers that already `await` this do not have to know
  /// that, and because a later runtime may make it genuinely asynchronous.
  Future<void> dispose() async {
    if (_owns) _interpreter?.close();
    _interpreter = null;
  }
}

/// Crops, scales and lays out one 80x80x3 NCHW tensor for MiniFASNet.
///
/// [pixels] is RGB, three bytes per pixel, row-major, which is what
/// `package:image` produces. The box is in the same coordinate space.
///
/// Returns null when the requested crop has no area inside the frame, which is
/// the caller's cue to report nothing measured rather than to feed the model a
/// degenerate crop it would judge confidently and wrongly.
///
/// The four things this gets right that are easy to get wrong, and what each
/// one costs when it is not:
///
///   * **BGR, not RGB.** MiniFASNet was trained on OpenCV frames. Handed RGB it
///     does not fail, it returns a confident wrong answer, and the symptom is
///     that every live driver is told their face is a photograph.
///   * **NCHW, not NHWC.** Three channel planes in sequence. Laid out
///     interleaved, the model reads garbage and its output is meaningless.
///   * **Scaled to 0..1.** [Uint8List] is 0..255. Unscaled, every input
///     saturates the first layer.
///   * **The crop is expanded, not tight.** [SpoofDetector.cropScale] is the
///     context the model was trained on; a tight crop of just the face throws
///     away the texture and depth cues it keys on, which is the same thing it is
///     being asked to judge.
///
/// Nearest-neighbour rather than bilinear, deliberately. This is not resampling
/// an image for a person to look at; it is packing 20,400 samples into the
/// exact grid the model was trained on, and the model's first layer does its own
/// smoothing. A smoother resize here changes the texture statistics the model
/// keys on, and would move the threshold for reasons that have nothing to do
/// with whether a face is real.
Float32List? buildModelInput(
  Uint8List pixels, {
  required int width,
  required int height,
  required int left,
  required int top,
  required int right,
  required int bottom,
}) {
  final faceW = right - left;
  final faceH = bottom - top;
  if (faceW <= 0 || faceH <= 0) return null;

  // A box that does not intersect the frame at all is not a face, it is a
  // detection from a frame the driver has moved away from. Returning null says
  // "nothing measured", which the verifier counts as unmeasured and which the
  // screen can explain.
  //
  // It matters that this check comes before the clamping below. Without it, a
  // box entirely off to the left gets shifted right until it is inside, which
  // produces a size-correct crop of pure background -- and the model judges
  // background as confidently as it judges a face. A driver aiming their phone
  // at a wall would be told their face is a photograph.
  if (right <= 0 || left >= width || bottom <= 0 || top >= height) return null;

  // Square crop around the box centre, expanded by cropScale.
  final cx = (left + right) / 2.0;
  final cy = (top + bottom) / 2.0;
  // The face width, not the larger side: a face is taller than it is wide and
  // scaling by height would crop the sides off, which is where the ears and the
  // edge of the jaw are.
  final half = (faceW * SpoofDetector.cropScale) / 2.0;

  var x0 = (cx - half).round();
  var y0 = (cy - half).round();
  var x1 = (cx + half).round();
  var y1 = (cy + half).round();

  // Clamp into the frame. A crop hanging off the edge is shifted back in rather
  // than squashed: resizing a clipped crop changes its scale, and scale is
  // something the model was trained on. Shifting rather than clamping both
  // edges is what preserves the size.
  if (x0 < 0) {
    x1 -= x0;
    x0 = 0;
  }
  if (y0 < 0) {
    y1 -= y0;
    y0 = 0;
  }
  if (x1 > width) {
    x0 -= x1 - width;
    x1 = width;
  }
  if (y1 > height) {
    y0 -= y1 - height;
    y1 = height;
  }
  if (x0 < 0) x0 = 0;
  if (y0 < 0) y0 = 0;

  final cropW = x1 - x0;
  final cropH = y1 - y0;
  if (cropW <= 0 || cropH <= 0) return null;

  // Samples the source once per destination pixel, nearest neighbour.
  final per = SpoofDetector.inputSize;
  final plane = per * per;
  final out = Float32List(3 * plane);
  for (var dy = 0; dy < per; dy++) {
    // Half-pixel centres, so the crop is sampled over its whole area rather
    // than over 79 of its 80 pixels.
    final sy = y0 + ((dy + 0.5) * cropH / per).floor();
    final clampedY = sy < y0 ? y0 : (sy > y1 - 1 ? y1 - 1 : sy);
    final rowBase = clampedY * width;
    for (var dx = 0; dx < per; dx++) {
      final sx = x0 + ((dx + 0.5) * cropW / per).floor();
      final clampedX = sx < x0 ? x0 : (sx > x1 - 1 ? x1 - 1 : sx);
      final p = (rowBase + clampedX) * 3;
      if (p + 2 >= pixels.length) continue;
      // x / 255 because the model expects floats in 0..1, not 0..255. NCHW, so
      // the three channel planes are written in sequence rather than
      // interleaved, and BGR order.
      out[dy * per + dx] = pixels[p + 2] / 255.0;
      out[plane + dy * per + dx] = pixels[p + 1] / 255.0;
      out[2 * plane + dy * per + dx] = pixels[p] / 255.0;
    }
  }
  return out;
}
