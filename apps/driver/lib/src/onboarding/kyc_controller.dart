import 'package:flutter/foundation.dart';
import 'package:mng_core/mng_core.dart';

import '../data/driver_repository.dart';
import 'driver_document.dart';

/// The steps of driver onboarding, in the order the driver walks them.
///
/// `underReview` is not in the plan's list and is the reason [submit] cannot
/// land on `approved` by itself. `submitGhanaCard` writes `kyc_status =
/// 'pending'` -- `guard_profile_update` raises on any other value, so `pending`
/// is the only one a client can write -- and an admin moves it to `approved`
/// through the service role. A controller that reported "You are verified" from
/// its own `submit()` would be telling a driver they can drive when the row
/// says they cannot.
/// The steps of driver onboarding, in the order the driver walks them.
///
/// `documents` is first on purpose. A driver who has just signed up has not
/// thought about a road worthy certificate, and a flow that asks for it at the
/// sixth step means they have already driven to the depot for it -- or, more
/// likely for a pilot, that they never find out and the verification quietly
/// stalls with nobody able to say why. The list first is a packing list.
///
/// `underReview` is not in the plan's list and is the reason [submit] cannot
/// land on `approved` by itself. `submitGhanaCard` writes `kyc_status =
/// 'pending'` -- `guard_profile_update` raises on any other value, so `pending`
/// is the only one a client can write -- and an admin moves it to `approved`
/// through the service role. A controller that reported "You are verified" from
/// its own `submit()` would be telling a driver they can drive when the row
/// says they cannot.
enum KycStep {
  documents,
  identity,
  ghanaCard,
  selfie,
  vehicle,
  review,
  underReview,
  approved,
}

class CardParseResult {
  const CardParseResult({
    this.cardNumber,
    this.expiry,
    this.name,
    this.dob,
    this.sex,
    this.nationality,
    this.issued,
    this.error,
  });
  final String? cardNumber;
  final String? expiry;
  final String? name;
  final String? error;

  /// The rest of the card's front.
  ///
  /// All nullable and all read on a best-effort basis -- see [GhanaCardParser] for
  /// why a field that cannot be read confidently comes back null rather than as a
  /// guess. Null means "the card reader could not see this", which is different
  /// from "this is blank on the card", and [KycController.applyScan] keeps
  /// whatever the driver had already typed when it is null.
  final String? dob;
  final String? sex;
  final String? nationality;
  final String? issued;
}

/// Reads a Ghana Card out of the text a card reader produced.
///
/// ## Labelled first, positional second
///
/// A Ghana Card's front is a printed form, so its fields have labels: `Name:`,
/// `Date of Birth:`, `Sex:`, `Nationality:`, `ID Number:`, `Issue Date:`,
/// `Date of Expiry:`. A reader usually keeps those labels, and where it does they
/// are worth more than anything else in the output. Every field is therefore
/// looked for by its label first.
///
/// Where a label is missing only two positional fallbacks are used, and both
/// rest on the card's physical layout rather than on a guess: the **first**
/// four-digit-year date is the date of birth and the **last** is the expiry,
/// because on the card the date of birth is in the upper block and the issue and
/// expiry dates are at the bottom.
///
/// Nothing else is guessed. A field that cannot be read confidently comes back
/// null and the driver types it, because this output goes to an employee who
/// compares it against a photograph to decide whether to let somebody take
/// paying passengers. A plausible wrong date of birth is worse than a blank one.
///
/// ## The bug this replaces
///
/// The previous version took the first `(\d{2})\s*/\s*(\d{2})` in the text as the
/// expiry. A date of birth printed `14/03/1994` *contains* `14/03`, so that regex
/// returned the driver's date of birth as the expiry -- and the field is prefilled
/// and looks right, so nobody would have noticed. Tightening the regex cannot fix
/// it, because `11/31` and `14/03` are the same shape; only the label and the
/// position distinguish them, which is why both are used now.
///
/// ## No camera in here
///
/// Nothing in this class runs a camera. It takes text something else produced, so
/// it is testable without a device and without a model, and a card reader that is
/// wrong can be swapped for a better one without touching this.
class GhanaCardParser {
  /// `GHA-284719305-4`, tolerating spaces a reader may insert.
  static final _cardNumber = RegExp(r'GHA-\s?\d{9}\s?-\s?\d');
  static final _name = RegExp(r'^([A-Z][A-Z ]+)$');

  /// A full `dd/mm/yyyy`, `dd-mm-yyyy` or `dd.mm.yyyy`.
  ///
  /// The trailing `\b` matters: without it `14/03/94` matches the first three
  /// groups of `14/03/1994` and yields a date in 1919, which is an age of 107.
  static final _date = RegExp(
    r'\b(\d{1,2})\s*[/\-.]\s*(\d{1,2})\s*[/\-.]\s*(\d{4})\b',
  );

  /// The label each field answers to.
  ///
  /// `final`, not `const`: `RegExp`'s const constructor takes a pattern only, and
  /// every one of these needs `caseSensitive: false`.
  static final _labels = <String, RegExp>{
    'dob': RegExp(
      r'\b(?:DATE\s*OF\s*BIRTH|D\.?O\.?B\.?)\b',
      caseSensitive: false,
    ),
    'issued': RegExp(
      r'\b(?:DATE\s*OF\s*ISSUE|ISSUE\s*DATE)\b',
      caseSensitive: false,
    ),
    'expiry': RegExp(
      r'\b(?:DATE\s*OF\s*EXPIRY|EXPIRY\s*DATE|EXPIRES?)\b',
      caseSensitive: false,
    ),
    'sex': RegExp(r'\b(?:SEX|GENDER)\b', caseSensitive: false),
    'nationality': RegExp(r'\bNATIONALITY\b', caseSensitive: false),
  };

