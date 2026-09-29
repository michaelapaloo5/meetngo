// Renders the car sprite and a few rotations of it to a PNG strip, so the
// artwork can actually be looked at rather than only asserted about.
//
// Not part of the suite: run deliberately with
//   flutter test test/preview_car_sprite.dart
// It writes to the system temp directory and asserts nothing.
import 'dart:io';
import 'dart:math' show cos, sin;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';

void main() {
  test('write a contact sheet', () {
    const s = kCarTopdownSize;
    const scale = 2;
    const gap = 12;
    // Left: the sprite as drawn. Then the same pixels at four rotations, which
    // is what the style's icon-rotate does to it, so the nose is visible
    // pointing each way.
    const rotations = [0, 45, 90, 135, 180, 270];
    final tiles = 1 + rotations.length;
    final tileW = s * scale;
    final width = tiles * tileW + (tiles - 1) * gap;
    final height = tileW;
    final canvas = Uint8List(width * height * 4);
    // A mid-gray backdrop, so a transparent edge is visible as a checkered
    // edge rather than disappearing into the review pane's background.
    for (var i = 0; i < canvas.length; i += 4) {
      canvas[i] = 0x60;
      canvas[i + 1] = 0x60;
      canvas[i + 2] = 0x60;
      canvas[i + 3] = 0xFF;
    }

    void blit(int tile, Uint8List src, double radians) {
      final originX = tile * (tileW + gap);
      final c = s / 2.0;
      final cosA = cos(radians);
      final sinA = sin(radians);
      // Supersampled 3x3 so the rotation does not alias into mush at 2x.
      for (var py = 0; py < tileW; py++) {
        for (var pxi = 0; pxi < tileW; pxi++) {
          var r = 0, g = 0, b = 0, a = 0, n = 0;
          for (var sy = 0; sy < 3; sy++) {
            for (var sx = 0; sx < 3; sx++) {
              final dx = pxi + sx / 3.0 - c * scale;
              final dy = py + sy / 3.0 - c * scale;
              // Inverse-rotate into sprite space, so the sprite turns.
              final ux = (dx * cosA + dy * sinA) / scale + c;
              final uy = (-dx * sinA + dy * cosA) / scale + c;
              final x = ux.floor();
              final y = uy.floor();
              if (x < 0 || y < 0 || x >= s || y >= s) continue;
              final i = (y * s + x) * 4;
              if (src[i + 3] == 0) continue;
              final sa = src[i + 3] / 255.0;
              r += (src[i] * sa).round();
              g += (src[i + 1] * sa).round();
              b += (src[i + 2] * sa).round();
              a += src[i + 3];
              n++;
            }
          }
          if (n == 0) continue;
          final o = (py * width + originX + pxi) * 4;
          final af = a / n / 255.0;
          canvas[o] = (canvas[o] * (1 - af) + (r / n) * af).round();
          canvas[o + 1] =
              (canvas[o + 1] * (1 - af) + (g / n) * af).round();
          canvas[o + 2] =
              (canvas[o + 2] * (1 - af) + (b / n) * af).round();
        }
      }
    }

    blit(0, carTopdownPixels(), 0);
    for (var i = 0; i < rotations.length; i++) {
      blit(i + 1, carTopdownPixels(), rotations[i] * 3.14159265 / 180.0);
    }

    // Reuse the package's own encoder: it is the one under test, and a second
    // encoder here would be a second thing that can be wrong.
    final png = _encode(canvas, width, height);
    final out = File(
      '${Directory.systemTemp.path}\\meetngo_car_sprite_preview.png',
    );
    out.writeAsBytesSync(png);
    // ignore: avoid_print
    print('wrote ${out.path} (${width}x$height)');
  });
}

/// A minimal PNG writer, so this file does not depend on a private helper.
Uint8List _encode(Uint8List rgba, int width, int height) {
  final out = BytesBuilder();
  out.add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  final ihdr = BytesBuilder()
    ..add(_be32(width))
    ..add(_be32(height))
    ..add([8, 6, 0, 0, 0]);
  _chunk(out, 'IHDR', ihdr.takeBytes());
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
  out.add(_be32(_crc32(body)));
}

List<int> _be32(int v) => [
      (v >> 24) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 8) & 0xFF,
      v & 0xFF,
    ];

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
