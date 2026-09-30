import 'geo_point.dart';

enum DriverAvailability { offline, online, onTrip }

enum KycStatus { notStarted, pending, approved, rejected }

class DriverProfile {
  const DriverProfile({
    required this.id,
    this.role = 'rider',
    required this.fullName,
    required this.phone,
    required this.rating,
    required this.tripCount,
    required this.kyc,
    required this.availability,
    this.photoUrl = '',
    this.vehicleId,
    this.location,
    this.cardNumber = '',
    this.cardDob = '',
    this.cardSex = '',
    this.cardNationality = '',
    this.cardIssued = '',
    this.cardExpiry = '',
  });

  factory DriverProfile.fromJson(Map<String, dynamic> json) => DriverProfile(
    id: json['id'] as String,
    role: (json['role'] as String?) ?? 'rider',
    fullName: (json['full_name'] as String?) ?? '',
    phone: (json['phone'] as String?) ?? '',
    photoUrl: (json['photo_url'] as String?) ?? '',
    rating: ((json['rating'] as num?) ?? 5.0).toDouble(),
    tripCount: (json['trip_count'] as num?)?.toInt() ?? 0,
    kyc: KycStatus.values.byName(
      (json['kyc_status'] as String?) ?? 'notStarted',
    ),
    availability: DriverAvailability.values.byName(
      (json['availability'] as String?) ?? 'offline',
    ),
    vehicleId: json['vehicle_id'] as String?,
    // Falls back to `ghana_card_last4` for rows written before
    // `20260930000003_ghana_card_fields.sql`, so a driver who submitted on an
    // older build does not show an empty number on the review screen.
    // `last4` holds the *first* four digits -- the app writes
    // `digits.substring(0, 4)` -- and the admin page says so where it shows
    // one, rather than presenting four digits as the whole number.
    cardNumber:
        (json['ghana_card_number'] as String?) ??
        (json['ghana_card_last4'] as String?) ??
        '',
    cardDob: (json['ghana_card_dob'] as String?) ?? '',
    cardSex: (json['ghana_card_sex'] as String?) ?? '',
    cardNationality: (json['ghana_card_nationality'] as String?) ?? '',
    cardIssued: (json['ghana_card_issued'] as String?) ?? '',
    cardExpiry: (json['ghana_card_expiry'] as String?) ?? '',
    location: json['lat'] == null
        ? null
        : GeoPoint(
            (json['lat'] as num).toDouble(),
            (json['lng'] as num).toDouble(),
          ),
  );

  final String id;

  /// `rider` or `driver`, as the server has it.
  ///
  /// Read, never inferred. This was missing until a driver reported that the app
  /// said "Waiting for review" while the approval queue showed nothing: the
  /// queue filters on `role = 'driver'` and the app only ever looked at
  /// `kyc_status`, so a profile stored as a rider said "waiting" forever and
  /// nothing explained why. Without the role on the model the app could not even
  /// know it was in that state, let alone get out of it.
  final String role;

  bool get isDriver => role == 'driver';

  final String fullName;
  final String phone;
  final String photoUrl;
  final double rating;
  final int tripCount;
  final KycStatus kyc;
  final DriverAvailability availability;
  final String? vehicleId;
  final GeoPoint? location;

  // The Ghana Card, as the driver entered it.
  //
  // These are on the profile rather than in the onboarding controller because
  // the review step has to survive a restart. `cardName` in particular was only
  // ever held in memory, so a driver who quit on the review screen came back to
  // a review showing their *profile* name in place of the name on the card --
  // and the employee is checking one against the other, so those are not
  // interchangeable.
  //
  // Empty string, not null, for the same reason as [photoUrl]: a column that is
  // absent and a column that is blank are the same thing to a person reading
  // this, and `null` would need a null check at every call site to say so.
  final String cardNumber;
  final String cardDob;
  final String cardSex;
  final String cardNationality;
  final String cardIssued;
  final String cardExpiry;