  /// Lines that are all capitals and are not the name.
  ///
  /// The header of a Ghana Card is `REPUBLIC OF GHANA` in capitals, and it is
  /// the first all-capitals line in the scan. A first-match name regex
  /// therefore returns `REPUBLIC OF GHANA` for every card ever scanned, which is
  /// a name field the driver has to correct by hand and never has to -- because
  /// the field is prefilled and looks right.
  static const _notNames = <String>{
    'REPUBLIC OF GHANA',
    'GHANA',
    'REPUBLIC',
    'EXP',
    'EXPIRY',
    'DATE OF EXPIRY',
    'NAME',
    'GHANA CARD',
    'NATIONALITY',
    'SEX',
    'GENDER',
    'DATE OF BIRTH',
    'DOB',
    'ISSUE DATE',
    'DATE OF ISSUE',
    'ID NUMBER',
    'CARD NUMBER',
    'HEIGHT',
  };

  static CardParseResult parse({required String rawText}) {
    if (rawText.trim().isEmpty) {
      return const CardParseResult(error: 'Scan was blank, try again');
    }
    final number = _cardNumber.firstMatch(rawText);
    if (number == null) {
      return const CardParseResult(error: 'Could not read the card number');
    }

    final labelled = _labelledValues(rawText);
    final dates = _allDates(rawText);

    // The expiry is the one field that is still required. Without it the card has
    // not really been read, and the driver should be told so rather than handed a
    // form that is missing the first thing an employee looks for.
    //
    // Three ways to find it, in order of how much they can be trusted: its
    // label; a line that is *only* a month and a year, which is the shape the
    // card prints and the shape a four-digit-year date cannot be; and failing
    // both, the last full date in the text.
    //
    // The middle one is not optional. A Ghana Card's expiry is printed `11/31`,
    // with no day, so on a card whose labels did not survive it is not a
    // `dd/mm/yyyy` at all and the date scan never sees it -- which is how the
    // first version of the positional fallback returned the *issue* date as the
    // expiry and looked entirely plausible.
    // The third fallback -- the last full date -- only applies when there are at
    // least two. A card with one date in it and no label for the expiry is far
    // more likely to be a card whose date of birth came out and whose expiry did
    // not than a card that genuinely has only an expiry, and turning a date of
    // birth into `14/94` is the exact mistake this parser spent its life
    // avoiding. Refusing leaves the field blank, which the driver fills in.
    final expiryRaw =
        labelled['expiry'] ??
        _bareMonthYearLine(rawText) ??
        (dates.length > 1 ? _asMonthYear(dates, last: true) : null);
    if (expiryRaw == null) {
      return const CardParseResult(error: 'Could not read the expiry date');
    }
    final expiryDate = parseGhanaCardExpiry(expiryRaw);
    if (expiryDate == null) {
      return const CardParseResult(error: 'Expiry date is not a real date');
    }
    final rest = _withoutExpiry(
      dates,
      expiryRaw,
      fromLabel: labelled['expiry'] != null,
    );
    // A labelled date is normalised through the same reader as an unlabelled
    // one, so `Date of Birth: 14 / 03 / 1994` is stored as `14/03/1994` rather
    // than with whatever spaces the card reader happened to produce. That value
    // goes into the database and in front of an employee comparing it with a
    // photograph, and it is also what `ageFromGhanaCardDate` has to make sense
    // of. Falls back to the raw text when it is not a full date, so an unusual
    // but readable value is kept rather than dropped.
    final dob =
        _asDayMonthYear(labelled['dob'] ?? '') ??
        labelled['dob'] ??
        (rest.isNotEmpty ? _asDayMonthYear(rest.first) : null);
    final issued =
        _asDayMonthYear(labelled['issued'] ?? '') ??
        labelled['issued'] ??
        (rest.length > 1 ? _asDayMonthYear(rest[rest.length - 1]) : null);

    return CardParseResult(
      cardNumber: _squash(number.group(0)!),
      expiry: _monthYear(expiryDate),
      name: _nameOf(rawText),
      dob: dob,
      sex: labelled['sex'] ?? _sexOf(rawText),
      nationality: labelled['nationality'] ?? _nationalityOf(rawText),
      issued: issued,
    );
  }

  /// Every `dd/mm/yyyy` in the text, in the order they appear.
  static List<String> _allDates(String rawText) =>
      _date.allMatches(rawText).map((m) => m.group(0)!).toList(growable: false);

  /// [dates] with [expiryRaw] taken out of it, if it was one of them.
  ///
  /// Compared on **month and year only**, deliberately. A full date of
  /// `11/31/2031` is day 11 of month 31, which is not a date, so
  /// `parseGhanaCardDate` returns null for it and it survives this filter -- and
  /// then gets reported as the date of issue, which is a field the driver did
  /// have a value for. An expiry carries a month and a year and no day, so the
  /// comparison carries the same two and nothing else.
  static List<String> _withoutExpiry(
    List<String> dates,
    String expiryRaw, {
    bool fromLabel = false,
  }) {
    if (fromLabel) return dates;
    final wanted = parseGhanaCardExpiry(expiryRaw);
    if (wanted == null) return dates;
    final out = <String>[];
    for (final d in dates) {
      final parts = _monthAndYear(d);
      if (parts != null &&
          parts.$1 == wanted.month &&
          parts.$2 == wanted.year) {
        continue;
      }
      out.add(d);
    }
    return out;
  }

