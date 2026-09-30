import 'dart:async';

import 'package:flutter/services.dart';

import 'face_reading.dart';

/// Talks to [LivenessChannel] on the Android side.
///
/// This replaces `google_mlkit_face_detection` entirely. That plugin is a thin
/// marshaller over the same native API, and its marshalling throws a
/// NullPointerException out of Google's runtime on every frame -- reproduced
/// here on a release build on a Samsung A06 with two plugin versions, two input
/// paths, and a demonstrably correct frame. So the marshalling is thirty lines
/// of our own now, and there is no plugin in the path.
///
/// Deliberately small. It turns a `List<Map>` into a [FaceReading] and nothing
/// else: all of the decision-making is in `LivenessVerifier`, which is plain
/// Dart and has thirty tests, and none of it can see this file.
class LivenessDetector {
  LivenessDetector({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('gh.meetngo.meetngo_driver/liveness');

  final MethodChannel _channel;

  /// Whether a reading succeeded. False means no face, not an error.
  ///
  /// A separate flag from the throwing path because "there is nobody there" is
  /// an ordinary thing for a camera to report and "the detector is broken" is
  /// not, and the driver is told a different thing about each.
  Future<FaceReading> detect(String path, {required DateTime at}) async {
    final raw = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'detect',
      {'path': path},
    );
    return _toReading(raw, at);
  }

  /// Releases the native detector.
  ///
  /// Called on the way out of the check. The detector holds native memory, and
  /// a driver opening the face check three times in a row would otherwise leak
  /// three of them.
  Future<void> close() async {
    try {
      await _channel.invokeMethod<void>('close');
    } on PlatformException {
      // Closing something already closed is not a failure worth showing a
      // driver, and the next check builds a fresh detector anyway.
    } on MissingPluginException {
      // The channel only exists on Android. On any other platform the check is
      // unreachable in the first place, and reaching here means it was reached.
    }
  }

  /// The platform error, turned into a sentence a driver can act on.
  ///
  /// The `PlatformException.code` is the whole of the diagnosis and it is ours
  /// -- the native side sets them. `detect_threw` in particular means the fault
  /// is in ML Kit rather than in anything this app can change, and a driver
  /// needs to be told to come back later rather than to keep trying.
  static String messageFor(PlatformException e) => switch (e.code) {
    'no_file' => 'The camera could not be read. Try again.',
    'input_image' || 'detect_threw' =>
      'The face check is not working on this phone right now. Please try '
          'again later.',
    _ => 'The camera could not be read. Try again.',
  };

  FaceReading _toReading(List<Map<Object?, Object?>>? raw, DateTime at) {
    if (raw == null || raw.isEmpty) return FaceReading.noFace(at);

    // The largest face, not the first. The verifier fails the check outright on
    // more than one face, so this only decides what the few samples before the
    // count trips report -- and the nearest face is the least surprising thing
    // to report for those.
    final faces = raw.map(_face).toList()
      ..sort((a, b) => b.area.compareTo(a.area));
    final f = faces.first;

    return FaceReading(
      at: at,
      faceCount: raw.length,
      // Every one of these is a nullable double on purpose. The native side
      // sends absent rather than zero, because a zero yaw is a head that is
      // demonstrably facing forwards and a missing one is nothing measured --
      // and the verifier refuses to pass a head turn on the second.
      yaw: f.yaw,
      pitch: f.pitch,
      roll: f.roll,
      leftEyeOpen: f.leftEyeOpen,
      rightEyeOpen: f.rightEyeOpen,
      smile: f.smile,
      contourPoints: f.contourPoints,
    );
  }

  _Face _face(Map<Object?, Object?> map) {
    double? d(String key) {
      final v = map[key];
      if (v is num) return v.toDouble();
      return null;
    }

    int i(String key) {
      final v = map[key];
      if (v is num) return v.toInt();
      return 0;
    }

    return _Face(
      yaw: d('yaw'),
      pitch: d('pitch'),
      roll: d('roll'),
      leftEyeOpen: d('leftEyeOpen'),
      rightEyeOpen: d('rightEyeOpen'),
      smile: d('smile'),
      contourPoints: i('contourPoints'),
      area: d('width')! * d('height')!,
    );
  }
}

class _Face {
  const _Face({
    required this.yaw,
    required this.pitch,
    required this.roll,
    required this.leftEyeOpen,
    required this.rightEyeOpen,
    required this.smile,
    required this.contourPoints,
    required this.area,
  });

  final double? yaw;
  final double? pitch;
  final double? roll;
  final double? leftEyeOpen;
  final double? rightEyeOpen;
  final double? smile;
  final int contourPoints;
  final double area;
}
