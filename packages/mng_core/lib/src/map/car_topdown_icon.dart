import 'dart:io';
import 'dart:math' show sqrt;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// The car sprite, drawn nose-up, for the style's `moving-car-icon` layer.
///
/// Registered under [kCarTopdownIconName] and rotated by the style's
/// `icon-rotate`, which turns it clockwise from up. So this image is drawn once
/// facing north and is correct at every heading, and nothing about a particular
/// camera bearing is baked into the pixels.
///
/// Drawn in code rather than shipped as a PNG. A sprite is a binary nobody can
/// review in a diff, and this way its shape is a description that tests can
/// assert on: "there is a wheel on each side", "the nose is lighter than the
/// tail" and "the body is opaque but the corners are not" are checkable
/// statements here and not statements at all about a `.png` in the repo.
///
/// The plan view is what makes this read as a vehicle at map scale. A side-on
/// car, which is what this replaced, is recognisable but wrong: rotated to face
/// the direction of travel on a top-down map it looks like the car is lying on
/// its roof. Seen from directly above, a car is recognisable by its silhouette
/// — long, narrow, with a cabin inset from the body and glass at each end — and
/// that is what is drawn.
const int kCarTopdownSize = 96;

/// The sprite's PNG bytes, 8-bit RGBA, [kCarTopdownSize] square.
Uint8List carTopdownPng() => _encodePng(carTopdownPixels(), kCarTopdownSize);