  /// The month and year of a date on a card, in either shape.
  ///
  /// `14/03/1994` gives (3, 1994) and `11/31/2031` gives (31, 2031) -- the
  /// second is not a real date and the month is deliberately not range-checked
  /// here, because the point of this function is to identify a string, not to
  /// decide whether it is one. Returns null when the shape is neither.
  static (int, int)? _monthAndYear(String raw) {
    final m = _date.firstMatch(raw);
    if (m != null) return (int.parse(m.group(2)!), int.parse(m.group(3)!));
    final my = RegExp(r'^(\d{1,2})\s*[/\-.]\s*(\d{2,4})$')
        .firstMatch(raw.trim());
    if (my == null) return null;
    var year = int.parse(my.group(2)!);
    if (year < 100) year += year <= 30 ? 2000 : 1900;
    return (int.parse(my.group(1)!), year);
  }

  /// The last `mm/yy` in the text that is not part of a longer date.
  ///
  /// Both assertions are the whole trick, and both were got wrong once.
  ///
  /// The **lookahead** says "only if nothing date-like follows", which rejects
  /// the `14/03` inside `14/03/1994`. Without it this returns the driver's date
  /// of birth as the expiry -- which is what the very first version of this
  /// parser did, on every card, silently, with the wrong value prefilled and
  /// looking right.
  ///
  /// The **lookbehind** rejects the other half of the same trap. `\b` holds
  /// between a slash and a digit, so in `14/03/1994` the engine happily matched
  /// `03/1994` -- month 3, "year" 1994 -- and reported the date of birth as an
  /// expiry wearing a different hat. A `\b` is not a boundary against a slash.
  ///
  /// Not anchored to the whole line, because an expiry is often printed after a
  /// short label -- `EXP 04/29`, `Expiry 04/29` -- and the label was never the
  /// problem. Last, because the expiry is at the bottom of the card and the issue
  /// date is above it.
  ///
  /// An impossible month is *not* skipped here. `31/31` is a real expiry
  /// somebody tried to read, and dropping it silently would turn a specific "that
  /// is not a real date" into a vague "we could not read it" --
  /// [parseGhanaCardExpiry] is the thing that knows the difference.
  static String? _bareMonthYearLine(String rawText) {
    final pattern = RegExp(
      r'(?<![\d/])(\d{1,2})\s*[/\-.]\s*(\d{2,4})(?!\s*[/\-.]\s*\d)',
    );
    String? found;
    for (final m in pattern.allMatches(rawText)) {
      found = '${m.group(1)}/${m.group(2)}';
    }
    return found;
  }

  /// The first or last of [dates] as `mm/yy`, for an expiry.
  ///
  /// Group **two**, not group one. These are `dd/mm/yyyy` dates -- group 1 is the
  /// day and group 2 is the month -- and an expiry is a month over a year. Reading
  /// `11/31/2031` as `11/2031` takes the *day* as the month, which happens to
  /// work for a card whose expiry is on the 11th and silently produces a card
  /// expiring in November 1931 for everybody else.
  static String? _asMonthYear(List<String> dates, {required bool last}) {
    if (dates.isEmpty) return null;
    final m = _date.firstMatch(last ? dates.last : dates.first);
    if (m == null) return null;
    final year = m.group(3)!.length == 4
        ? m.group(3)!.substring(2)
        : m.group(3)!;
    return '${m.group(2)}/$year';
  }

  /// A full date as `dd/mm/yyyy`.
  static String? _asDayMonthYear(String raw) {
    final m = _date.firstMatch(raw);
    if (m == null) return null;
    return '${m.group(1)}/${m.group(2)}/${m.group(3)}';
  }

