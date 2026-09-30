import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'kyc_controller.dart';

/// Reads the text off a Ghana Card photograph.
///
/// ## Why this is an interface
///
/// Because the alternative is a widget test that reaches a platform channel and
/// hangs, which is the same trap `LivenessScreen` fell into: `availableCameras()`
/// never resolves in a test binding, the spinner never settles, and
/// `pumpAndSettle` times out. This seam is the same one
/// `document_scanner_stub.dart` established for the camera, and for the same
/// reason -- [CardReaderStub] answers a fixture and every test that does not
/// care about OCR is unaffected by whether ML Kit works.
///
/// ## Why a failure must not block a driver
///
/// This is a third-party native plugin, and this project has already had a
/// Google ML Kit plugin fail on the test phone in the worst possible way:
/// `google_mlkit_face_detection`'s `FaceDetector.processImage` threw a
/// NullPointerException out of Google's own runtime on every frame, which made a
/// *required* check of onboarding impossible to pass for anybody.
///
/// Text recognition is a different API, but the lesson is not about which API --
/// it is that a plugin failure must never be the reason a driver cannot hand in
/// a licence photo. So [read] never throws: it returns null on any failure, the
/// button reports it, and the seven fields underneath stay editable. Every field
/// this fills can be typed by hand, which is what makes the whole feature
/// optional rather than load-bearing.
///
/// ## What it costs
///
/// Nothing per card, and nothing leaves the phone. ML Kit's Latin text model is
/// bundled into the APK rather than downloaded, and `processImage` is a local
/// call. The cost is APK size -- a few megabytes, on an APK that is already
/// 133 MB -- and the maintenance position in the plugin's own words, which are
/// "as-is, not sponsored by Google".
abstract class CardReader {
  /// The text on the card at [imagePath], or null when it could not be read.
  ///
  /// Null covers a cancelled capture, a plugin that would not start, and a
  /// photograph with no text on it. The caller cannot tell them apart and does
  /// not need to: all three mean "the driver will type it".
  Future<String?> read(String imagePath);
}

/// The real one, on-device.
class MlKitCardReader implements CardReader {
  MlKitCardReader([TextRecognizer? recognizer])
      : _recognizer = recognizer ?? TextRecognizer(script: TextRecognitionScript.latin);

  final TextRecognizer _recognizer;

  @override
  Future<String?> read(String imagePath) async {
    try {
      final recognised = await _recognizer.processImage(
        InputImage.fromFilePath(imagePath),
      );
      final text = recognised.text.trim();
      return text.isEmpty ? null : text;
    } on Object catch (e) {
      // Deliberately swallowed, and the reason is written down above: a driver
      // with a working camera and a broken plugin still has seven text fields,
      // and a stack trace is not something to put in front of them on a phone in
      // a car park. The failure is logged where a developer will find it and
      // nowhere a driver will.
      debugPrint('card reader failed: $e');
      return null;
    }
  }

  void dispose() => _recognizer.close();
}

/// Answers a fixture. Never touches a platform channel.
class CardReaderStub implements CardReader {
  CardReaderStub(this.text);

  /// What [read] returns. Null models a reader that could not see the card.
  final String? text;

  /// Every path it was asked about, so a test can assert the button read the
  /// photograph the driver had just taken.
  final List<String> asked = <String>[];

  @override
  Future<String?> read(String imagePath) async {
    asked.add(imagePath);
    return text;
  }
}

/// Takes a photograph and reads it, and reports what happened.
///
/// Split out from the card step so the sequence -- capture, read, parse -- is one
/// testable unit and the screen holds no logic. [onText] is not called at all
/// when nothing could be read, which is what lets the screen leave the driver's
/// typed values alone.
Future<void> readCardFromCamera({
  required CardReader reader,
  required Future<String?> Function() capture,
  required KycController controller,
  required void Function(String message) onMessage,
  // `VoidCallback` and not `Future<void> Function()`: this is a spinner, and a
  // caller writing `() => setState(() {})` would be returning void from a
  // function declared to return a Future, which the analyzer refuses.
  VoidCallback? onRead,
}) async {
  final path = await capture();
  if (path == null) return; // The driver cancelled the camera.

  onRead?.call();
  final text = await reader.read(path);
  if (text == null || text.trim().isEmpty) {
    onMessage(
      'Could not read the card. Fill the fields in below, and check them '
      'against your photograph.',
    );
    return;
  }

  controller.applyScan(text);
  // Only said when the parse found nothing, because "read it but could not make
  // sense of it" is a different problem from "read it".
  if (controller.cardNumber == null || controller.cardNumber!.isEmpty) {
    onMessage('Read the card, but could not find the card number on it.');
    return;
  }
  onMessage('Card read. Check every field against your card before continuing.');
}

/// True when [path] is a file this process can read.
///
/// Not a general existence check: `File.exists` on an Android content URI or a
/// path in a scoped-storage directory is true while the bytes are unreadable, and
/// ML Kit's failure mode for that is an exception rather than empty text. Read
/// one byte first so a permission problem is reported as a message.
Future<bool> isReadableImageFile(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) return false;
    // Read a byte and close it, rather than opening and closing an empty
    // handle: opening is lazy, so a path that exists but cannot be read passes
    // this check and then fails inside ML Kit instead.
    final handle = await file.open(mode: FileMode.read);
    await handle.readByte();
    await handle.close();
    return true;
  } on Object {
    return false;
  }
}
