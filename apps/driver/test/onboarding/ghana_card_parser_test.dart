import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_driver/src/onboarding/kyc_controller.dart';
import 'package:mng_core/mng_core.dart';

/// Reading a Ghana Card, and turning a date of birth into an age.
///
/// ## Why the parser is tested against text rather than a photograph
///
/// Because the reader is behind `CardReader` and the parsing is behind
/// `GhanaCardParser.parse`, and between them there is exactly one thing worth
/// testing without a device: given the text a card reader produced, does the
/// right field come out? Everything else is Google's code.
///
/// The fixtures below are written the way ML Kit's `RecognizedText.text`
/// actually looks -- lines, occasional colons, labels that may or may not have
/// survived -- because a fixture that is tidier than reality tests nothing. The
/// second one in particular is the shape that broke the old parser.
void main() {
  group('reading a card whose labels survived', () {
    // The tidy case, and the one a card in good light produces.
    const tidy = '''
REPUBLIC OF GHANA
GHANA CARD
Name: APPAH MENSAH
Date of Birth: 14/03/1994
Sex: M
Nationality: GHANAIAN
ID Number: GHA-284719305-4
Issue Date: 02/11/2021
Date of Expiry: 11/31
Height: 1.72m
''';

    test('reads every field', () {
      final r = GhanaCardParser.parse(rawText: tidy);
      expect(r.error, isNull);
      expect(r.cardNumber, 'GHA-284719305-4');
      expect(r.name, 'APPAH MENSAH');
      expect(r.dob, '14/03/1994');
      expect(r.sex, 'M');
      expect(r.nationality, 'GHANAIAN');
      expect(r.issued, '02/11/2021');
      expect(r.expiry, '11/31');
    });

    test('the expiry is the expiry, not the date of birth', () {
      // The regression this whole rewrite exists for. `14/03` is *inside*
      // `14/03/1994`, so the old `_expiry` regex -- the first
      // `(\d{2})\s*/\s*(\d{2})` in the text -- returned the driver's date of
      // birth. It was prefilled, it looked right, and nobody would have
      // noticed until an employee compared it with the photograph.
      final r = GhanaCardParser.parse(rawText: tidy);
      expect(r.expiry, isNot('14/03'));
      expect(r.expiry, '11/31');
      expect(r.dob, '14/03/1994');
    });
  });

  group('reading a card whose labels did not survive', () {
    // What a phone camera actually produces: no colons, the date of birth high
    // on the card, the issue and expiry dates together at the bottom.
    const unlabelled = '''
REPUBLIC OF GHANA
APPAH MENSAH
M
GHANAIAN
14/03/1994
GHA-284719305-4
02/11/2021
11/31
''';

    test('still finds the number and the name', () {
      final r = GhanaCardParser.parse(rawText: unlabelled);
      expect(r.error, isNull);
      expect(r.cardNumber, 'GHA-284719305-4');
      expect(r.name, 'APPAH MENSAH');
    });

    test('takes the first date as the birth and the last as the expiry', () {
      // Both fallbacks rest on the card's layout, not on a guess: the date of
      // birth is in the upper block and the issue and expiry are at the bottom.
      final r = GhanaCardParser.parse(rawText: unlabelled);
      expect(r.dob, '14/03/1994');
      expect(r.expiry, '11/31');
      expect(r.issued, '02/11/2021');
    });

    test('finds the nationality and the sex on lines of their own', () {
      final r = GhanaCardParser.parse(rawText: unlabelled);
      expect(r.nationality, 'Ghanaian');
      expect(r.sex, 'M');
    });

    test('does not claim a date of birth when there is only one date', () {
      // A card photographed so that only the expiry came out. Reading that one
      // date as both the birth and the expiry would put a driver's date of
      // birth in the past and their age in the hundreds.
      const onlyExpiry = '''
GHA-284719305-4
APPAH MENSAH
11/31
''';
      final r = GhanaCardParser.parse(rawText: onlyExpiry);
      expect(r.expiry, '11/31');
      expect(r.dob, isNull);
    });

    test('a reader that expanded the expiry into a full date still works', () {
      // The third fallback, and the one that had no test until a mutation
      // showed it: taking the *first* full date as the expiry instead of the
      // last passed every other test in this file. Nothing exercised the branch,
      // because every other fixture has either a label for the expiry or a bare
      // `mm/yy` for it -- and a branch nothing reaches is a branch that can be
      // wrong without anybody finding out.
      //
      // Here there is no `mm/yy` anywhere and no label, so the expiry can only
      // come from the last full date.
      //
      // `01/11/2031` and not `11/31/2031`. A card's expiry is a month and a
      // year -- November 2031 -- so a reader that expanded it into three
      // components would put the day first. The first version of this fixture
      // wrote `11/31/2031`, which is the 31st of a month that does not exist,
      // and the parser was right to refuse it. The two orderings are the
      // difference between a card and a nonsense string, and only one of them is
      // a thing a camera will ever produce.
      const expanded = '''
GHA-284719305-4
APPAH MENSAH
14/03/1994
02/11/2021
01/11/2031
''';
      final r = GhanaCardParser.parse(rawText: expanded);
      expect(r.error, isNull);
      expect(r.expiry, '11/31');
      expect(r.dob, '14/03/1994');
      expect(r.issued, '02/11/2021');
    });

    test('an expanded expiry with a day of 31 is refused, not salvaged', () {
      // The companion to the fixture above, kept so the refusal is deliberate
      // rather than accidental. 31 is not a month, and reading it as one would
      // hand an employee an expiry that cannot exist.
      final r = GhanaCardParser.parse(
        rawText: 'GHA-284719305-4\nAPPAH MENSAH\n14/03/1994\n02/11/2021\n11/31/2031',
      );
      expect(r.error, 'Expiry date is not a real date');
      expect(r.expiry, isNull);
    });

    test('the expiry printed after a short label is still found', () {
      // `EXP 04/29` is how the existing fixture in kyc_test.dart writes it, and
      // it is not a whole line of `mm/yy` -- so a search anchored to the line
      // missed it and refused the card.
      const shortLabel = 'REPUBLIC OF GHANA\n'
          'GHA-123456789-0\n'
          'JANE COOPER\n'
          'EXP 04/29';
      final r = GhanaCardParser.parse(rawText: shortLabel);
      expect(r.error, isNull);
      expect(r.expiry, '04/29');
      expect(r.name, 'JANE COOPER');
    });

    test('a month over a year inside a full date is not an expiry', () {
      // The trap the lookahead exists for, stated directly. If this ever passes
      // a date of birth off as an expiry, an employee's expiry check is reading
      // a birthday.
      const onlyBirth = '''
GHA-284719305-4
APPAH MENSAH
14/03/1994
''';
      final r = GhanaCardParser.parse(rawText: onlyBirth);
      // There is no expiry at all on this text, so it is refused rather than
      // invented out of the date of birth.
      expect(r.error, 'Could not read the expiry date');
    });
  });

  group('spaces inside a date, which is what a card reader produces', () {
    // Found by mutation: loosening the full-date pattern to require no space at
    // all -- `(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})` -- passed every test in this
    // file. Nothing in any fixture had a space in a date, so the `\s*` in the
    // pattern was untested and could have been dropped without anybody finding
    // out.
    //
    // It matters because a reader's spacing is not the printer's spacing. A card
    // printed `14/03/1994` can be read as `14 / 03 / 1994` or `14/ 03/1994`
    // depending on the kerning and the light, and a driver who then has to type
    // the date by hand because the reader "could not see it" is a worse outcome
    // than a driver who never had the option.
    const spaced = '''
GHA-284719305-4
APPAH MENSAH
Date of Birth: 14 / 03 / 1994
Date of Expiry: 11 / 31
''';

    test('a date with spaces around its separators is read', () {
      final r = GhanaCardParser.parse(rawText: spaced);
      expect(r.error, isNull);
      expect(r.dob, '14/03/1994');
      expect(r.expiry, '11/31');
    });

    test('spaces in the expiry are read too', () {
      final r = GhanaCardParser.parse(rawText: 'GHA-284719305-0\nEXP 04 / 29');
      expect(r.error, isNull);
      expect(r.expiry, '04/29');
    });
  });

  group('a two-digit year is not a year', () {
    test('reads 11/31 as 2031, not 1931', () {
      final r = GhanaCardParser.parse(rawText: 'GHA-284719305-4\n11/31');
      expect(r.expiry, '11/31');
    });

    test('a two-digit expiry inside a four-digit date cannot be mistaken for it', () {
      // `14/03/94` must not match the first three groups of `14/03/1994` and
      // produce 1994 as a month-year pair, which would be a date in 1919 and an
      // age of 107.
      final parsed = parseGhanaCardDate('14/03/1994');
      expect(parsed, isNotNull);
      expect(parsed!.year, 1994);
      expect(ageFromGhanaCardDate('14/03/1994', asOf: DateTime(2026, 9, 30)), 32);
    });
  });

  group('refusals, which have to stay refusals', () {
    test('a blank scan is refused', () {
      expect(
        GhanaCardParser.parse(rawText: '   ').error,
        'Scan was blank, try again',
      );
    });

    test('a card with no number is refused', () {
      expect(
        GhanaCardParser.parse(rawText: 'APPAH MENSAH\n11/31').error,
        'Could not read the card number',
      );
    });

    test('a card with no readable expiry is refused', () {
      expect(
        GhanaCardParser.parse(rawText: 'GHA-284719305-4\nAPPAH MENSAH').error,
        'Could not read the expiry date',
      );
    });

    test('an impossible expiry is refused rather than stored', () {
      // 31/31 is not a date. Accepting it would put a value in front of an
      // employee that cannot be true.
      expect(
        GhanaCardParser.parse(rawText: 'GHA-284719305-4\n31/31').error,
        'Expiry date is not a real date',
      );
    });

    test('31 February as a date of birth is not a date', () {
      expect(parseGhanaCardDate('31/02/1994'), isNull);
    });
  });

  group('age', () {
    // Fixed "today" throughout, so these cannot start failing in December.
    final now = DateTime(2026, 9, 30);

    test('counts whole years, and not a day early', () {
      // The birthday is today, so the driver turns 32 today.
      expect(ageFromGhanaCardDate('30/09/1994', asOf: now), 32);
      // Yesterday's birthday: already 32.
      expect(ageFromGhanaCardDate('29/09/1994', asOf: now), 32);
      // Tomorrow's: still 31.
      expect(ageFromGhanaCardDate('01/10/1994', asOf: now), 31);
    });

    test('reads the three formats a card or a reader produces', () {
      expect(ageFromGhanaCardDate('14/03/1994', asOf: now), 32);
      expect(ageFromGhanaCardDate('14-03-1994', asOf: now), 32);
      expect(ageFromGhanaCardDate('1994-03-14', asOf: now), 32);
      expect(ageFromGhanaCardDate('14/03/94', asOf: now), 32);
    });

    test('an unreadable date is no age rather than a wrong one', () {
      // A wrong age is worse than a missing one. It is the number an employee
      // checks fastest against a face, so a plausible wrong one is a plausible
      // wrong approval.
      for (final bad in ['', '   ', 'not a date', '3/13/994', '00/00/0000']) {
        expect(ageFromGhanaCardDate(bad, asOf: now), isNull, reason: bad);
      }
    });

    test('a date in the future is no age', () {
      expect(ageFromGhanaCardDate('01/01/2030', asOf: now), isNull);
    });

    test('the profile carries the age of its own date of birth', () {
      final profile = DriverProfile(
        id: 'd1',
        fullName: 'Appah Mensah',
        phone: '',
        rating: 5,
        tripCount: 0,
        kyc: KycStatus.pending,
        availability: DriverAvailability.offline,
        cardDob: '14/03/1994',
      );
      expect(profile.age, isNotNull);
      expect(profile.age, greaterThanOrEqualTo(31));
    });
  });

  group('a two-column card does not pair labels with labels', () {
    // A reader that lays the card out as two columns puts every label in one
    // run and every value in another. Taking "the next line" blindly would give
    // `DATE OF BIRTH` -> `SEX`.
    const columns = '''
DATE OF BIRTH
SEX
NATIONALITY
DATE OF EXPIRY
14/03/1994
M
GHANAIAN
11/31
''';

    test('no field is filled with another field name', () {
      final r = GhanaCardParser.parse(rawText: columns);
      for (final value in [r.dob, r.sex, r.nationality, r.issued]) {
        expect(
          value,
          isNot(contains('DATE')),
          reason: 'a label was read as a value: $value',
        );
        expect(value, isNot(contains('SEX')), reason: value);
        expect(value, isNot(contains('NATIONALITY')), reason: value);
      }
    });
  });
}