  /// Values sitting after their label, on the same line or the next one.
  ///
  /// A reader often puts the labels in one column and the values in another, so
  /// both are tried. The next-line value is only taken when that line is not
  /// itself a label, or a two-column card would pair every label with the label
  /// beneath it.
  static Map<String, String> _labelledValues(String rawText) {
    final lines = rawText
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList(growable: false);
    final found = <String, String>{};

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      for (final entry in _labels.entries) {
        if (found.containsKey(entry.key)) continue;
        if (!entry.value.hasMatch(line)) continue;
        final after = line
            .replaceFirst(entry.value, '')
            .replaceAll(RegExp(r'[:\-–—]'), ' ')
            .trim();
        if (_isValue(after)) {
          found[entry.key] = after;
          continue;
        }
        if (i + 1 < lines.length && !_isLabelLine(lines[i + 1])) {
          found[entry.key] = lines[i + 1];
        }
      }
    }
    return found;
  }

  static bool _isLabelLine(String line) =>
      _labels.values.any((r) => r.hasMatch(line)) || _cardNumber.hasMatch(line);

  /// Whether a fragment is a value rather than more of a label.
  static bool _isValue(String text) {
    if (text.isEmpty) return false;
    if (_isLabelLine(text)) return false;
    // A bare one- or two-digit number is not a value for any of these fields,
    // and `1` after `SEX` is a read failure rather than an answer.
    if (RegExp(r'^\W*\d{1,2}\W*$').hasMatch(text)) return false;
    return true;
  }

  static String? _sexOf(String rawText) {
    final m = RegExp(
      r'\b(?:SEX|GENDER)\b\s*[:\-–—]?\s*([MF])\b',
      caseSensitive: false,
    ).firstMatch(rawText);
    if (m != null) return m.group(1)!.toUpperCase();
    // Some cards print only `M` or `F` on a line of its own.
    for (final line in rawText.split('\n')) {
      final t = line.trim();
      if (t == 'M' || t == 'F' || t == 'MALE' || t == 'FEMALE') {
        return t[0].toUpperCase();
      }
    }
    return null;
  }

  static String? _nationalityOf(String rawText) {
    final m = RegExp(r'\bNATIONALITY\b\s*[:\-–—]?\s*([A-Za-z ]+)')
        .firstMatch(rawText);
    final value = m?.group(1)?.trim();
    if (value != null && value.isNotEmpty) return value;
    // Every Ghanaian carries `GHANAIAN` somewhere on the card, and on a Ghana
    // Card it is the only nationality word the document contains.
    if (rawText.toUpperCase().contains('GHANAIAN')) return 'Ghanaian';
    return null;
  }

  static String _squash(String text) => text.replaceAll(RegExp(r'\s'), '');

  /// `31/01/2031` and `11/31` both become `11/31` -- month over year, as
  /// printed. [expiry] has already been parsed, so this is a format and not a
  /// judgement.
  static String _monthYear(DateTime expiry) {
    final year = expiry.year % 100;
    return '${expiry.month.toString().padLeft(2, '0')}/'
        '${year.toString().padLeft(2, '0')}';
  }

  static String? _nameOf(String rawText) {
    // A labelled name first: `Name: APPAH MENSAH` is unambiguous, and the
    // all-capitals heuristic is only a fallback for a reader that dropped it.
    final labelled = RegExp(
      r'\bNAME\b\s*[:\-–—]\s*([A-Z][A-Z ]+)\s*$',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(rawText);
    if (labelled != null) {
      final v = labelled.group(1)!.trim();
      if (v.isNotEmpty && !_notNames.contains(v.toUpperCase())) return v;
    }
    for (final line in rawText.split('\n')) {
      final candidate = line.trim();
      if (candidate.isEmpty) continue;
      if (_cardNumber.hasMatch(candidate)) continue;
      if (_notNames.contains(candidate.toUpperCase())) continue;
      if (_labels.values.any((r) => r.hasMatch(candidate))) continue;
      if (_date.hasMatch(candidate)) continue;
      final match = _name.firstMatch(candidate);
      if (match != null) return match.group(1)!.trim();
    }
    return null;
  }
}

/// The KYC flow, as state a screen can read and a test can drive.
///
/// Every field is a notifying setter. The plan's version had them as plain
/// public fields, and the screen's `onChanged: (v) => c.fullName = v` then
/// mutated one with no `notifyListeners`, so the "Continue" button below it --
/// which reads `canAdvance` -- stayed disabled for the whole time the driver
/// was typing their name. Nothing on the screen was wrong; the button simply
/// never woke up.
class KycController extends ChangeNotifier {
  KycController(this._repo);

  final DriverRepository _repo;

  KycStep _step = KycStep.documents;
  KycStep get step => _step;
  set step(KycStep value) {
    if (_step == value) return;
    _step = value;
    notifyListeners();
  }

  /// The documents the server already holds, so the checklist survives a restart.
  List<DriverDocument> _documents = const [];
  List<DriverDocument> get documents => _documents;

  /// Records a document the driver has just sent.
  void recordDocument(DriverDocument document) {
    _documents = [
      ..._documents.where((d) => d.kind != document.kind),
      document,
    ];
    notifyListeners();
  }

  /// Uploads one document and records it, so the checklist ticks.
  ///
  /// On the controller rather than in the screen, because the row has to be
  /// marked sent from the same object the checklist reads and because the
  /// upload is a thing that can fail, and a failure has to leave the row
  /// unticked. The screen owns only the error message.
  Future<void> uploadDocument({
    required DriverDocumentKind kind,
    required String filePath,
  }) async {
    await _repo.uploadDocument(kind: kind, filePath: filePath);
    recordDocument(
      DriverDocument(
        kind: kind,
        // The controller does not know the storage path the repository chose,
        // and does not need to: nothing in the app reads it back, and inventing
        // one here would put a path in the app that the server never issued.
        path: filePath,
        createdAt: DateTime.now(),
      ),
    );
  }

  /// The liveness check, and whether it has been done.
  ///
  /// Not local, and not fake. See `_LivenessRow` in `document_checklist.dart`:
  /// liveness and a face match against the licence are bought from a provider,
  /// and this app does not claim otherwise. [livenessProvider] is the name, or
  /// null when none is configured, and null is what the checklist reads as "not
  /// connected yet" rather than as a pass.
  static const String? livenessProvider = null;

  bool get livenessComplete => livenessProvider != null;

  String? error;
  bool busy = false;

  String? _fullName;
  String? get fullName => _fullName;
  set fullName(String? value) {
    _fullName = value;
    notifyListeners();
  }

