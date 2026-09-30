import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';

/// Ghanaian phone numbers, and the three ways people write the same one.
///
/// The whole reason this file exists is that a phone number is compared for
/// equality. If `024 123 4567` and `+233 24 123 4567` do not reduce to the same
/// value, a rider taps "call driver", the dialler opens, and it rings a number
/// nobody answers -- with no error anywhere.

void main() {
  group('the same number written four ways', () {
    const canonical = '0241234567';

    // These are the four forms that actually appear: a driver typing into a
    // field, someone reading a number off a printed card, someone forwarding a
    // number from a WhatsApp contact, and the doubled international prefix.
    const forms = <String, String>{
      'plain local': '0241234567',
      'spaced as people type it': '024 123 4567',
      'with the + country code': '+233 24 123 4567',
      'with 00 instead of +': '0024 123 4567',
      'bracketed': '(024) 123-4567',
      'dotted': '024.123.4567',
    };

    forms.forEach((label, input) {
      test('$label reduces to a dialable number', () {
        expect(normaliseGhanaPhone(input), isNotNull, reason: input);
      });
    });

    test('the local forms all reduce to the same stored value', () {
      // The four local spellings must be *identical*, not merely valid, or the
      // equality comparison that motivates this fails.
      expect(normaliseGhanaPhone('0241234567'), canonical);
      expect(normaliseGhanaPhone('024 123 4567'), canonical);
      expect(normaliseGhanaPhone('(024) 123-4567'), canonical);
      expect(normaliseGhanaPhone('024.123.4567'), canonical);
      expect(normaliseGhanaPhone('0024 123 4567'), canonical);
    });

    test('the + form keeps its international shape rather than being rewritten', () {
      // Storing `+233 24 123 4567` as `0241234567` would make it the same string
      // as the local form, which is right for matching and wrong for display: a
      // driver who wrote the international form should not see it silently
      // rewritten on the profile they are editing.
      expect(normaliseGhanaPhone('+233 24 123 4567'), '233241234567');
    });
  });

  group('the reconstruction, which is where the real bug would be', () {
    // Ghana's local numbers begin `0` and the international form replaces that
    // `0` with `233`. So `233241234567` is NOT `0241234567` with two characters
    // off the front -- the `2` after `233` is not a leading zero, it is a digit
    // of the subscriber number, and the local form is `0` + the remaining nine.
    // Slicing instead of reconstructing yields `41234567`, which is eight digits
    // and belongs to nobody.
    test('an international number is rebuilt, not sliced', () {
      expect(normaliseGhanaPhone('+233241234567'), '233241234567');
      expect(normaliseGhanaPhone('00233241234567'), '233241234567');
    });

    test('a bare 233 with no + is still recognised', () {
      expect(normaliseGhanaPhone('233241234567'), '233241234567');
    });

    test('a country code on its own is not a number', () {
      expect(normaliseGhanaPhone('233'), isNull);
      expect(normaliseGhanaPhone('+233'), isNull);
    });

    // A `+` is a claim about which country the number is from, and the only
    // country this function knows is Ghana.
    //
    // The inputs here are chosen so that this rule is the *only* thing that can
    // refuse them. `+44 7700 900123` is 12 digits, so it would also fail the
    // length check, and the first attempt at this test used it and was useless:
    // deleting the `+` branch's `return null` changed nothing, because the number
    // never reached that line. `+442012345678` is 12 digits after the `+` and the
    // same problem. What isolates the rule is a number that is *ten digits long*
    // and starts with a real Ghanaian prefix, but is not Ghana's: `+233` is
    // checked first, so it is `+44` with a Ghana-shaped body, and only the
    // country check can refuse it.
    test('a + in front of another country is refused rather than rewritten', () {
      // The country check is what refuses these, and nothing else would: each is
      // ten digits with a genuine Ghanaian prefix, so the length, the prefix and
      // the leading-zero rules would all pass them.
      expect(normaliseGhanaPhone('+44241234567'), isNull,
          reason: 'ten digits, real prefix, wrong country -- only the country check refuses this');
      expect(normaliseGhanaPhone('+23424123456'), isNull, reason: 'Nigeria, same shape');
      expect(normaliseGhanaPhone('+233241234567'), '233241234567',
          reason: 'Ghana, the one country it does know');
    });

    test('a + with no country code at all is refused', () {
      // Ten digits, real prefix, a `+` and no country. The `+` says "this is
      // international" and there is no country to read, so it is a number this
      // function has no business guessing at.
      expect(normaliseGhanaPhone('+0241234567'), isNull);
    });

    // The `00` branch. This one is here because the code got it wrong twice and
    // the tests did not catch either time: the first version required a leading
    // `0` *after* stripping the `00`, which is impossible, and the second had no
    // length check at all. The mutation that removed the length check entirely
    // also passed the whole suite, because `_local` re-checks the length -- so
    // the assertion below is on the *behaviour* (`0024 123 4567` is accepted),
    // not on the guard being present.
    //
    // `0024 123 4567` is the form a Ghanaian most often uses for their own
    // number: `00` in front of the local number, where the `00` has doubled the
    // leading zero rather than sitting in front of it. Getting this wrong means
    // the form is refused as a nine-digit number, and the driver cannot enter
    // the number they know themselves by.
    test('00 in front of a local number is that number, not a nine-digit one', () {
      expect(normaliseGhanaPhone('0024 123 4567'), '0241234567');
      // And the `00` is not preserved, because `00` is a dialling instruction
      // rather than part of the number.
      expect(normaliseGhanaPhone('0024 123 4567'), isNot(contains('00')));
    });

    test('00 followed by a full country code is the international form', () {
      expect(normaliseGhanaPhone('00233241234567'), '233241234567');
    });

    test('00 followed by ten digits of another country is refused', () {
      // `00` + a complete foreign number. The length check is what separates
      // this from `0024 123 4567`, and it is the branch's whole job.
      expect(normaliseGhanaPhone('00447700900123'), isNull);
    });
  });

  group('refused rather than stored', () {
    // Every one of these is null rather than a best-effort string. A wrong
    // number that dials rings somebody, which is worse than no number.
    const refused = <String, String>{
      'empty': '',
      'whitespace': '   ',
      'letters': 'not a number',
      'seven digits': '0241234',
      'eleven digits': '02412345678',
      'nine digits': '241234567',
      'an impossible prefix': '0191234567',
      'a foreign number': '+44 7700 900123',
      'a foreign number with 00': '00447700900123',
      'just a plus': '+',
      'just zeros': '0000000000',
    };

    refused.forEach((label, input) {
      test('$label is refused', () {
        expect(normaliseGhanaPhone(input), isNull, reason: input);
      });
    });

    test('null in is null out, not a crash', () {
      expect(normaliseGhanaPhone(null), isNull);
    });
  });

  group('the leading zero, isolated from the other two rules', () {
    // `_local` refuses on three separate grounds: length, leading zero, and a
    // known prefix. A test case for the leading zero has to be a number that
    // passes the other two, or it proves nothing about this one -- and the first
    // attempt at this used `2412345678`, whose prefix `241` is not a Ghanaian
    // one, so deleting the leading-zero check entirely left the suite green.
    //
    // `24` is MTN, and `24` + eight digits is ten digits, so `2412345678` is
    // ten digits with no leading zero and a real-looking prefix. Only the zero
    // check can refuse it.
    test('ten digits, real prefix, no leading zero is refused', () {
      expect(normaliseGhanaPhone('2412345678'), isNull);
      // And the same number with its zero is fine, so the zero really is the
      // only thing being tested.
      expect(normaliseGhanaPhone('0241234567'), '0241234567');
    });
  });

  group('the prefixes Ghana actually issues', () {
    // A number with a prefix that does not exist is a typo, not a new network.
    const valid = [
      '0201234567', // MTN
      '0241234567', // MTN
      '0271234567', // MTN
      '0501234567', // Vodafone
      '0551234567', // Vodafone
      '0591234567', // Airtel
      '0301234567', // fixed line
      '0801234567', // fixed line
    ];
    for (final number in valid) {
      test('$number is accepted', () {
        expect(normaliseGhanaPhone(number), number);
      });
    }
  });

  group('isCallableGhanaPhone', () {
    test('a real number is callable', () {
      expect(isCallableGhanaPhone('0241234567'), isTrue);
      expect(isCallableGhanaPhone('+233 24 123 4567'), isTrue);
    });

    // The predicate the call buttons gate on. An empty string is false rather
    // than "unknown": a driver who never entered a number cannot be called, and
    // a button that opens an empty dialler is a worse affordance than no button.
    test('an empty or absent number is not callable', () {
      expect(isCallableGhanaPhone(null), isFalse);
      expect(isCallableGhanaPhone(''), isFalse);
      expect(isCallableGhanaPhone('   '), isFalse);
      expect(isCallableGhanaPhone('0241234'), isFalse);
      expect(isCallableGhanaPhone('nonsense'), isFalse);
    });
  });

  group('the dialler URI', () {
    test('is tel: with the bare number', () {
      // `tel:` is what both platforms hand to the dialler. The number goes in
      // the path with no query, because a `tel:` URI with a query is honoured by
      // some launchers and ignored by others, and the failure mode is a dialler
      // that opens with nothing in it.
      expect(ghanaTelUri('024 123 4567'), 'tel:0241234567');
      expect(ghanaTelUri('+233 24 123 4567'), 'tel:233241234567');
    });

    test('is null for anything not worth dialling', () {
      expect(ghanaTelUri(null), isNull);
      expect(ghanaTelUri(''), isNull);
      expect(ghanaTelUri('0241234'), isNull);
    });
  });

  group('the display form', () {
    test('a local number is grouped for reading', () {
      expect(formatGhanaPhone('0241234567'), '024 123 4567');
      expect(formatGhanaPhone('+233 24 123 4567'), '+233 24 123 4567');
    });

    // A driver is easier to recognise on a phone as the local form. The two
    // forms appearing next to each other on a screen that also has a call button
    // is confusing, so the form the driver typed is the form shown back.
    test('an international number keeps its country code', () {
      expect(formatGhanaPhone('233241234567'), '+233 24 123 4567');
    });

    test('is null for anything not a number', () {
      expect(formatGhanaPhone('nonsense'), isNull);
      expect(formatGhanaPhone(null), isNull);
    });
  });

  group('round tripping', () {
    // What a driver types goes in, comes out in a readable form, and goes back
    // in. If that does not hold, the profile screen rewrites what was typed on
    // every save.
    const inputs = [
      '0241234567',
      '024 123 4567',
      '(024) 123-4567',
      '+233 24 123 4567',
      '0024 123 4567',
    ];
    for (final input in inputs) {
      test('$input survives normalise -> format -> normalise', () {
        final once = normaliseGhanaPhone(input);
        expect(once, isNotNull);
        final shown = formatGhanaPhone(once);
        expect(shown, isNotNull);
        expect(normaliseGhanaPhone(shown), once, reason: 'formatting must not change the value');
      });
    }
  });
}