  /// The driver's age in whole years, or null when the date cannot be read.
  ///
  /// Computed, never stored. A stored age is a second answer to a question that
  /// changes on its own, and it would have to be updated by something; the date
  /// of birth is the fact and this is arithmetic on it.
  ///
  /// Tolerantly parsed, because the column is `text` (see
  /// `20260930000003_ghana_card_fields.sql`) and holds whatever the driver typed
  /// or the card reader read -- `14/03/1994`, `1994-03-14`, `14.03.94`. A
  /// driver whose date of birth is unreadable gets null and the screen says
  /// "not given", which is true. A wrong age is worse than no age: it is the
  /// number an employee compares against a face.
  int? get age => ageFromGhanaCardDate(cardDob);

  bool get isApproved => kyc == KycStatus.approved;

  bool get canAcceptOffers =>
      isApproved && availability == DriverAvailability.online;

  DriverProfile copyWith({
    DriverAvailability? availability,
    KycStatus? kyc,
    GeoPoint? location,
    String? vehicleId,
    String? role,
  }) => DriverProfile(
    id: id,
    fullName: fullName,
    // `?? this.role`, not a bare `role`: the parameter shadows the field and is
    // nullable, so passing it straight through would hand null to a non-nullable
    // field on every `copyWith` that did not mention the role -- which is most
    // of them.
    role: role ?? this.role,
    phone: phone,
    photoUrl: photoUrl,
    rating: rating,
    tripCount: tripCount,
    kyc: kyc ?? this.kyc,
    availability: availability ?? this.availability,
    vehicleId: vehicleId ?? this.vehicleId,
    location: location ?? this.location,
    cardNumber: cardNumber,
    cardDob: cardDob,
    cardSex: cardSex,
    cardNationality: cardNationality,
    cardIssued: cardIssued,
    cardExpiry: cardExpiry,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role,
    'full_name': fullName,
    'phone': phone,
    'photo_url': photoUrl,
    'rating': rating,
    'trip_count': tripCount,
    'kyc_status': kyc.name,
    'availability': availability.name,
    'vehicle_id': vehicleId,
    if (location != null) 'lat': location!.lat,
    if (location != null) 'lng': location!.lng,
    'ghana_card_number': cardNumber,
    'ghana_card_dob': cardDob,
    'ghana_card_sex': cardSex,
    'ghana_card_nationality': cardNationality,
    'ghana_card_issued': cardIssued,
    'ghana_card_expiry': cardExpiry,
  };
}

/// Whole years from [raw] to today, or null when [raw] is not a readable date.
///
/// A standalone function as well as [DriverProfile.age], because the onboarding
/// controller holds the date of birth as a field before it is ever written to a
/// profile, and building a whole profile to ask it a question about a string is
/// absurd. The parse lives in one place either way.
int? ageFromGhanaCardDate(String raw, {DateTime? asOf}) {
  final parsed = parseGhanaCardDate(raw);
  if (parsed == null) return null;
  final now = asOf ?? DateTime.now();
  var years = now.year - parsed.year;
  final hadBirthday =
      now.month > parsed.month ||
      (now.month == parsed.month && now.day >= parsed.day);
  if (!hadBirthday) years -= 1;
  return years < 0 ? null : years;
}

