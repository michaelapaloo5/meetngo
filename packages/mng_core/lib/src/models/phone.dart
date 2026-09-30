/// Ghanaian phone numbers, reduced to something two people typing the same
/// number differently will agree on.
///
/// This exists because a phone number is compared for equality, and the three
/// ways a Ghanaian number is written in ordinary use are all the same number:
///
///   024 123 4567      0241234567      what a driver types
///   +233 24 123 4567  233241234567    what someone reading it off a card writes
///   0024 123 4567     0241234567      the international prefix, doubled up
///
/// Storing whatever was typed means a rider who dials `+233 24 123 4567` does
/// not match a driver who typed `0241234567`, and the failure is silent: the
/// call button exists, it opens the dialler, and it dials a number nobody
/// answers.
///
/// What comes out is the 10-digit local form when the number is a local one, so
/// `0241234567`, and the 12-digit international form when the caller supplied a
/// country code, so `233241234567`. Both are dialled identically by Android and
/// iOS. Anything that does not reduce to one of those is **null**, not a
/// best-effort string: a wrong number that dials is worse than no number, because
/// it rings somebody.
///
/// The mobile prefixes are checked. Ghana's are `020`-`027`, `050`-`057` and
/// `059`; the fixed lines are `030`-`039` and `080`-`084`. `024` is MTN, `055`
/// is Vodafone, `054` is AirtelTigo. The check is on the first three digits
/// because that is the part that identifies a network, and a number with an
/// impossible prefix is a typo rather than a new network.
///
/// Why this lives in `mng_core` and not in the driver app: the rider app needs
/// the same rule to decide whether to show a call button at all, and two
/// implementations of "is this a number worth dialling" is one too many. The
/// server does not use it -- `profiles.phone` is a `text` column and stores
/// whatever normalises, which is the whole reason it is `text` and not a
/// numeric type.
library;

/// The Ghana country code, without a plus.
const String kGhanaCountryCode = '233';

/// A local Ghanaian mobile number: 10 digits, starting 02 or 05.
const int kGhanaMobileDigits = 10;

/// The prefixes Ghana issues, as the first three digits of a local number.
///
/// A number outside this set is refused rather than stored. This is the rule
/// that turns `0241234` (seven digits, a number half typed) into a field that
/// says "that is not a Ghanaian number" instead of a number that rings nobody.
const Set<String> kGhanaMobilePrefixes = {
  // MTN
  '020', '023', '024', '025', '026', '027',
  // Vodafone
  '050', '051', '052', '053', '054', '055', '056', '057',
  // Airtel
  '059',
  // `057` is listed once, above, under Vodafone. It was listed a second time here
  // for AirtelTigo, which is a duplicate set element and does not compile -- and
  // the comment claiming the two networks share the range is not the reason to
  // list it twice anyway. A set is a set.
};

/// Fixed lines, which are also worth accepting: a driver may be reachable on one.
const Set<String> kGhanaFixedPrefixes = {
  '030', '031', '032', '033', '034', '035', '036', '037', '038', '039',
  '080', '081', '082', '083', '084',
};