/// The car's pixels, row-major RGBA, top row first.
///
/// Exposed so the tests can assert on the drawing itself -- that the nose is
/// lighter than the boot, that the wheels are where wheels go, that the corners
/// are transparent. Asserting those against a `.png` in the repository is
/// impossible, and asserting only that the encoder emits a PNG would leave the
/// artwork itself entirely untested, which is the part that actually goes wrong
/// when someone changes a colour.
///
/// Drawn in four passes, in the order they have to be painted: shadow, wheels,
/// body, then the details that sit on top of the body. Source-over throughout,
/// so each pass blends onto what is already there rather than replacing it.
@visibleForTesting
Uint8List carTopdownPixels() {
  const s = kCarTopdownSize;
  final out = Uint8List(s * s * 4);

  void blend(int x, int y, int r, int g, int b, double a) {
    if (x < 0 || y < 0 || x >= s || y >= s || a <= 0) return;
    final i = (y * s + x) * 4;
    final outA = out[i + 3] / 255.0;
    final oa = a + outA * (1 - a);
    if (oa <= 0) return;
    out[i] = ((r / 255.0 * a + out[i] / 255.0 * outA * (1 - a)) / oa * 255)
        .round()
        .clamp(0, 255);
    out[i + 1] = ((g / 255.0 * a + out[i + 1] / 255.0 * outA * (1 - a)) / oa * 255)
        .round()
        .clamp(0, 255);
    out[i + 2] = ((b / 255.0 * a + out[i + 2] / 255.0 * outA * (1 - a)) / oa * 255)
        .round()
        .clamp(0, 255);
    out[i + 3] = (oa * 255).round().clamp(0, 255);
  }

  /// Distance from [p] to the rounded rectangle it belongs to, 0 inside.
  ///
  /// A signed distance field rather than a pixel loop per shape: one function
  /// draws the body, the cabin, the glass, the lights and the wheels, and
  /// `0.5` pixels of antialiasing fall out of it for free. Without it every
  /// edge is a hard staircase and the sprite looks like it was cut out with
  /// scissors, which at 58 rendered pixels is visible.
  double roundedBoxSdf(
    double px,
    double py,
    double cx,
    double cy,
    double halfW,
    double halfH,
    double r,
  ) {
    final qx = (px - cx).abs() - (halfW - r);
    final qy = (py - cy).abs() - (halfH - r);
    final ax = qx > 0 ? qx : 0.0;
    final ay = qy > 0 ? qy : 0.0;
    final outside = sqrt(ax * ax + ay * ay);
    // Inside the box on one axis and outside on the other, the distance is the
    // larger of the two overshoots; inside both, it is the larger of the two
    // negatives. Whichever is greater is the nearest edge, either way.
    final inside = qx > qy ? qx : qy;
    return outside + (inside > 0 ? 0 : inside) - r;
  }

  /// Paint a rounded rectangle, with [r] radius, as one flat colour.
  void box(
    double cx,
    double cy,
    double halfW,
    double halfH,
    double r,
    int col,
    double a, {
    double feather = 0.9,
  }) {
    final x0 = (cx - halfW - feather - 1).floor();
    final x1 = (cx + halfW + feather + 1).ceil();
    final y0 = (cy - halfH - feather - 1).floor();
    final y1 = (cy + halfH + feather + 1).ceil();
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        final d = roundedBoxSdf(
          x + 0.5,
          y + 0.5,
          cx,
          cy,
          halfW,
          halfH,
          r,
        );
        final cov = (0.5 - d / feather).clamp(0.0, 1.0);
        if (cov <= 0) continue;
        blend(x, y, (col >> 16) & 0xFF, (col >> 8) & 0xFF, col & 0xFF,
            a * cov);
      }
    }
  }

  // Geometry, in the 96x96 sprite's own pixels. A sedan is about 2.6x longer
  // than it is wide; 84x34 is 2.47, which reads as a car rather than as a
  // bus at the 58px this is drawn at, and leaving the margins is what lets the
  // ground shadow and the wheels fall outside the body without being clipped.
  const bodyCx = 48.0;
  const bodyCy = 48.0;
  const bodyHalfW = 17.0;
  const bodyHalfH = 42.0;
  const bodyR = 15.0;

  // The ambient occlusion under the car. Offset down and right, because the
  // light this sprite pretends comes from is up and to the left -- which is also
  // why the body is lit on its left edge below. A shadow directly under the car
  // reads as a sticker; an offset one reads as a car standing on the road.
  for (final (dx, dy, a) in const [(3.0, 4.0, 0.10), (2.0, 2.5, 0.14), (1.0, 1.5, 0.20)]) {
    box(
      bodyCx + dx,
      bodyCy + dy,
      bodyHalfW * 0.98,
      bodyHalfH * 0.99,
      bodyR,
      0x0B1020,
      a,
      feather: 2.6,
    );
  }

  // The body, lit from up-left. The gradient runs along the car's length, not
  // across it: along it, the bonnet catches the light and the boot falls away,
  // which is what tells a viewer which end is the front before they have
  // worked out the rotation. Across it there is a bright left flank and a
  // darker right one, which is what gives the flat plan view any sense of
  // volume at all.
  for (var y = 4; y <= 92; y++) {
    final ty = ((y - 4) / 88.0).clamp(0.0, 1.0);
    for (var x = 28; x <= 68; x++) {
      final tx = ((x - 28) / 40.0).clamp(0.0, 1.0);
      final d = roundedBoxSdf(x + 0.5, y + 0.5, bodyCx, bodyCy, bodyHalfW,
          bodyHalfH, bodyR);
      if (d > 0.6) continue;
      final cov = (0.5 - d / 1.2).clamp(0.0, 1.0);
      if (cov <= 0) continue;
      // Bonnet bright, boot darker: a 26% fall from nose to tail.
      final shade = 1.0 - 0.26 * ty;
      // Left flank lit, right flank in shade: a 20% fall across the width.
      final flank = 1.0 - 0.20 * tx;
      final k = (shade * flank).clamp(0.0, 1.0);
      blend(
        x,
        y,
        (0xF5 * k).round(),
        (0xB3 * k).round(),
        (0x01 * k * k).round(),
        cov,
      );
    }
  }

  // Wheel arches. Thin dark slivers hugging the inside of the body's edge --
  // deliberately subtle, because a fat black bar here reads as a slab laid
  // across the car rather than as a wheel. From directly above almost all a
  // wheel hides under its arch; what is visible is a narrow dark crescent at
  // the flank, and that is what is drawn. The length is the axle's position:
  // front arches behind the bonnet, rear arches ahead of the boot.
  for (final y in const [30.0, 66.0]) {
    for (final x in const [35.5, 60.5]) {
      box(x, y, 2.2, 7.0, 2.2, 0x2A2F3A, 0.9);
    }
  }
  // A thin bright edge on the outboard side of each arch, which is the arch
  // lip catching the light. It is what stops the crescent reading as a hole
  // cut in the body.
  for (final y in const [30.0, 66.0]) {
    for (final x in const [33.4, 62.6]) {
      box(x, y, 0.9, 6.0, 0.8, 0xFFDE8A, 0.8);
    }
  }

  // A dark rim around the whole body, 1.5px. The map behind the car is white
  // roads on pale land *and* dark parkland, and a bright amber shape with no
  // edge disappears against the first and looks like a sticker on the second.
  // The rim is what keeps it legible on both.
  for (var y = 3; y <= 93; y++) {
    for (var x = 27; x <= 69; x++) {
      final d = roundedBoxSdf(x + 0.5, y + 0.5, bodyCx, bodyCy, bodyHalfW,
          bodyHalfH, bodyR);
      if (d > 0.2 || d < -1.4) continue;
      final cov = (0.5 - (d - 1.4) / 1.6).clamp(0.0, 1.0);
      blend(x, y, 0x8A, 0x62, 0x00, 0.9 * cov);
    }
  }

  // The cabin: narrower than the body and inset from both ends, so the
  // bonnet and boot are visible either side of it. A plan-view car is
  // recognisable mostly by this -- a long body with a shorter, narrower
  // rectangle inside it.
  const cabinHalfW = 12.0;
  box(48, 44, cabinHalfW, 20, 8, 0xE09A00, 1);

  // Glass. The windscreen and the rear window are trapezoids -- narrower at
  // their inner edge -- because a rectangle there reads as a hole rather than
  // as a window, and the taper is the perspective cue that sells the view as
  // being from above.
  _trapezoid(blend, top: 24, bottom: 34, topHalf: 8.5, bottomHalf: 12.0,
      colour: 0x2B3A4A, alpha: 0.95);
  _trapezoid(blend, top: 54, bottom: 63, topHalf: 12.0, bottomHalf: 9.5,
      colour: 0x2B3A4A, alpha: 0.9);
  // Roof, between them, a lighter panel so the cabin has a top.
  box(48, 44, 10.5, 9.0, 5.0, 0xF7BE3A, 1);
  // A highlight along the roof's left side, matching the body's light. Kept
  // narrow and low-contrast: a bright bar down the middle of the roof reads as
  // a stripe painted on the car rather than as a surface turning toward the
  // light.
  box(43.8, 44, 2.2, 7.5, 2.0, 0xFFD066, 0.45);

  // Side glass: thin slivers down each flank of the cabin, which is all that
  // is visible of a door window from directly above.
  for (final x in const [36.5, 59.5]) {
    box(x, 44, 1.4, 7.0, 1.3, 0x2B3A4A, 0.85);
  }

  // Mirrors. Small nubs at the cabin's widest point, on stalks. Barely visible
  // at 58px and worth it anyway: they are the detail that stops the sprite
  // reading as a generic vehicle from above. Drawn past the body line, which
  // is correct -- a mirror does stick out, and it is the only part that does.
  for (final x in const [31.5, 64.5]) {
    box(x, 41, 2.4, 1.3, 1.1, 0xD18F00, 1);
  }

  // Lights. White at the nose, red at the tail, so the front of the car is
  // identifiable from the sprite alone -- which is what lets the nose be drawn
  // as the default orientation rather than left ambiguous.
  for (final x in const [39.0, 57.0]) {
    box(x, 9.5, 3.2, 2.2, 1.6, 0xFFF6DC, 1);
    box(x, 86.5, 3.0, 2.0, 1.5, 0xE5484D, 1);
  }

  return out;
}