/// Reads the expiry off a Ghana Card, which is printed as a month and a year.
///
/// Deliberately not [parseGhanaCardDate]. A Ghana Card's expiry is `11/31` --
/// month over year, two digits -- and a day-first parser asked about `11/31` says
/// "the 31st of month 11", which is not a date, and refuses a perfectly good
/// expiry. That is not hypothetical: it is what the first version of the card
/// reader did, and it refused every card it was pointed at.
///
/// Accepts `11/31`, `11/2031`, `11-31`, `11.2031`, and a full `dd/mm/yyyy` of
/// which only the month and year are taken -- a reader that expanded the expiry
/// into three parts has still told us when it runs out.
///
/// Returns the first of that month, so the caller can format it back without
/// inventing a day.
DateTime? parseGhanaCardExpiry(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;

  // A full date first, so `31/01/2031` and `11/31/2031` both work.
  final full = RegExp(r'^(\d{1,2})\s*[/\-.]\s*(\d{1,2})\s*[/\-.]\s*(\d{4})$')
      .firstMatch(text);
  if (full != null)
    return _expiry(int.parse(full.group(2)!), int.parse(full.group(3)!));

  final my = RegExp(r'^(\d{1,2})\s*[/\-.]\s*(\d{2,4})$').firstMatch(text);
  if (my == null) return null;
  final year = int.parse(my.group(2)!);
  // A two-digit expiry year is read as the century that puts it within a
  // plausible window around today, not by the `<= 30 ? 2000 : 1900` rule that a
  // *birth* year uses. That rule sends `11/31` to 1931 -- an expiry that had
  // already lapsed when the card was printed -- and then refuses it, which is
  // what the first version of the card reader did to every card it was shown.
  //
  // The window is deliberately wide at the front and narrow at the back: a card
  // can be shown after it expired, and `99` should read as 1999 rather than
  // 2099. An expiry more than 20 years out is a mistyped year, not a card.
  final now = DateTime.now().year;
  final resolved = year >= 100 ? year : _nearestCentury(year, now);
  return _expiry(int.parse(my.group(1)!), resolved);
}

/// The century for [twoDigit] that lands it in [now] - 10 .. [now] + 20.
int _nearestCentury(int twoDigit, int now) {
  for (var century = 2000; century <= 2100; century += 100) {
    final candidate = century + twoDigit;
    if (candidate >= now - 10 && candidate <= now + 20) return candidate;
  }
  return 2000 + twoDigit;
}

DateTime? _expiry(int month, int year) {
  if (month < 1 || month > 12) return null;
  if (year < 1990 || year > DateTime.now().year + 20) return null;
  return DateTime(year, month, 1);
}

/// Reads a date off a Ghana Card, or null when it is not one.
///
/// The formats, in the order they are tried:
///   * `14/03/1994`, `14-03-1994`, `14.03.1994` -- day first, as printed
///   * `1994-03-14` -- ISO, which is what a card reader sometimes produces
///   * `14/03/94` and `14/03/24` -- two-digit years, which become 1994 and 2024
///
/// Day-first is tried before month-first deliberately. Only the first component
/// is ambiguous between them, and on a Ghana Card it is the day; a driver born
/// on the 3rd of November would be read as 3 November by neither guess, but a
/// driver born on the 11th of March would be read as 11 March by both, so the
/// order only matters for a driver born on a day of the month that is also a
/// valid month. There is no way to tell those apart without asking, and the
/// driver is looking at the card while they are typing it.
///
/// A two-digit year is read as 20xx when it is 30 or below and 19xx otherwise,
/// which is the same rule the whole industry uses and is right for every driver
/// who could hold a licence.
DateTime? parseGhanaCardDate(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;

  // ISO first, because `1994-03-14` is unambiguous and would otherwise be read
  // as day 1994, which is not a date.
  final iso = RegExp(r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})$').firstMatch(text);
  if (iso != null) {
    return _date(
      int.parse(iso.group(1)!),
      int.parse(iso.group(2)!),
      int.parse(iso.group(3)!),
    );
  }

  final dmy = RegExp(r'^(\d{1,2})[-/.](\d{1,2})[-/.](\d{2,4})$')
      .firstMatch(text);
  if (dmy == null) return null;
  final day = int.parse(dmy.group(1)!);
  final month = int.parse(dmy.group(2)!);
  var year = int.parse(dmy.group(3)!);
  if (year < 100) year += year <= 30 ? 2000 : 1900;
  return _date(year, month, day);
}

/// Null rather than a rolled-over date, so `31/02/1994` is rejected instead of
/// becoming the 3rd of March and being shown to an employee as a fact.
DateTime? _date(int year, int month, int day) {
  if (year < 1900 || year > DateTime.now().year + 1) return null;
  if (month < 1 || month > 12) return null;
  if (day < 1 || day > 31) return null;
  final d = DateTime(year, month, day);
  // DateTime rolls 31 February into 3 March, so compare the parts back.
  if (d.year != year || d.month != month || d.day != day) return null;
  return d;
}