/// Reduce [input] to a dialable Ghanaian number, or null if it is not one.
///
/// Handles, in order: a `+` prefix, a `00` international prefix, a bare `233`
/// with no `+`, and a local `0XX...`. Whitespace, dashes, dots and brackets are
/// removed first, because a number pasted from a card arrives with all of them.
///
/// The `233` case has a trap in it. Ghana's local numbers start `0`, and the
/// international form replaces that `0` with `233`. So `233241234567` has twelve
/// digits, and slicing two off the front is not the operation -- the `2` after
/// `233` is not a leading `0` to delete, the local form is `241234567` with a
/// `0` prepended. Getting that wrong produces `41234567`, which is eight digits
/// and belongs to nobody, so the reconstruction is written out rather than
/// sliced.
String? normaliseGhanaPhone(String? input) {
  if (input == null) return null;
  // Strip everything that is not a digit, and note a single leading `+`.
  //
  // The `+` has to be read BEFORE the digits are pulled out, because `+233...`
  // and `233...` are the same number but only the first is explicitly
  // international. That distinction is what decides whether a driver who typed
  // `+233 24 123 4567` sees their own formatting back on the profile or has it
  // silently rewritten to the local form, so it is carried through the whole
  // function rather than being guessed at the end.
  final trimmed = input.trim();
  if (trimmed.isEmpty) return null;
  final hadPlus = trimmed.startsWith('+');
  final digits = trimmed.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty) return null;

  // A leading `00` is an international access prefix, so it is removed before
  // anything else looks at the digits. Left in place it makes every `00`-form
  // two digits too long, and every one of them is refused for being the wrong
  // length -- which is how `0024 123 4567`, the form a Ghanaian most often uses
  // for their own number, was being rejected.
  // An explicit international marker: a leading `+` or a leading `00`.
  //
  // Only the `00` form is also the local form with a prefix, so only the `00`
  // gets the leading zero back. `+233 24 123 4567` is genuinely an
  // international number and the country code is mandatory there -- a `+` in
  // front of anything that is not Ghana is a number from somewhere else that
  // this function has no business rewriting.
  final isDoubleZero = digits.startsWith('00');
  final withoutPrefix = isDoubleZero ? digits.substring(2) : digits;
  if (withoutPrefix.isEmpty) return null;

  if (isDoubleZero) {
    if (withoutPrefix.startsWith(kGhanaCountryCode)) {
      return _international(withoutPrefix.substring(kGhanaCountryCode.length));
    }
    // `0024 123 4567` is `00` written in front of the number the caller already
    // had, which was `0241234567`. The `00` does not sit in front of that
    // leading zero -- it *is* that zero, doubled. So stripping the `00` leaves
    // nine digits, `241234567`, and the `0` has to be put back.
    //
    // The distinguishing test is length, not a leading character. An earlier
    // version of this comment claimed a leading `0` was the marker, and that
    // could not be right: the check runs on the string *after* the `00` is gone,
    // and by that point the only `0` that was ever there is inside `241234567`.
    // Nine digits means a local number that lost its leading zero, so it gets it
    // back. Ten means a different country's number and is refused.
    //
    // The length check is not redundant even though `_local` re-checks the
    // length: the branch exists to decide whether to *prepend* a zero, and
    // `_local('0' + tenDigits)` would be an eleven-digit string that `_local`
    // then refuses. Removing this guard therefore changes nothing, and that is
    // the honest description of it -- a guard against an impossible branch
    // rather than a rule in its own right. It is kept because it says what the
    // branch is for, and `phone_test.dart` asserts the behaviour it produces
    // (`0024 123 4567` is accepted) rather than its presence.
    if (withoutPrefix.length == kGhanaMobileDigits - 1) {
      return _local('0$withoutPrefix');
    }
    return null;
  }

  if (hadPlus) {
    // A `+` is an explicit claim about which country this is, and Ghana is the
    // only one this function knows.
    if (withoutPrefix.startsWith(kGhanaCountryCode)) {
      return _international(withoutPrefix.substring(kGhanaCountryCode.length));
    }
    return null;
  }

  // No international marker. A bare `233...` is still recognised, because it is
  // unambiguous -- a local number cannot start with 233, since it starts `0`.
  if (withoutPrefix.startsWith(kGhanaCountryCode) && withoutPrefix.length > kGhanaMobileDigits) {
    return _international(withoutPrefix.substring(kGhanaCountryCode.length));
  }

  return _local(withoutPrefix);
}

