/// The six documents a driver has to send.
///
/// Named for what the document *is*, not for the screen it appears on, and
/// stored as the plain text these values are rather than as a Dart-only enum,
/// because the `driver_documents` table's check constraint is the definition and
/// a second list here could drift from it. [driverDocumentKinds] is the one that
/// has to agree with the SQL, and it is tested against the migration.
enum DriverDocumentKind {
  profilePhoto('profilePhoto', 'Profile picture'),
  vehiclePhoto('vehiclePhoto', 'Vehicle photo'),
  ghanaCardPhoto('ghanaCardPhoto', 'Ghana card photo'),
  driversLicence('driversLicence', "Driver's licence photo"),
  roadWorthy('roadWorthy', 'Road worthy certificate'),
  insuranceSticker('insuranceSticker', 'Insurance sticker'),
  livenessFrame('livenessFrame', 'Face check');

  const DriverDocumentKind(this.wire, this.label);

  /// The value written to `driver_documents.kind`.
  final String wire;

  /// What the rider-side checklist calls it.
  final String label;

  /// Whether this is the face check rather than a photograph.
  ///
  /// True only for [livenessFrame], and it is the one kind the checklist does
  /// not take with the camera: a liveness check has to *watch* a face move, so
  /// it runs in this app with a live preview, rather than handing the driver to
  /// the system camera and getting one still back. There is no way to do that
  /// with `ACTION_IMAGE_CAPTURE`.
  bool get isLiveness => this == DriverDocumentKind.livenessFrame;

  /// The one-line instruction under the label.
  ///
  /// Every one of these is a photograph a driver has to go and find or take, and
  /// the single biggest cause of a stalled verification is a photo the wrong side
  /// up or too dark to read. So the instruction says what the photo has to show
  /// rather than repeating the label.
  String get hint => switch (this) {
    DriverDocumentKind.profilePhoto =>
      'Your face, looking at the phone. Well lit.',
    DriverDocumentKind.vehiclePhoto =>
      'The whole vehicle, from the side. The plate must be readable.',
    DriverDocumentKind.ghanaCardPhoto =>
      'The front of the card. All four corners inside the photo.',
    DriverDocumentKind.driversLicence =>
      'Both sides, or two photos if it is a fold-out licence.',
    DriverDocumentKind.roadWorthy =>
      'The certificate, with the expiry date readable.',
    DriverDocumentKind.insuranceSticker =>
      'The sticker on the windscreen, with the number readable.',
    // Not a photograph and not a selfie. A liveness check is the driver
    // doing small things to their face while the phone watches, and the
    // only still that comes out of it is the evidence.
    DriverDocumentKind.livenessFrame =>
      'A short check that your face is a real one, done here in the app. '
          'It asks you to turn your head and smile.',
  };

  static DriverDocumentKind? byWire(String wire) {
    for (final kind in DriverDocumentKind.values) {
      if (kind.wire == wire) return kind;
    }
    return null;
  }
}

/// Every kind, in the order the checklist shows them.
///
/// The order is the order a driver has to fetch or do them, which is not
/// alphabetical and not the order the table happens to use: the two easy ones
/// (a face, a vehicle) first so the list does not open with paperwork, and the
/// face check last because it is the only one that needs good light and a
/// steady hand, so it is done once the driver has got everything else ready.
const List<DriverDocumentKind> driverDocumentKinds = [
  DriverDocumentKind.profilePhoto,
  DriverDocumentKind.vehiclePhoto,
  DriverDocumentKind.ghanaCardPhoto,
  DriverDocumentKind.driversLicence,
  DriverDocumentKind.roadWorthy,
  DriverDocumentKind.insuranceSticker,
  DriverDocumentKind.livenessFrame,
];

/// The six kinds that are photographs.
///
/// [driverDocumentKinds] has seven. The count in the app's own tests and in the
/// admin page has to be about the photographs, and a list that was six until
/// the face check was added and is seven now is a number that has to be
/// updated in three places every time it changes. Naming the split once here
/// is the cheaper shape.
const List<DriverDocumentKind> driverPhotoKinds = [
  DriverDocumentKind.profilePhoto,
  DriverDocumentKind.vehiclePhoto,
  DriverDocumentKind.ghanaCardPhoto,
  DriverDocumentKind.driversLicence,
  DriverDocumentKind.roadWorthy,
  DriverDocumentKind.insuranceSticker,
];

/// One document a driver has sent, as the server holds it.
class DriverDocument {
  const DriverDocument({
    required this.kind,
    required this.path,
    required this.createdAt,
  });

  final DriverDocumentKind kind;

  /// The storage object path, not a URL.
  ///
  /// Deliberately not resolved into a URL here. The bucket is private, so a URL
  /// would need a signed token, and a token baked into a model is a credential
  /// in a data class. The screen asks for the image when it draws the row.
  final String path;

  final DateTime createdAt;

  static DriverDocument? fromJson(Map<String, dynamic> json) {
    final kind = DriverDocumentKind.byWire(json['kind'] as String? ?? '');
    if (kind == null) return null;
    final path = json['path'];
    if (path is! String || path.isEmpty) return null;
    return DriverDocument(
      kind: kind,
      path: path,
      createdAt:
          DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}
