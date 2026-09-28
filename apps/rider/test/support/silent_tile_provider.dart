import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

/// A [TileProvider] that draws nothing and asks the network for nothing.
///
/// `flutter_map`'s default provider issues an HTTP request per visible tile.
/// Under `flutter test` the test binding's `HttpOverrides` answers every one
/// of them with a 400, so each map test spends seconds printing one
/// `ClientException` per tile and asserting nothing about the map. This
/// provider answers from a 1x1 transparent PNG that
/// [TileProvider.transparentImage] already carries, which settles the same
/// frame in one pump and leaves the test free to assert on the layers, the
/// pins and the camera instead of on the transport.
class SilentTileProvider extends TileProvider {
  /// How many tiles were asked for. A map that mounted and never asked for a
  /// tile did not lay out, so this is a real assertion target and not a
  /// diagnostic leftover.
  int requested = 0;

  @override
  MemoryImage getImage(TileCoordinates coordinates, TileLayer options) {
    requested++;
    return MemoryImage(kBlankTileBytes);
  }
}

final Uint8List kBlankTileBytes = TileProvider.transparentImage;