/// `241234567` -> `233241234567`, refusing anything that is not a real number.
///
/// The `0` is *prepended* to `rest` and the result checked, rather than two
/// characters being sliced off the front of the full string. Those look the same
/// and are not: `233241234567` minus its first two characters is `3241234567`,
/// not `241234567`, because the `2` after the country code is a digit of the
/// subscriber number and not a leading zero to delete. The reconstruction is
/// written out here so the arithmetic is visible rather than implied.
String? _international(String rest) {
  // `rest` is what came after `233`. A Ghanaian number is nine digits after its
  // leading zero, so anything else is not one -- and the `0` is put back rather
  // than sliced out, which is the whole point.
  if (rest.length != kGhanaMobileDigits - 1) return null;
  return _local('0$rest') == null ? null : '$kGhanaCountryCode$rest';
}

/// The local form: exactly ten digits, a known prefix, leading zero.
///
/// The order is deliberate. Length first, because it is the cheapest and the
/// most often wrong -- a half-typed number fails here and never reaches the
/// prefix set. Prefix set last, because it is the only check that can be wrong
/// in an interesting way.
///
/// The leading-zero check in the middle is **implied** by the prefix set: every
/// entry in both sets begins `0`, so any ten-digit number that passes the prefix
/// check already has a leading zero. It is kept because the reason a number is
/// refused should be legible rather than inferred from a set literal, and
/// because it is the check a reader looks for when a number they believe is
/// valid comes back null.
///
/// That it is implied is also why `toolchain/mutate-phone.mjs` records deleting
/// it as SURVIVING rather than as a gap in the tests: no input exists that this
/// check refuses and the prefix check does not, so no test asserting it can be
/// written. Two attempts to write one are in the history of this file, and both
/// were wrong in the same way -- `2412345678` was chosen because `24` looks like
/// MTN, and it is not: MTN's prefixes are `020` through `027`, so `241` is in no
/// set and the *prefix* check is what refuses it. The behaviour is covered by the
/// prefix set test, which is the rule doing the work.
String? _local(String digits) {
  if (digits.length != kGhanaMobileDigits) return null;
  if (!digits.startsWith('0')) return null;
  final prefix = digits.substring(0, 3);
  if (!kGhanaMobilePrefixes.contains(prefix) && !kGhanaFixedPrefixes.contains(prefix)) {
    return null;
  }
  return digits;
}

/// Whether [input] is a number worth dialling, i.e. not empty and valid.
///
/// This is the predicate the "call rider" and "call driver" buttons gate on. An
/// empty string is false rather than "unknown": a driver who never entered a
/// number cannot be called, and a button that opens an empty dialler is a worse
/// affordance than no button.
bool isCallableGhanaPhone(String? input) =>
    input != null && normaliseGhanaPhone(input) != null;

/// A dialler URI for [input], or null when it is not a number we can dial.
///
/// `tel:` rather than a `mailto:`-style scheme because that is what both Android
/// and iOS hand to the dialler, and it accepts the bare digits as well as the
/// spaced form. The number goes in the path with no query string, because a
/// `tel:` URI with a query is honoured by some launchers and ignored by others,
/// and the failure mode is a dialler that opens with nothing in it.
String? ghanaTelUri(String? input) {
  final normalised = normaliseGhanaPhone(input);
  if (normalised == null) return null;
  return 'tel:$normalised';
}

/// A short human form for [input], e.g. `024 123 4567`.
///
/// For display next to a name, not for dialling. A driver is easier to recognise
/// on a phone as `024 123 4567` than as `233241234567`, and the two forms of the
/// same number next to each other is confusing on a screen that also has a call
/// button on it.
String? formatGhanaPhone(String? input) {
  final normalised = normaliseGhanaPhone(input);
  if (normalised == null) return null;
  if (normalised.length == kGhanaMobileDigits) {
    return '${normalised.substring(0, 3)} ${normalised.substring(3, 6)} ${normalised.substring(6)}';
  }
  // The international form: +233 24 123 4567
  final rest = normalised.substring(kGhanaCountryCode.length);
  return '+$kGhanaCountryCode ${rest.substring(0, 2)} ${rest.substring(2, 5)} ${rest.substring(5)}';
}
