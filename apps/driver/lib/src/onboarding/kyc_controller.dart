import 'package:flutter/foundation.dart';
import 'package:mng_core/mng_core.dart';

import '../data/driver_repository.dart';

/// The steps of driver onboarding, in the order the driver walks them.
///
/// `underReview` is not in the plan's list and is the reason [submit] cannot
/// land on `approved` by itself. `submitGhanaCard` writes `kyc_status =
/// 'pending'` -- `guard_profile_update` raises on any other value, so `pending`
/// is the only one a client can write -- and an admin moves it to `approved`
/// through the service role. A controller that reported "You are verified" from
/// its own `submit()` would be telling a driver they can drive when the row
/// says they cannot.
enum KycStep { identity, ghanaCard, selfie, vehicle, review, underReview, approved }

class CardParseResult {
  const CardParseResult({this.cardNumber, this.expiry, this.name, this.error});
  final String? cardNumber;
  final String? expiry;
  final String? name;
  final String? error;
}

/// Reads the three things a Ghana Card scan carries.
///
/// There is no OCR engine in this build, so nothing calls [parse] from the
/// camera path: the app has a seam for a capture and no way to turn a picture
/// into text. What the parser gives the driver is the other half -- a
/// handwriting- and paste-proof way to fill the three fields in from whatever
/// text a scan produces, and the only place the shape of a Ghana Card number
/// and expiry is written down.
class GhanaCardParser {
  static final _cardNumber = RegExp(r'GHA-\d{9}-\d');
  static final _expiry = RegExp(r'(\d{2})\s*/\s*(\d{2})');
  static final _name = RegExp(r'^([A-Z][A-Z ]+)$');

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
  };

  static CardParseResult parse({required String rawText}) {
    if (rawText.trim().isEmpty) {
      return const CardParseResult(error: 'Scan was blank, try again');
    }
    final number = _cardNumber.firstMatch(rawText);
    if (number == null) {
      return const CardParseResult(error: 'Could not read the card number');
    }
    final expiry = _expiry.firstMatch(rawText);
    if (expiry == null) {
      return const CardParseResult(
        error: 'Could not read the expiry date',
      );
    }
    final month = int.parse(expiry.group(1)!);
    if (month < 1 || month > 12) {
      return const CardParseResult(error: 'Expiry month is not valid');
    }
    return CardParseResult(
      cardNumber: number.group(0),
      expiry: '${expiry.group(1)}/${expiry.group(2)}',
      name: _nameOf(rawText),
    );
  }

  static String? _nameOf(String rawText) {
    for (final line in rawText.split('\n')) {
      final candidate = line.trim();
      if (candidate.isEmpty) continue;
      if (_cardNumber.hasMatch(candidate)) continue;
      if (_notNames.contains(candidate.toUpperCase())) continue;
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

  KycStep _step = KycStep.identity;
  KycStep get step => _step;
  set step(KycStep value) {
    if (_step == value) return;
    _step = value;
    notifyListeners();
  }

  String? error;
  bool busy = false;

  String? _fullName;
  String? get fullName => _fullName;
  set fullName(String? value) {
    _fullName = value;
    notifyListeners();
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

  bool get canAdvance => switch (step) {
        KycStep.identity => (_fullName ?? '').trim().length >= 3,
        KycStep.ghanaCard =>
          (_cardNumber ?? '').isNotEmpty && (_cardExpiry ?? '').isNotEmpty,
        KycStep.selfie => (_selfiePath ?? '').isNotEmpty,
        KycStep.vehicle =>
          (_vehicleMake ?? '').isNotEmpty &&
              (_vehicleModel ?? '').isNotEmpty &&
              (_vehiclePlate ?? '').isNotEmpty &&
              _vehicleSeats >= 1 &&
              _vehicleSeats <= 8,
        KycStep.review ||
        KycStep.underReview ||
        KycStep.approved =>
          false,
      };

  /// Fills the card fields from scan text, or sets [error] and changes nothing.
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
        case KycStep.identity:
          step = KycStep.ghanaCard;
          break;
        case KycStep.ghanaCard:
          await _repo.submitGhanaCard(
            cardNumber: _cardNumber!,
            expiry: _cardExpiry!,
            fullName: _cardName ?? _fullName ?? '',
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
}