  /// The driver's own phone number, in Ghana's 0XX format.
  ///
  /// Collected at sign-up because three things depend on it and none of them can
  /// work without it: the rider has no way to call the driver, the driver has no
  /// way to call the rider, and neither side can be reached when a trip goes
  /// wrong. The column has existed since the first migration with a default of
  /// `''` and nothing ever wrote to it, so a rider tapping "call driver" had
  /// nothing to call.
  ///
  /// Normalised rather than stored as typed. Ghanaian numbers are written
  /// `024 123 4567`, `+233 24 123 4567` and `0024 123 4567` by three different
  /// people who all mean the same one, and a number that is compared for
  /// equality after being typed two different ways is a number that does not
  /// match. What is stored is `0241234567` or `233241234567`; anything that does
  /// not reduce to one of those is refused here rather than written.
  String? _phone;
  String? get phone => _phone;
  set phone(String? value) {
    _phone = value;
    notifyListeners();
  }

  /// What is written to the database, or null when what was typed is not a
  /// Ghanaian number yet.
  ///
  /// Normalised on the way out rather than on the way in, and the distinction
  /// matters. Normalising in the setter threw away what the driver typed: a
  /// driver part way through `024 123 4567` has typed something that does not
  /// normalise, so the setter stored null, and the field's own error text --
  /// which asks "is what I typed too short?" -- had nothing left to ask about.
  /// Three tests failed on exactly that: the gate would not open for a number
  /// that was correct, and the message said "enter your number" to a driver who
  /// had already entered one.
  ///
  /// So [phone] keeps what was typed, this answers what would be stored, and the
  /// repository normalises again on the way in because it is the only writer of
  /// the column and the rule has to hold for every caller.
  String? get phoneNormalised => normaliseGhanaPhone(_phone);

  /// The digits of what would be stored, for the call affordance.
  String get phoneDigits => phoneNormalised ?? '';

  /// Whether the phone is present and is a real Ghanaian number.
  bool get phoneComplete => phoneNormalised != null;

  /// Why the phone is not acceptable, or null when it is. The screen shows this
  /// rather than silently refusing to advance, because a driver who cannot move
  /// past a field with no explanation concludes the app is broken.
  ///
  /// Read against [phone], the text as typed, and never against the normalised
  /// value: a part-typed number normalises to null and every message here would
  /// then say "enter your number" rather than saying which part is wrong.
  String? get phoneProblem {
    final typed = (_phone ?? '').trim();
    if (typed.isEmpty) return 'Enter the number a rider would use to reach you';
    if (phoneComplete) return null;
    final digitCount = typed.replaceAll(RegExp(r'[^0-9]'), '').length;
    if (digitCount < 9) {
      return 'That looks too short. Enter 10 digits, e.g. 0241234567';
    }
    // Ten digits, and still refused: the prefix is not one Ghana issues. The
    // message says so rather than repeating "enter 10 digits" to a driver who
    // has just typed ten of them.
    if (digitCount == 10) {
      return 'That does not start like a Ghanaian number. It should begin 020, 024, 050, 055 or 059.';
    }
    return 'Enter 10 digits, e.g. 0241234567';
  }

  String? _cardNumber;
  String? get cardNumber => _cardNumber;
  set cardNumber(String? value) {
    _cardNumber = value;
    notifyListeners();
  }

  String? _cardExpiry;
  String? get cardExpiry => _cardExpiry;
  set cardExpiry(String? value) {
    _cardExpiry = value;
    notifyListeners();
  }

  String? _cardName;
  String? get cardName => _cardName;
  set cardName(String? value) {
    _cardName = value;
    notifyListeners();
  }

  // The rest of the card, all nullable and all optional in the same way the
  // three above are: a driver who typed only a name and a number in an older
  // build must still be able to move on, and the review screen says "not given"
  // rather than refusing to be reached.
  //
  // Nullable rather than `''` so that "the driver has not entered this" and
  // "the driver entered an empty string" stay the same thing, which is what the
  // write does anyway -- it trims and stores whatever it is given.
  String? _cardDob;
  String? get cardDob => _cardDob;
  set cardDob(String? value) {
    _cardDob = value;
    notifyListeners();
  }

  String? _cardSex;
  String? get cardSex => _cardSex;
  set cardSex(String? value) {
    _cardSex = value;
    notifyListeners();
  }

  String? _cardNationality;
  String? get cardNationality => _cardNationality;
  set cardNationality(String? value) {
    _cardNationality = value;
    notifyListeners();
  }

  String? _cardIssued;
  String? get cardIssued => _cardIssued;
  set cardIssued(String? value) {
    _cardIssued = value;
    notifyListeners();
  }

  /// The driver's age, from [cardDob], or null when it cannot be read.
  ///
  /// Delegates to [ageFromGhanaCardDate] so there is one parser rather than two
  /// between this app and the model. Computed rather than stored: a stored age
  /// is a second answer to a question that changes on its own.
  int? get cardAge => cardDob == null ? null : ageFromGhanaCardDate(cardDob!);

  String? _selfiePath;
  String? get selfiePath => _selfiePath;
  set selfiePath(String? value) {
    _selfiePath = value;
    notifyListeners();
  }

  String? _vehicleMake;
  String? get vehicleMake => _vehicleMake;
  set vehicleMake(String? value) {
    _vehicleMake = value;
    notifyListeners();
  }

  String? _vehicleModel;
  String? get vehicleModel => _vehicleModel;
  set vehicleModel(String? value) {
    _vehicleModel = value;
    notifyListeners();
  }

  String? _vehiclePlate;
  String? get vehiclePlate => _vehiclePlate;
  set vehiclePlate(String? value) {
    _vehiclePlate = value;
    notifyListeners();
  }

  int _vehicleSeats = 4;
  int get vehicleSeats => _vehicleSeats;
  set vehicleSeats(int value) {
    _vehicleSeats = value;
    notifyListeners();
  }

