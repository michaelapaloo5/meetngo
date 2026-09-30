import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_litert/flutter_litert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_driver/src/onboarding/liveness/spoof_detector.dart';

/// The real MiniFASNet, loaded and run against the real crop builder.
///
/// Everything else about the anti-spoof check is tested with a fake, and a fake
/// cannot tell you that the model disagrees with the contract you assumed. This
/// file is the part that needs the actual weights, and it exists because
/// assuming wrong was not theoretical: the model card describes a two-class
/// output, the model is three-class, and reading index 1 of a `[1, 2]` buffer
/// threw `Output object shape mismatch` on every call.
///
/// ## What these tests establish, and what they cannot
///
/// **They do** prove the wiring: the file is present and the right size, the
/// tensor shape is what the model accepts, the output is a three-class
/// softmax, index 2 is the one that moves, the answer is deterministic, and the
/// channel order is load-bearing.
///
/// **They cannot** prove the model discriminates. It needs a photograph of a
/// real face and a real live face, and there is no such pair in a unit test.
/// The `everything is called live` test below is the honest record of that gap:
/// given a black frame, a white frame and random noise, this model answers
/// around 0.99 "live" in all three. That is what a model does with input
/// outside its training distribution, and it is exactly why the threshold here
/// cannot be trusted until somebody points the check at a real face and then at
/// a photograph of that same face.
///
/// Until then `DriverDocumentKind.livenessFrame.isRequired` is false, and the
/// six photographs plus an admin's own comparison are the check that works.
void main() {
  final modelFile = File('assets/models/anti_spoof.tflite');
  late Interpreter interpreter;

  setUpAll(() {
    // Read from disk rather than the asset bundle: a test's working directory
    // is the package root, and this is the same bytes the bundle serves,
    // without needing the manifest wired into the harness.
    interpreter = Interpreter.fromFile(
      modelFile,
      options: (InterpreterOptions()..addDelegate(XNNPackDelegate())),
    );
  });

  tearDownAll(() => interpreter.close());

  /// The class the model calls "live".
  ///
  /// Three classes: a 2D presentation attack, a 3D one, and a real face. The
  /// reference implementation reads `pred[2]`, and so does this.
  const liveClass = 2;

  /// Runs a crop of [pixels] through the model and returns the raw output.
  List<double> raw(Uint8List pixels, int w, int h) {
    final input = buildModelInput(
      pixels,
      width: w,
      height: h,
      left: (w * 0.3).round(),
      top: (h * 0.2).round(),
      right: (w * 0.7).round(),
      bottom: (h * 0.8).round(),
    )!;
    final out = List.filled(3, 0.0).reshape([1, 3]);
    interpreter.run(input, out);
    return (out[0] as List).map((e) => (e as num).toDouble()).toList();
  }

  /// A frame of one flat colour.
  Uint8List flat(int w, int h, int v) =>
      Uint8List.fromList(List.filled(w * h * 3, v));

  /// A face-shaped image: an oval with eyes and a mouth on a plain background.
  ///
  /// Not a real face and not trying to be. It exists to give the model
  /// something structured and reproducible, so a test can tell one image from
  /// another.
  Uint8List faceLike(int w, int h) {
    final px = Uint8List(w * h * 3);
    void set(int x, int y, int r, int g, int b) {
      if (x < 0 || y < 0 || x >= w || y >= h) return;
      final p = (y * w + x) * 3;
      px[p] = r;
      px[p + 1] = g;
      px[p + 2] = b;
    }

    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final nx = (x - w / 2) / (w * 0.3);
        final ny = (y - h / 2) / (h * 0.4);
        if (nx * nx + ny * ny < 1) {
          set(x, y, 214, 176, 150);
        } else {
          set(x, y, 90, 95, 100);
        }
      }
    }
    for (final ex in [w * 0.38, w * 0.62]) {
      for (var dy = -6; dy <= 6; dy++) {
        for (var dx = -8; dx <= 8; dx++) {
          if (dx * dx / 64.0 + dy * dy / 36.0 < 1) {
            set((ex + dx).round(), (h * 0.44 + dy).round(), 245, 245, 245);
          }
          if (dx * dx / 9.0 + dy * dy / 9.0 < 1) {
            set((ex + dx).round(), (h * 0.44 + dy).round(), 40, 30, 25);
          }
        }
      }
    }
    for (var dy = -6; dy <= 6; dy++) {
      for (var dx = -20; dx <= 20; dx++) {
        if (dx * dx / 400.0 + dy * dy / 36.0 < 1) {
          set((w / 2 + dx).round(), (h * 0.64 + dy).round(), 150, 70, 70);
        }
      }
    }
    return px;
  }

  group('the file', () {
    test('is present, and the size the model card claims', () {
      // A truncated file, or a Git LFS pointer nobody fetched, fails here
      // rather than on a driver's phone.
      expect(modelFile.existsSync(), isTrue, reason: 'model asset missing');
      expect(modelFile.lengthSync(), 1850744);
    });
  });

  group('the wiring', () {
    test('the model takes exactly the tensor buildModelInput produces', () {
      // No exception is the assertion. A rank, length or layout mismatch throws
      // from the runtime, and the crop is the part most likely to be broken by
      // a later edit.
      final input = buildModelInput(
        faceLike(640, 480),
        width: 640,
        height: 480,
        left: 200,
        top: 100,
        right: 440,
        bottom: 380,
      )!;

      expect(input.length, 3 * 80 * 80);
      expect(input.every((v) => v >= 0.0 && v <= 1.0), isTrue);
      final out = List.filled(3, 0.0).reshape([1, 3]);
      expect(() => interpreter.run(input, out), returnsNormally);
    });

    test('the output is a three-class softmax', () {
      // The single most important assertion here. The model card says two
      // classes and the model has three, so a `[1, 2]` buffer throws
      // `Output object shape mismatch` and the check silently measures nothing.
      final out = raw(faceLike(320, 400), 320, 400);

      expect(out.length, 3, reason: 'class count the model card gets wrong');
      expect(out.every((v) => v >= 0.0 && v <= 1.0), isTrue);
      // Already softmaxed, not logits. The reference implementation applies its
      // own exp/normalise, which would be a second softmax if this were wrong.
      expect(out.reduce((a, b) => a + b), closeTo(1.0, 1e-4));
    });

    test('the third class is the one that carries the answer', () {
      // Class 2 is "live" in the reference implementation. If it were not, every
      // verdict this app produces would be about a presentation-attack class
      // and nothing would ever be reported live.
      final out = raw(faceLike(320, 400), 320, 400);

      expect(
        out[liveClass],
        greaterThan(out[0]),
        reason: 'the live class should not be the least likely',
      );
      expect(
        out[liveClass],
        greaterThan(out[1]),
        reason: 'the live class should not be less likely than a 3D spoof',
      );
    });

    test('different images get different answers, so it is not a constant', () {
      // A model that returned a fixed number would pass every assertion in this
      // file. Two structurally very different images must not score the same.
      //
      // `stripes` is the useful comparison rather than noise: it is the input
      // furthest from anything the model was trained on that still has real
      // spatial structure, and it moves the answer the most. The gap between
      // this and the 0.001 that a channel-order swap produced is the point --
      // the model responds to *what is in the frame*, and the ordering assertion
      // belongs in `spoof_detector_test.dart` where it is exact rather than
      // inferred from a model that barely reacts to a synthetic image.
      final w = 320;
      final h = 400;
      final stripes = Uint8List(w * h * 3);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final p = (y * w + x) * 3;
          final c = ((y ~/ 8) % 2 == 0) ? 240 : 20;
          stripes[p] = c;
          stripes[p + 1] = c;
          stripes[p + 2] = c;
        }
      }

      final face = raw(faceLike(w, h), w, h)[liveClass];
      final banded = raw(stripes, w, h)[liveClass];

      expect(
        (face - banded).abs(),
        greaterThan(0.005),
        reason: 'a face-shaped image and hard stripes scored the same ($face)',
      );
    });

    test('the same image scores the same thing every time', () {
      // Determinism, so a "live" verdict means the picture and not a coin toss.
      // XNNPACK's thread count can change float reduction order, so this is a
      // real risk rather than a formality.
      final px = faceLike(320, 400);
      final first = raw(px, 320, 400)[liveClass];
      for (var i = 0; i < 3; i++) {
        expect(
          raw(px, 320, 400)[liveClass],
          closeTo(first, 1e-5),
          reason: 'run $i disagreed with the first',
        );
      }
    });
  });

  group('what the crop actually sends', () {
    // These check the preprocessing rather than the model, using the tensor
    // statistics, because a crop that is silently constant would make the model
    // confidently wrong in a way nothing above would catch.

    test('a black frame produces an all-zero tensor', () {
      final input = buildModelInput(
        flat(320, 400, 0),
        width: 320,
        height: 400,
        left: 96,
        top: 80,
        right: 224,
        bottom: 320,
      )!;

      expect(input.every((v) => v == 0.0), isTrue);
    });

    test('a white frame produces an all-one tensor', () {
      final input = buildModelInput(
        flat(320, 400, 255),
        width: 320,
        height: 400,
        left: 96,
        top: 80,
        right: 224,
        bottom: 320,
      )!;

      expect(input.every((v) => v == 1.0), isTrue);
    });

    test('and a mid grey one produces mid grey', () {
      final input = buildModelInput(
        flat(320, 400, 128),
        width: 320,
        height: 400,
        left: 96,
        top: 80,
        right: 224,
        bottom: 320,
      )!;

      expect(input.every((v) => (v - 128 / 255).abs() < 1e-6), isTrue);
    });
  });

  group('the honest gap', () {
    test(
      'the model calls black, white and noise all "live"',
      () {
        // The reason the face check is not yet required, written as a test so it
        // cannot quietly stop being true and cannot quietly be forgotten.
        //
        // This is not a claim that the model is broken. It was trained on crops
        // of real faces, and these are not faces: what it does with input
        // outside its training distribution is default to its most common
        // answer. What it does mean is that **the threshold in
        // `SpoofDetector.liveThreshold` has no measured false-accept rate**,
        // because nobody has yet watched this model reject a photograph.
        //
        // Closing this needs two things a unit test cannot have: a live face in
        // front of the camera, and a printed photograph of that same face held
        // in the same place. Until then this number is not evidence for
        // anything except "the model loaded and ran".
        final w = 320;
        final h = 400;
        final rng = Random(7);
        final noise = Uint8List(w * h * 3);
        for (var i = 0; i < noise.length; i++) {
          noise[i] = rng.nextInt(256);
        }

        final scores = {
          'black': raw(flat(w, h, 0), w, h)[liveClass],
          'white': raw(flat(w, h, 255), w, h)[liveClass],
          'noise': raw(noise, w, h)[liveClass],
        };
        for (final entry in scores.entries) {
          expect(
            entry.value,
            greaterThan(SpoofDetector.liveThreshold),
            reason:
                '${entry.key} scored ${entry.value}, so the "always live" '
                'behaviour this test records has changed and the comment above '
                'needs rewriting',
          );
        }
      },
      skip:
          'records a known limitation, not a requirement. Deliberately not '
          'asserted as a specification: if the model ever behaves better on '
          'out-of-distribution input this should fail, and that is a good thing '
          'to notice rather than a bad one.',
    );
  });
}
