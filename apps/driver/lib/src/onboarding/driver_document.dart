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
  insuranceSticker('insuranceSticker', 'Insurance sticker');

  const DriverDocumentKind(this.wire, this.label);

  /// The value written to `driver_documents.kind`.
  final String wire;

  /// What the rider-side checklist calls it.
  final String label;

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
/// The order is the order a driver has to fetch them, which is not alphabetical
/// and not the order the table happens to use: the two easy ones (a face, a
/// vehicle) first so the list does not open with paperwork.
const List<DriverDocumentKind> driverDocumentKinds = [
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
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}
