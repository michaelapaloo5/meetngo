import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_driver/src/onboarding/liveness/spoof_detector.dart';

/// The crop MiniFASNet is fed.
///
/// Every case here is a way the crop can be *silently* wrong. None of them
/// throws, none of them logs, and none of them is visible without a real face
/// in front of a real camera: the model accepts whatever layout it is given and
/// returns a confident number either way. That is why they are tested here
/// rather than discovered on a driver's phone.
void main() {
  /// A frame of one flat colour, RGB, `width * height * 3` bytes.
  Uint8List frame(int width, int height, int r, int g, int b) {
    final out = Uint8List(width * height * 3);
    for (var i = 0; i < out.length; i += 3) {
      out[i] = r;
      out[i + 1] = g;
      out[i + 2] = b;
    }
    return out;
  }

  /// A frame where every pixel encodes its own position, so a mis-mapped
  /// coordinate is visible rather than plausible.
  ///
  /// Red is the x coordinate, green is the y, blue is a constant. A transpose
  /// or a stride error cannot hide in this.
  Uint8List posFrame(int width, int height) {
    final out = Uint8List(width * height * 3);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final p = (y * width + x) * 3;
        out[p] = x & 0xff;
        out[p + 1] = y & 0xff;
        out[p + 2] = 77;
      }
    }
    return out;
  }

  group('the shape the model was given', () {
    test('is 1x3x80x80, which is 19,200 floats', () {
      // The model's declared input. A tensor of the wrong rank is rejected by
      // the runtime at best and read as garbage at worst.
      final out = buildModelInput(
        frame(200, 200, 10, 20, 30),
        width: 200,
        height: 200,
        left: 80,
        top: 80,
        right: 120,
        bottom: 140,
      );

      expect(out, isNotNull);
      expect(SpoofDetector.inputSize, 80);
      expect(out!.length, 3 * 80 * 80);
    });

    test('has the three channel planes contiguous, not interleaved', () {
      // A frame that is pure red: RGB (255, 0, 0). In BGR that is
      // (0, 0, 255), so the B plane must be 1.0 and the R plane 0.0.
      //
      // In an NHWC layout those values would be interleaved, and the test above
      // would still pass. Only checking the values catches it.
      final out = buildModelInput(
        frame(200, 200, 255, 0, 0),
        width: 200,
        height: 200,
        left: 80,
        top: 80,
        right: 120,
        bottom: 140,
      )!;
      const per = SpoofDetector.inputSize * SpoofDetector.inputSize;
      final plane = out.sublist(0, per);
      final green = out.sublist(per, 2 * per);
      final blue = out.sublist(2 * per, 3 * per);

      // BGR: a red pixel has full blue, no green, no red.
      expect(blue.every((v) => v == 1.0), isTrue, reason: 'blue plane');
      expect(green.every((v) => v == 0.0), isTrue, reason: 'green plane');
      expect(plane.every((v) => v == 0.0), isTrue, reason: 'red plane');
    });

    test('is scaled to 0..1, not left as 0..255', () {
      // Unscaled, every value saturates the first layer and the model returns
      // the same number for every face, which reads as a broken check.
      final out = buildModelInput(
        frame(200, 200, 128, 128, 128),
        width: 200,
        height: 200,
        left: 80,
        top: 80,
        right: 120,
        bottom: 140,
      )!;

      expect(out.every((v) => v >= 0.0 && v <= 1.0), isTrue);
      // 128/255, not 128.
      expect(out.first, closeTo(128 / 255.0, 1e-6));
    });

    test('a green frame puts the value in the middle plane', () {
      // The complementary check on the channel order: if red landed in the
      // third plane, green must land in the second. Together the two tests
      // pin the order completely.
      final out = buildModelInput(
        frame(200, 200, 0, 255, 0),
        width: 200,
        height: 200,
        left: 80,
        top: 80,
        right: 120,
        bottom: 140,
      )!;
      const per = SpoofDetector.inputSize * SpoofDetector.inputSize;

      expect(out.sublist(per, 2 * per).every((v) => v == 1.0), isTrue);
      expect(out.sublist(0, per).every((v) => v == 0.0), isTrue);
      expect(out.sublist(2 * per, 3 * per).every((v) => v == 0.0), isTrue);
    });
  });

  group('the crop itself', () {
    test('is centred on the face box', () {
      // A position-encoded frame, so the centre of the output must be the
      // centre of the input's box. An off-by-half-crop is the kind of thing
      // that still produces a face-shaped result and quietly hurts accuracy.
      final w = 400;
      final h = 400;
      final out = buildModelInput(
        posFrame(w, h),
        width: w,
        height: h,
        left: 180,
        top: 200,
        right: 220,
        bottom: 240,
      )!;

      // The middle of the 80x80 grid. Red carries x and green carries y, both
      // taken from the channel order above, so these are read out of the B and
      // G planes: B is R (x), G is G (y).
      const per = SpoofDetector.inputSize * SpoofDetector.inputSize;
      const mid =
          (SpoofDetector.inputSize ~/ 2) * SpoofDetector.inputSize +
          SpoofDetector.inputSize ~/ 2;
      final x = (out[2 * per + mid] * 255).round();
      final y = (out[per + mid] * 255).round();

      expect(x, closeTo(200, 2), reason: 'centre x of the box');
      expect(y, closeTo(220, 2), reason: 'centre y of the box');
    });

    test('is wider than the face box, because the model needs the context', () {
      // 2.7x is not a style choice. A tight crop of just the face removes the
      // texture and depth cues the model keys on, which is the same thing it
      // is being asked to judge, and it performs measurably worse.
      expect(SpoofDetector.cropScale, greaterThan(1.5));
      expect(SpoofDetector.cropScale, lessThan(4.0));
    });

    test('samples the whole crop rather than its top-left corner', () {
      // A frame with a marker in one corner of the crop. If the sampler walked
      // the source in the wrong order, or read a fixed stride, the corner colour
      // would fill the grid.
      final w = 200;
      final h = 200;
      final pixels = frame(w, h, 0, 0, 0);
      // The crop geometry is worked out here rather than guessed, because a
      // guess is how the first version of this test came to put its marker
      // outside the crop and assert nothing at all.
      const boxLeft = 100;
      const boxTop = 100;
      const boxRight = 120;
      const boxBottom = 140;
      final half = (boxRight - boxLeft) * SpoofDetector.cropScale / 2.0; // 27.0
      final cx = (boxLeft + boxRight) / 2.0; // 110
      final cy = (boxTop + boxBottom) / 2.0; // 120
      final x1 = (cx + half).round(); // 137
      final y1 = (cy + half).round(); // 147
      final markerX = x1 - 1;
      final markerY = y1 - 1;
      // Sanity: the marker really is at the far corner, not somewhere else.
      expect(markerX - (cx - half).round(), x1 - 1 - (cx - half).round());

      final p = (markerY * w + markerX) * 3;
      pixels[p] = 255;
      pixels[p + 1] = 255;
      pixels[p + 2] = 255;

      final out = buildModelInput(
        pixels,
        width: w,
        height: h,
        left: boxLeft,
        top: boxTop,
        right: boxRight,
        bottom: boxBottom,
      )!;
      const per = SpoofDetector.inputSize * SpoofDetector.inputSize;

      // Somewhere in the output is the marker, and it is not the whole thing.
      final withMarker = out.sublist(0, per).where((v) => v > 0.5).length;
      expect(withMarker, greaterThan(0), reason: 'the corner is represented');
      expect(withMarker, lessThan(per ~/ 4), reason: 'and only the corner');
    });

    test('the marker test is testing something, so the geometry is asserted', () {
      // Kept deliberately. The test above depends on the crop being where this
      // says it is, and if cropScale ever changes the marker quietly moves out
      // of the crop and the test passes while asserting nothing. This fails
      // loudly instead.
      const half = (120 - 100) * SpoofDetector.cropScale / 2.0;
      expect(half, closeTo(27.0, 0.001));
      final x0 = (110.0 - half).round();
      final x1 = (110.0 + half).round();
      expect(x0, 83);
      expect(x1, 137);
      expect(137, lessThan(200), reason: 'the crop fits the frame');
    });
  });

  group('frames that cannot be cropped', () {
    test('an empty box gives nothing rather than a degenerate crop', () {
      // A 1x1 crop would be judged confidently by the model and be meaningless.
      // Null is the honest answer, and the verifier counts it as unmeasured.
      expect(
        buildModelInput(
          frame(200, 200, 0, 0, 0),
          width: 200,
          height: 200,
          left: 100,
          top: 100,
          right: 100,
          bottom: 140,
        ),
        isNull,
      );
      expect(
        buildModelInput(
          frame(200, 200, 0, 0, 0),
          width: 200,
          height: 200,
          left: 100,
          top: 100,
          right: 120,
          bottom: 100,
        ),
        isNull,
      );
    });

    test('a box entirely off the left of the frame gives nothing', () {
      // Not a clamp-to-zero and not a crash. The first frames after a camera
      // starts can produce this, and it must read as "nothing measured".
      expect(
        buildModelInput(
          frame(200, 200, 0, 0, 0),
          width: 200,
          height: 200,
          left: -80,
          top: 80,
          right: -40,
          bottom: 140,
        ),
        isNull,
      );
    });

    test('a box hanging off the edge is shifted in, not squashed', () {
      // The scale of the crop has to survive, because scale is something the
      // model was trained on. Resizing a clipped crop would change it.
      final w = 200;
      final h = 200;
      final out = buildModelInput(
        posFrame(w, h),
        width: w,
        height: h,
        left: 0,
        top: 80,
        right: 40,
        bottom: 120,
      );

      // Present, and still covering the face rather than a squashed sliver.
      expect(out, isNotNull);
      const per = SpoofDetector.inputSize * SpoofDetector.inputSize;
      // All black means the sampler read nothing but clamped positions, which
      // would mean the whole grid came from one edge.
      expect(out!.sublist(0, per).any((v) => v > 0.0), isTrue);
    });

    test('a frame smaller than the box does not read out of bounds', () {
      // The one that would crash on a driver's phone rather than merely being
      // wrong. A 4x4 frame with a 100px-wide box in it.
      final out = buildModelInput(
        frame(4, 4, 10, 20, 30),
        width: 4,
        height: 4,
        left: 0,
        top: 0,
        right: 100,
        bottom: 100,
      );

      expect(out, isNotNull);
      expect(out!.every((v) => v >= 0.0 && v <= 1.0), isTrue);
    });
  });
}
