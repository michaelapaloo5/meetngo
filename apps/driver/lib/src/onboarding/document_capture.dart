import 'dart:io';

import 'package:image_picker/image_picker.dart';

import 'document_checklist.dart';

/// Takes a document photo with the camera.
///
/// Behind [DocumentCapture] so the checklist has no plugin in it and a test can
/// drive captured, cancelled and refused without a camera. The same reason the
/// card and selfie steps already take a scanner.
///
/// The camera source, not the gallery, and that is a decision rather than a
/// default. A document photographed from the camera is dated by when it was
/// taken, which is the first thing an admin checks when a licence looks too
/// old; one chosen from a gallery can be a photo of a photo, from last year, of
/// a licence that has since been revoked. Allowing the gallery would make the
/// upload trivially faked, and there is no server-side check on any of this.
class CameraDocumentCapture implements DocumentCapture {
  CameraDocumentCapture([ImagePicker? picker])
    : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<String?> capture() async {
    final shot = await _picker.pickImage(
      source: ImageSource.camera,
      // Bounded rather than left to the sensor: a 12-megapixel photo of a
      // credit card is 4MB of a driver's upload allowance spent on detail no
      // one reads, and the bucket rejects anything over 10MB, so a driver
      // photographing in 48MP mode on a modern phone would hit an error they
      // cannot explain. 1600px is still far more than a licence needs.
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 85,
    );
    // Null for a back-out, and for a camera the device refused to open. Both
    // are the driver's row staying unticked with no message, which is right:
    // nothing went wrong that they did something about.
    if (shot == null) return null;

    // A path that is not a readable file is refused here, for the same reason
    // `submitSelfie` does it -- so a driver is never told a photo was taken when
    // the file is not there for the upload to find.
    if (!File(shot.path).existsSync()) return null;
    return shot.path;
  }
}
