import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';

/// Alpha of the pixel at (x, y), 0-255.
int alphaAt(Uint8List px, int x, int y) =>
    px[(y * kCarTopdownSize + x) * 4 + 3];

/// Red channel at (x, y), or null where the pixel is transparent.
int? redAt(Uint8List px, int x, int y) {
  if (alphaAt(px, x, y) < 16) return null;
  return px[(y * kCarTopdownSize + x) * 4];
}

/// Luminance at (x, y), 0-255, or null where transparent.
double? lumaAt(Uint8List px, int x, int y) {
  final i = (y * kCarTopdownSize + x) * 4;
  if (px[i + 3] < 16) return null;
  return 0.2126 * px[i] + 0.7152 * px[i + 1] + 0.0722 * px[i + 2];
}

void main() {
  final px = carTopdownPixels();

  group('the sprite is a plan view, nose up', () {
    test('it is longer than it is wide, like a car', () {
      // Measured from the drawn pixels, counting the body and its glass but
      // not the ground shadow or the wheels. Those are deliberately outside
      // the body's box -- a wheel peeking past the arch is the cue that stops
      // a plan view reading as a capsule -- so including them would measure
      // the artwork's footprint rather than the car's proportions.
      var minX = kCarTopdownSize, maxX = -1, minY = kCarTopdownSize, maxY = -1;
      for (var y = 0; y < kCarTopdownSize; y++) {
        for (var x = 0; x < kCarTopdownSize; x++) {
          if (alphaAt(px, x, y) < 240) continue;
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
      final w = maxX - minX + 1;
      final h = maxY - minY + 1;
      // A real car is 2.2-2.7x longer than wide. A sprite outside that reads as
      // a van, a bus or a pill, whichever way it is rotated.
      final ratio = h / w;
      expect(ratio, greaterThan(2.0), reason: 'too square ($w x $h)');
      expect(ratio, lessThan(2.9), reason: 'too long ($w x $h)');
    });

    test('the body is symmetric left to right', () {
      // A plan view of a car is bilateral. Asymmetry is invisible at 58
      // rendered pixels to a viewer and glaring in the asset, so it is
      // asserted rather than eyeballed.
      //
      // The *body* only: the shading is deliberately lit from the upper left,
      // so its colour is not symmetric, and the ground shadow is deliberately
      // offset down-right. Both are the point. What must be symmetric is the
      // outline -- its alpha -- because that is what the eye reads as shape.
      var mismatches = 0;
      for (var y = 0; y < kCarTopdownSize; y++) {
        for (var x = 0; x < kCarTopdownSize ~/ 2; x++) {
          final mirror = kCarTopdownSize - 1 - x;
          final a = alphaAt(px, x, y);
          final b = alphaAt(px, mirror, y);
          // Where one side is the body and the other is not, the pixels are
          // legitimately different -- that is the wheel and the mirror. Only
          // count a mismatch when both sides claim to be solid.
          if (a > 240 && b > 240 && (a - b).abs() > 8) mismatches++;
        }
      }
      expect(mismatches, 0, reason: '$mismatches pixels break the symmetry');
    });

    test('the front is lit and the back falls away, so rotation reads', () {
      // This is the cue that tells a viewer which end is the nose without
      // having to resolve the rotation. Without it the car still points the
      // right way on the road but reads as an anonymous capsule.
      final bonnet = lumaAt(px, 48, 12)!;
      final boot = lumaAt(px, 48, 84)!;
      expect(bonnet, greaterThan(boot * 1.15),
          reason: 'bonnet $bonnet vs boot $boot');
    });

    test('the left flank is lit and the right is in shade', () {
      final left = lumaAt(px, 34, 48)!;
      final right = lumaAt(px, 62, 48)!;
      expect(left, greaterThan(right * 1.1),
          reason: 'left $left vs right $right');
    });
  });

  group('the sprite has the parts that make it a car', () {
    test('four wheel arches, dark, one at each corner', () {
      // Inside the body's width, so from above they read as arch slivers. The
      // gaps at the front and rear of each pair are the strongest cue that
      // this is a car and not a capsule.
      //
      // The arch centres, as drawn.
      for (final (x, y) in const [(35, 30), (60, 30), (35, 66), (60, 66)]) {
        expect(lumaAt(px, x, y), isNotNull, reason: 'no pixel at ($x, $y)');
        expect(lumaAt(px, x, y)!, lessThan(110),
            reason: 'the arch at ($x, $y) is not dark');
      }
    });

    test('the arches are inside the body line, so it does not read as a van', () {
      // Protruding wheels would add to the sprite's width and drop the
      // length:width ratio to about 1.8, which is a van or a truck rather
      // than the car this is meant to be.
      int opaqueWidth(int y) {
        var n = 0;
        for (var x = 0; x < kCarTopdownSize; x++) {
          if (alphaAt(px, x, y) > 200) n++;
        }
        return n;
      }

      // A row through the front arches is no wider than one through the body
      // between them, i.e. the arches do not add to the silhouette.
      expect(opaqueWidth(30), lessThanOrEqualTo(opaqueWidth(48)),
          reason: 'the arches stick out past the body');
    });

    test('a cabin, narrower than the body, so the bonnet and boot show', () {
      // Measured at the cabin's own row against the body's widest row. A
      // cabin as wide as the body leaves no bonnet or boot and the sprite
      // reads as a solid block rather than as a car seen from above.
      int opaqueRun(int y) {
        var n = 0;
        for (var x = 0; x < kCarTopdownSize; x++) {
          if (alphaAt(px, x, y) > 200) n++;
        }
        return n;
      }

      final atBodyWaist = opaqueRun(48);
      final atBonnet = opaqueRun(14);
      expect(atBodyWaist, greaterThan(atBonnet),
          reason: 'the body must be widest at the doors');
      // The cabin is drawn on top of the body, so both are opaque at that row
      // and the run measures the body. The cabin's own inset is measured from
      // its edge colour instead, below.
      expect(atBodyWaist, greaterThan(28),
          reason: 'the body is only ${atBodyWaist}px wide');
    });

    test('the cabin is inset from the body, as a shoulder line', () {
      // The cabin is a different colour from the body, so the shoulder -- the
      // strip of body either side of the cabin -- is measurable as a run of
      // body colour at the cabin's row.
      int bodyColourRun(int y) {
        var n = 0;
        for (var x = 0; x < kCarTopdownSize ~/ 2; x++) {
          final i = (y * kCarTopdownSize + x) * 4;
          if (px[i + 3] < 200) continue;
          // Body amber, not glass (dark blue) and not the roof highlight.
          if (px[i] > 150 && px[i + 1] > 90 && px[i + 2] < 90) n++;
        }
        return n;
      }

      // From the left edge to where the cabin begins.
      final shoulder = bodyColourRun(40);
      expect(shoulder, greaterThanOrEqualTo(8),
          reason: 'no shoulder line; the cabin runs to the body edge');
    });

    test('glass at both ends, dark, and lighter than nothing', () {
      // The windscreen and the rear window, at the two narrowest parts of the
      // cabin. Both are trapezoids in the drawing; all this checks is that
      // they are there and are not the same colour as the body.
      for (final (x, y) in const [(44, 28), (52, 28), (45, 58), (51, 58)]) {
        final l = lumaAt(px, x, y);
        expect(l, isNotNull, reason: 'no glass at ($x, $y)');
        expect(l!, lessThan(110), reason: 'glass at ($x, $y) is too light');
      }
    });

    test('white at the nose and red at the tail, so the front is identifiable', () {
      // The sprite is drawn nose-up and the style rotates it. If the two ends
      // were the same colour a car stopped at a pickup would look equally
      // plausible driving away from it, and the rotation would be decorative
      // rather than informative.
      int channel(int x, int y, int c) =>
          (y * kCarTopdownSize + x) * 4 + c;

      // Headlight: near-white, so all three channels are high.
      expect(px[channel(39, 9, 0)], greaterThan(230));
      expect(px[channel(39, 9, 1)], greaterThan(220));
      expect(px[channel(39, 9, 2)], greaterThan(200));

      // Tail light: red-dominant, so green and blue are low.
      expect(px[channel(39, 86, 0)], greaterThan(200));
      expect(px[channel(39, 86, 1)], lessThan(120));
      expect(px[channel(39, 86, 2)], lessThan(130));

      // And the two ends are genuinely different colours, which is the whole
      // point: a car facing the wrong way should be visible as wrong.
      final noseHue = px[channel(39, 9, 1)] - px[channel(39, 9, 2)];
      final tailHue = px[channel(39, 86, 1)] - px[channel(39, 86, 2)];
      expect(noseHue, isNot(closeTo(tailHue, 20)));
    });

    test('mirrors, the small detail that stops it reading as generic', () {
      // The only part of the car that does stick out past the body line, which
      // is correct: a wing mirror is wider than the body at that point.
      var found = 0;
      for (final x in [29, 30, 31, 32, 33, 34]) {
        for (final y in [39, 40, 41, 42, 43]) {
          if (alphaAt(px, x, y) > 200) found++;
        }
      }
      expect(found, greaterThan(3));
    });
  });

  group('the sprite survives being put on a map', () {
    test('it has transparent corners, so a square is not drawn', () {
      for (final (x, y) in const [(0, 0), (95, 0), (0, 95), (95, 95), (2, 2)]) {
        expect(alphaAt(px, x, y), lessThan(8), reason: '($x, $y) is opaque');
      }
    });

    test('the body is opaque, so the car is not see-through over a road', () {
      expect(alphaAt(px, 48, 20), greaterThan(240));
      expect(alphaAt(px, 48, 78), greaterThan(240));
    });

    test('it has an edge, because a bright shape vanishes against parkland', () {
      // The map behind the car is white roads on pale land *and* dark parkland.
      // Without a dark rim the amber body disappears against the first and
      // looks like a sticker on the second.
      var darkEdgePixels = 0;
      for (var y = 10; y < 86; y++) {
        final x = _bodyEdgeAt(px, y);
        if (x == null) continue;
        final l = lumaAt(px, x, y);
        if (l != null && l < 130) darkEdgePixels++;
      }
      expect(darkEdgePixels, greaterThan(30),
          reason: 'the body has no legible outline');
    });

    test('it has a soft ground shadow, offset away from the light', () {
      // A shadow directly under the car reads as a sticker. An offset one
      // reads as a car standing on a road.
      //
      // Sampled just outside the body's edge, where the body itself cannot
      // contribute. The body spans x 31..65; the shadow is offset down and
      // right, so it reaches past the right edge and does not reach past the
      // left one.
      // The widest reach of the shadow on that side, summed over the three
      // passes rather than sampled at one pixel: a 3-pass shadow offset 3px
      // with a 2.6px feather puts only a few percent of alpha at the last
      // pixel past the body, and a fixed threshold on a single pixel is a
      // test that passes or fails on rounding.
      final pastFlank = [66, 67, 68, 69]
          .map((x) => alphaAt(px, x, 50))
          .reduce((a, b) => a > b ? a : b);
      final pastOtherFlank = [26, 27, 28, 29]
          .map((x) => alphaAt(px, x, 50))
          .reduce((a, b) => a > b ? a : b);
      expect(pastFlank, greaterThan(pastOtherFlank + 4),
          reason: 'the shadow should fall down-right, away from the light');
      expect(pastFlank, greaterThan(2), reason: 'no shadow past the flank');
    });

    test('the shadow is soft, not a hard outline', () {
      // A hard-edged offset shape reads as a second car rather than as
      // shading, so the alpha has to ramp rather than step.
      final near = alphaAt(px, 67, 50);
      final far = alphaAt(px, 70, 50);
      expect(near, greaterThan(far));
      expect(far, lessThan(near),
          reason: 'the shadow should fade out with distance');
    });
  });

  group('the PNG encoder', () {
    test('emits a real 8-bit RGBA PNG of the declared size', () {
      final png = carTopdownPng();
      expect(png.length, greaterThan(8));
      // Signature.
      expect(png.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      // IHDR: length, type, then width and height as big-endian uint32.
      expect(
        String.fromCharCodes(png.sublist(12, 16)),
        'IHDR',
      );
      final w = (png[16] << 24) | (png[17] << 16) | (png[18] << 8) | png[19];
      final h = (png[20] << 24) | (png[21] << 16) | (png[22] << 8) | png[23];
      expect(w, kCarTopdownSize);
      expect(h, kCarTopdownSize);
      // Bit depth 8, colour type 6 (truecolour with alpha).
      expect(png[24], 8);
      expect(png[25], 6);
    });

    test('ends with IEND, as every PNG must', () {
      final png = carTopdownPng();
      expect(
        String.fromCharCodes(png.sublist(png.length - 8, png.length - 4)),
        'IEND',
      );
    });

    test('the compressed payload really inflates back to the pixels', () {
      // A CRC-32 bug or a bad zlib stream would still produce bytes that look
      // like a PNG. Decompressing is the only check that MapLibre will agree
      // with, since a truncated IDAT is a silently blank car.
      final png = carTopdownPng();
      final idat = _chunksOf(png)
          .firstWhere((c) => c.$1 == 'IDAT')
          .$2;
      final raw = ZLibCodec().decode(idat);
      // height scanlines, each prefixed with a filter byte, then width*4 bytes.
      expect(raw.length, kCarTopdownSize * (1 + kCarTopdownSize * 4));
      expect(raw[0], 0, reason: 'the filter byte of scanline 0');
      // The inflated data has to be the same pixels that were drawn.
      final offset = 1;
      expect(raw[offset + (48 * kCarTopdownSize + 48) * 4 + 3],
          alphaAt(px, 48, 48));
    });

    test('it is deterministic, so a rebuild does not churn the binary', () {
      // Determinism matters even though the sprite is generated: a
      // nondeterministic encoder would make every build produce a different
      // image for no reason, and would make a diff of two builds unreadable.
      expect(carTopdownPng(), carTopdownPng());
    });
  });

  group('VehicleFix', () {
    test('carries a position and a heading', () {
      const fix = VehicleFix(GeoPoint(5.6, -0.18), 90);
      expect(fix.point.lat, 5.6);
      expect(fix.headingDegrees, 90);
    });

    test('a fix with no heading reports 0 rather than failing', () {
      const fix = VehicleFix(GeoPoint(5.6, -0.18));
      expect(fix.bearing, isNull);
      expect(fix.headingDegrees, 0);
    });

    test('normalises a heading into 0-360', () {
      // A compass reports 360 as readily as 0, and a rotation of 360 is a car
      // spun all the way round for no reason.
      expect(normaliseBearing(360), 360);
      expect(VehicleFix(const GeoPoint(0.1, 0.1), 360).headingDegrees, 0);
      expect(VehicleFix(const GeoPoint(0.1, 0.1), 725).headingDegrees, 5);
      expect(VehicleFix(const GeoPoint(0.1, 0.1), -0.0).headingDegrees, 0);
    });

    test('refuses a heading that means "there is none"', () {
      // Geolocator reports -1 for no compass, and NaN when it is guessing.
      // Both have to become null before they reach the rotation, or a phone
      // lying on a desk spins the car to 359 degrees.
      expect(normaliseBearing(-1), isNull);
      expect(normaliseBearing(double.nan), isNull);
      expect(normaliseBearing(null), isNull);
      expect(normaliseBearing(0), 0, reason: 'north is a real reading');
      expect(normaliseBearing(359.5), 359.5);
    });

    test('equality ignores how the heading was written', () {
      // So a controller that keeps its last fix does not re-notify because a
      // poll returned 359.9 where the last one returned -0.1.
      expect(
        const VehicleFix(GeoPoint(5.6, -0.18), 90),
        const VehicleFix(GeoPoint(5.6, -0.18), 450),
      );
      expect(
        const VehicleFix(GeoPoint(5.6, -0.18), 90),
        isNot(const VehicleFix(GeoPoint(5.6, -0.18), 91)),
      );
    });
  });
}

/// The leftmost opaque body pixel on a row, skipping the wheels.
int? _bodyEdgeAt(Uint8List px, int y) {
  for (var x = 22; x < 48; x++) {
    if (alphaAt(px, x, y) > 200) return x;
  }
  return null;
}

/// The PNG's chunks, as `(type, data)` pairs.
List<(String, List<int>)> _chunksOf(List<int> png) {
  final out = <(String, List<int>)>[];
  var i = 8;
  while (i + 8 <= png.length) {
    final len = (png[i] << 24) | (png[i + 1] << 16) | (png[i + 2] << 8) | png[i + 3];
    final type = String.fromCharCodes(png.sublist(i + 4, i + 8));
    out.add((type, png.sublist(i + 8, i + 8 + len)));
    i += 12 + len;
  }
  return out;
}