  RideCategory _vehicleCategory = RideCategory.standard;
  RideCategory get vehicleCategory => _vehicleCategory;
  set vehicleCategory(RideCategory value) {
    _vehicleCategory = value;
    notifyListeners();
  }

  /// How many of the required documents this driver has sent.
  ///
  /// Counted from the list rather than from [_documents].length, because the
  /// two are not the same once anything optional exists: a driver who did the
  /// face check and skipped a licence photo has six documents on file and is
  /// missing one of the things an admin actually reviews. Counting the list
  /// would let that driver submit, and the gate would look like it was working.
  int get _requiredSent => driverRequiredKinds
      .where((kind) => _documents.any((d) => d.kind == kind))
      .length;

  bool get canAdvance => switch (step) {
    // Every required document, because this is the step that exists to collect
    // them. `continue` is disabled until each one is in, which is what stops a
    // driver reaching the review step with three of six and finding out at the
    // far end.
    KycStep.documents => _requiredSent >= driverRequiredKinds.length,
    // Name **and** a phone that is a real Ghanaian number. Both, and both here,
    // rather than the phone being collected later or being optional: a driver
    // with a name and six documents and no phone is a driver a rider cannot
    // call when the pickup goes wrong, and discovering that at 2am at a junction
    // in Osu is the worst possible time.
    //
    // `phoneComplete` rather than "is not empty" so that a driver who has typed
    // seven digits cannot advance on a number that will not dial.
    KycStep.identity =>
      (_fullName ?? '').trim().length >= 3 && phoneComplete,
    KycStep.ghanaCard =>
      (_cardNumber ?? '').isNotEmpty && (_cardExpiry ?? '').isNotEmpty,
    KycStep.selfie => (_selfiePath ?? '').isNotEmpty,
    KycStep.vehicle =>
      (_vehicleMake ?? '').isNotEmpty &&
          (_vehicleModel ?? '').isNotEmpty &&
          (_vehiclePlate ?? '').isNotEmpty &&
          _vehicleSeats >= 1 &&
          _vehicleSeats <= 8,
    KycStep.review || KycStep.underReview || KycStep.approved => false,
  };

  /// Fills the card fields from scan text, or sets [error] and changes nothing.
  ///
  /// Only fills what was actually read. A field the scan could not find keeps
  /// whatever the driver had already typed, because a card reader that returns
  /// null for a field is saying "I could not read that", not "that is blank" --
  /// and blanking a field the driver filled in by hand, because the camera did
  /// badly on one line of eight, is the kind of thing that loses a whole
  /// submission.
  void applyScan(String rawText) {
    error = null;
    final parsed = GhanaCardParser.parse(rawText: rawText);
    if (parsed.error != null) {
      error = parsed.error;
      notifyListeners();
      return;
    }
    _cardNumber = parsed.cardNumber;
    _cardExpiry = parsed.expiry;
    _cardName = parsed.name ?? _cardName;
    _cardDob = parsed.dob ?? _cardDob;
    _cardSex = parsed.sex ?? _cardSex;
    _cardNationality = parsed.nationality ?? _cardNationality;
    _cardIssued = parsed.issued ?? _cardIssued;
    notifyListeners();
  }

