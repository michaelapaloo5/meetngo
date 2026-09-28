import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// The one place the app touches the camera.
///
/// A widget test must never reach a platform view, so [DocumentScanner] is the
/// seam: [ScannerStub] answers a fixed path and the app uses
/// [ImagePickerScanner]. Nothing in this app reads the bytes a capture
/// produced -- see `SupabaseDriverRepository.submitSelfie` for why.
abstract class DocumentScanner {
  /// A path on this device, or null when the driver cancelled.
  Future<String?> capture();
}

class ImagePickerScanner implements DocumentScanner {
  ImagePickerScanner([ImagePicker? picker]) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<String?> capture() async {
    final file = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 80,
    );
    return file?.path;
  }
}

class ScannerStub implements DocumentScanner {
  ScannerStub(this.path);
  final String? path;

  @override
  Future<String?> capture() async => path;
}

/// The button both capture steps use.
class CaptureButton extends StatelessWidget {
  const CaptureButton({
    super.key,
    required this.label,
    required this.scanner,
    required this.onCaptured,
  });

  final String label;
  final DocumentScanner scanner;
  final void Function(String path) onCaptured;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () async {
        final path = await scanner.capture();
        if (path != null) onCaptured(path);
      },
      icon: const Icon(Icons.photo_camera, size: 18),
      label: Text(label),
    );
  }
}