/// A trapezoid between two rows, wider at the bottom, antialiased.
///
/// Its own function because the two windows are the only shapes in the sprite
/// that are not a rounded rectangle, and inlining the same eight lines twice
/// would be the sort of duplication that ends up with the two windows a pixel
/// out of line with each other.
void _trapezoid(
  void Function(int x, int y, int r, int g, int b, double a) blend, {
  required int top,
  required int bottom,
  required double topHalf,
  required double bottomHalf,
  required int colour,
  required double alpha,
}) {
  final height = bottom - top;
  for (var y = top; y < bottom; y++) {
    final t = (y - top) / height;
    final half = topHalf + (bottomHalf - topHalf) * t;
    for (var x = (48 - half).floor(); x <= (48 + half).ceil(); x++) {
      final d = ((x + 0.5 - 48).abs() - half);
      final cov = (0.5 - d / 1.0).clamp(0.0, 1.0);
      if (cov <= 0) continue;
      blend(
        x,
        y,
        (colour >> 16) & 0xFF,
        (colour >> 8) & 0xFF,
        colour & 0xFF,
        alpha * cov,
      );
    }
  }
}

/// Wraps raw RGBA in the smallest valid PNG this needs.
///
/// Hand-rolled rather than pulled from a package: it is a few dozen lines, it
/// adds no transitive dependency to a package that both apps link against, and
/// the alternative for one icon is a build step producing a binary.
Uint8List _encodePng(Uint8List rgba, int width) {
  final height = width;
  final out = BytesBuilder();

  out.add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

  final ihdr = BytesBuilder()
    ..add(_be32(width))
    ..add(_be32(height))
    // 8 bits per channel, colour type 6 = truecolour with alpha, deflate, no
    // filter, no interlace.
    ..add([8, 6, 0, 0, 0]);
  _chunk(out, 'IHDR', ihdr.takeBytes());

  // Each scanline is prefixed with its filter type. 0 is None, and zlib does
  // the compressing.
  final raw = BytesBuilder();
  for (var y = 0; y < height; y++) {
    raw.addByte(0);
    final start = y * width * 4;
    raw.add(rgba.sublist(start, start + width * 4));
  }
  _chunk(out, 'IDAT', ZLibCodec(level: 6).encode(raw.takeBytes()));

  _chunk(out, 'IEND', Uint8List(0));
  return out.takeBytes();
}

void _chunk(BytesBuilder out, String type, List<int> data) {
  out.add(_be32(data.length));
  final body = (BytesBuilder()
        ..add(type.codeUnits)
        ..add(data))
      .takeBytes();
  out.add(body);
  // CRC-32 over the type and the data. Flutter ships no crc32 and zlib's is
  // only over the compressed payload, so this is the one piece of arithmetic
  // the format needs and it happens once per chunk.
  out.add(_be32(_crc32(body)));
}

List<int> _be32(int v) => [
      (v >> 24) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 8) & 0xFF,
      v & 0xFF,
    ];

/// CRC-32 as PNG defines it: IEEE polynomial, reflected, seeded with all ones,
/// finished with a final xor.
int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