  /// Walks one step forward, writing whatever that step owns to the server.
  ///
  /// Each step writes as it is left, not at the end, so a driver who loses
  /// their connection on the vehicle step keeps the card they already sent.
  ///
  /// Every case ends in a `break` for readability, not because it has to: under
  /// Dart 3 a `switch` statement case that completes normally simply leaves the
  /// switch, and a probe over this exact shape confirms one case runs per call.
  /// (An earlier note in this file claimed the plan's breakless version was a
  /// compile error. It is not -- `dart analyze` accepts it and the tests below
  /// pass against it.)
  Future<void> advance() async {
    if (!canAdvance) return;
    error = null;
    busy = true;
    notifyListeners();
    try {
      switch (step) {
        case KycStep.documents:
          step = KycStep.identity;
          break;
        case KycStep.identity:
          step = KycStep.ghanaCard;
          break;
        case KycStep.ghanaCard:
          await _repo.submitGhanaCard(
            cardNumber: _cardNumber!,
            expiry: _cardExpiry!,
            fullName: _cardName ?? _fullName ?? '',
            dob: _cardDob ?? '',
            sex: _cardSex ?? '',
            nationality: _cardNationality ?? '',
            issued: _cardIssued ?? '',
            // Written with the identity details rather than as a separate call.
            // It is part of the same row, it is part of the same `pending`
            // write, and a driver who has a name and a card number but no phone
            // is a driver neither the rider nor the platform can reach -- so
            // there is no state in which one is written and the other is not.
            //
            // The normalised form, not the raw field. `phoneComplete` has already
            // gated this call, so a null here is unreachable in practice, and an
            // empty string is the honest value for it if it ever is.
            phone: phoneNormalised ?? '',
          );
          step = KycStep.selfie;
          break;
        case KycStep.selfie:
          await _repo.submitSelfie(_selfiePath!);
          step = KycStep.vehicle;
          break;
        case KycStep.vehicle:
          await _repo.saveVehicle(
            make: _vehicleMake!,
            model: _vehicleModel!,
            plate: _vehiclePlate!,
            seats: _vehicleSeats,
            rideCategory: _vehicleCategory,
          );
          step = KycStep.review;
          break;
        case KycStep.review:
        case KycStep.underReview:
        case KycStep.approved:
          return;
      }
    } on DriverAuthFailure catch (e) {
      error = e.message;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void back() {
    if (step == KycStep.approved || step == KycStep.underReview) return;
    final order = KycStep.values.indexOf(step);
    if (order == 0) return;
    step = KycStep.values[order - 1];
    error = null;
  }

  /// Hands the finished application over and reads the server's answer.
  ///
  /// It writes nothing, and that is the change from the plan. By the time the
  /// driver reaches `review` the card, the selfie and the vehicle are all
  /// already on the server -- [advance] sent each of them on the way past --
  /// so the plan's version uploaded the same selfie a second time and wrote the
  /// same vehicle row a second time on every submit. What is left to do is the
  /// only part that was never done: ask whether the driver is approved yet.
  Future<void> submit() async {
    if (step != KycStep.review) return;
    // The six documents are what an admin actually reviews, so submitting
    // without them would put a stranger's application in front of a human who
    // has nothing to look at and a button that says approve. Refused here
    // rather than in `canAdvance`, because the button being live and then
    // doing nothing is worse than it being dead -- and the driver is walked
    // back to the list rather than left staring at a review of a car.
    final sentRequired = driverRequiredKinds
        .where((kind) => documents.any((d) => d.kind == kind))
        .length;
    if (sentRequired < driverRequiredKinds.length) {
      step = KycStep.documents;
      error = 'Send your documents before submitting for review';
      return;
    }
    error = null;
    busy = true;
    notifyListeners();
    try {
      final profile = await _repo.me();
      step = (profile?.isApproved ?? false)
          ? KycStep.approved
          : KycStep.underReview;
    } on DriverAuthFailure catch (e) {
      error = e.message;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Re-reads the server's answer after an admin has looked at the application.
  Future<void> checkStatus() async {
    if (step != KycStep.underReview) return;
    error = null;
    busy = true;
    notifyListeners();
    try {
      final profile = await _repo.me();
      if (profile?.isApproved ?? false) {
        step = KycStep.approved;
      } else if (profile == null) {
        error = 'This account has no driver profile yet';
      }
    } on DriverAuthFailure catch (e) {
      error = e.message;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Works out how far through onboarding this driver already is, and resumes
  /// there instead of starting again.
  ///
  /// Found on a device: force-closing the driver app mid-onboarding sent the
  /// driver back to the identity step, and every step they had already
  /// completed looked as though it had not been. [advance] writes each step to
  /// the server on the way past, precisely so that a driver who loses their
  /// connection does not have to re-enter what has already been accepted -- and
  /// then the app threw that away on the next launch and started from
  /// `KycStep.identity` regardless of what the server said.
  ///
  /// So the step is *reconstructed* from the server rather than remembered
  /// locally. That is the only copy that matters: a local cache of it would be
  /// a second answer to a question the database already answers, and the two
  /// would disagree the moment a driver onboarded on one device and reopened on
  /// another. No new storage, and nothing to migrate.
  ///
  /// What this cannot bring back is the text typed into the *current* step and
  /// not yet submitted, and a selfie taken but not yet sent. Both are written
  /// only when that step is left, so until then they exist in one place: the
  /// screen in front of the driver. That is a real cost and it is the price of
  /// not keeping a second copy of the driver's identity documents on the phone.
  ///
  /// A read that fails changes nothing: the driver lands on the first step,
  /// which is where they would have been anyway, rather than on an error.
  Future<void> resumeFromServer() async {
    final DriverProfile? profile;
    try {
      profile = await _repo.me();
    } on Object {
      // A driver who cannot be read is on the first step, which is where they
      // would have been anyway. Nothing to say about it.
      return;
    }

    // The repair, before anything reads the role.
    //
    // `handle_new_user` reads the role from signup metadata once, so an account
    // made before the driver app sent `role: 'driver'` -- or by somebody who
    // installed the rider app first -- is a rider forever. The approval queue
    // filters on `role = 'driver'` as well as on `kyc_status`, so such a driver
    // appears in the app as "Waiting for review" and in no queue at all, and
    // nothing on either screen says why.
    //
    // Claiming it here rather than at signup is what makes the signup fix cover
    // accounts that already existed, and the database permits exactly this one
    // transition. It grants nothing: `kyc_status = 'approved'` and
    // `vehicles.approved` are both service-role writes, so the worst this can do
    // is put somebody in the queue, which is where they need to be.
    if (profile != null && !profile.isDriver) {
      try {
        await _repo.claimDriverRole();
      } on Object {
        // Swallowed on purpose. If the claim fails the driver can still upload
        // every document and an employee can still see them, and a driver stuck
        // behind an error dialog is a worse outcome than one who has to ask why
        // they are not in the queue.
      }
    }

    // The vehicle read is separate on purpose. A driver whose profile is
    // readable has at least sent their card, so the flow can continue past the
    // card step even when the vehicle read is refused -- and refusing to
    // continue would send a driver who had already sent a card, a selfie and a
    // vehicle back to typing their name. A failed vehicle read is read as "no
    // vehicle", which lands on a step that can be completed rather than on one
    // that assumes something exists.
    Vehicle? vehicle;
    if (profile?.vehicleId != null) {
      try {
        vehicle = await _repo.myVehicle();
      } on Object {
        vehicle = null;
      }
    }

    // Read before the step is decided, because the step now depends on it: a
    // driver with four of the six documents is sent to the list, not to a
    // review they cannot complete. A failed read is read as "none sent", which
    // is the safe direction -- it costs a driver one screen of re-sending and
    // costs nothing an unapproved driver's safety.
    var documents = const <DriverDocument>[];
    try {
      documents = await _repo.myDocuments();
    } on Object {
      documents = const [];
    }

    final restored = _stepFor(profile, vehicle, documents);
    if (restored == null) return;
    // Full name and selfie come back with the profile, so the review step can
    // show what was actually submitted rather than empty fields.
    final name = profile?.fullName.trim() ?? '';
    if (name.isNotEmpty) _fullName = name;
    if (profile?.photoUrl.isNotEmpty ?? false) _selfiePath = profile!.photoUrl;
    // The Ghana Card, the same reason and the same way. `cardName` was only ever
    // held in memory, so a driver who quit on the review screen came back to it
    // showing their *profile* name where the name on the card should be -- and
    // the employee reads that row against the card photograph, so those are not
    // interchangeable and the substitution was quietly wrong.
    //
    // Restored only when the server has something, so a driver who has not
    // reached the card step keeps whatever they had typed rather than having it
    // replaced by an empty string from a row that simply has no card in it yet.
    if (profile != null) {
      if (profile.cardNumber.isNotEmpty) _cardNumber = profile.cardNumber;
      if (profile.cardDob.isNotEmpty) _cardDob = profile.cardDob;
      if (profile.cardSex.isNotEmpty) _cardSex = profile.cardSex;
      if (profile.cardNationality.isNotEmpty) {
        _cardNationality = profile.cardNationality;
      }
      if (profile.cardIssued.isNotEmpty) _cardIssued = profile.cardIssued;
      if (profile.cardExpiry.isNotEmpty) _cardExpiry = profile.cardExpiry;
      // The card name is not a column of its own: the identity step asks for the
      // name *on the card* and writes it to `full_name`, so that is where it
      // comes back from.
      if (name.isNotEmpty) _cardName = name;
    }
    if (vehicle != null) {
      _vehicleMake = vehicle.make;
      _vehicleModel = vehicle.model;
      _vehiclePlate = vehicle.plate;
      _vehicleSeats = vehicle.seats;
      _vehicleCategory = vehicle.rideCategory;
    }
    // Set from the read above rather than re-read, so the list the checklist
    // draws is the same list the step was decided on. Two reads could disagree
    // and produce a screen showing four documents on a step that was chosen
    // for six.
    _documents = documents;
    _step = restored;
    notifyListeners();
  }

  /// Which step the server's state corresponds to, or null to leave it alone.
  ///
  /// Null means "carry on from wherever this controller already is", which is
  /// what a driver who is midway through and simply re-opened the app needs.
  static KycStep? _stepFor(
    DriverProfile? profile,
    Vehicle? vehicle,
    List<DriverDocument> documents,
  ) {
    if (profile == null) return null;
    if (profile.isApproved) return KycStep.approved;

    // The six documents outrank every other step for anyone not yet approved,
    // including a driver who has already submitted a Ghana Card and a vehicle.
    //
    // This is the gap that a fresh signup never sees: a driver who signed up
    // before the documents existed is sitting at `review` with a car and no
    // licence photo, and would reach an admin holding nothing to approve. So
    // the resume is driven by what is actually missing rather than by how far
    // through the old flow they got, and a driver who has four of the six is
    // sent to the list to fetch the other two rather than to a review they
    // cannot complete.
    final sentRequired = driverRequiredKinds
        .where((kind) => documents.any((d) => d.kind == kind))
        .length;
    if (sentRequired < driverRequiredKinds.length) {
      return KycStep.documents;
    }

    return switch (profile.kyc) {
      // The Ghana Card went in, which is the step that writes `pending`. What
      // came after it is decided by what else exists.
      //
      // `underReview`, not `review`, once the vehicle is saved. This was `review`,
      // and it was wrong in a way that lost work: `submit()` writes nothing to
      // the server. It checks the six documents are present, re-reads the profile
      // and sets this controller's step -- nothing more. The server has said
      // `pending` since the Ghana Card step, which is *before* the selfie and the
      // vehicle, so a driver with all six documents and a vehicle is already in
      // the admin's queue whether or not they ever pressed the button.
      //
      // So "has everything" and "has submitted" are the same fact, and only one
      // of them is on the server. Resuming to `review` therefore said "Submit for
      // review" to a driver who had already done it, on every single app launch,
      // forever: `underReview` was only ever set in memory by `submit()`, so no
      // restart could ever reach it. The symptom was a driver who had finished
      // being told they had not finished.
      //
      // The cost of this is that a driver who quits on the review screen without
      // pressing submit is told "Sent for review" when they did not press it. That
      // is accurate in every way that matters -- an employee can see them, read
      // their documents and approve them -- because the button had no server-side
      // effect to miss.
      KycStatus.pending =>
        vehicle != null ? KycStep.underReview : KycStep.selfie,
      // A rejection sends the driver back to the beginning on purpose: the
      // card is the document that was refused, so re-entering the name and
      // scanning a new card is the honest retry rather than carrying on past
      // a refused identity check. The document list is not reset with it --
      // their licence and road worthy certificate are still valid, and asking
      // for those again is the kind of thing that makes a driver give up.
      KycStatus.rejected => KycStep.identity,
      KycStatus.notStarted => KycStep.documents,
      KycStatus.approved => KycStep.approved,
    };
  }
}
