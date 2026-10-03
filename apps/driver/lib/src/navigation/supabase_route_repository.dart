import 'dart:async';

import 'package:mng_core/mng_core.dart';

import 'navigation_controller.dart';

/// [RouteRepository] over the `route` Edge Function.
///
/// A function call rather than a direct OSRM call from the app, for the same
/// reason `contact` exists: the routing engines are keys somebody has to hold, and
/// the app must not hold them.
///
/// The engine, the traffic factor and the step wording are all decided there. This
/// sends two points and renders what comes back, and it deliberately does not
/// second-guess the duration -- `durationS` is what a rider should be shown, and
/// `durationFreeFlowS` is kept alongside it for the diagnostics rather than used to
/// recompute anything.
class SupabaseRouteRepository implements RouteRepository {
  SupabaseRouteRepository(this._client);

  final dynamic _client;

  /// How long a routing call may take before it is treated as failed.
  ///
  /// A live call to the deployed function answers in about a second. Fifteen
  /// seconds is several times that, so this is not a threshold a healthy request
  /// ever approaches -- it exists because without it a call that never answers
  /// leaves the banner on "Finding a new route" indefinitely, which is the one
  /// thing a driver cannot be shown while they are driving. The in-flight guard in
  /// `NavigationController` stops requests piling up, but it cannot rescue a single
  /// call that hangs; only a deadline can, and a deadline has to produce a message
  /// the driver can act on rather than silence.
  static const Duration timeout = Duration(seconds: 15);

  @override
  Future<TripRoute> route(GeoPoint from, GeoPoint to) async {
    try {
      final res = await _client.functions
          .invoke('route', body: {'from': from.toJson(), 'to': to.toJson()})
          .timeout(timeout);
      final data = res.data;
      if (data is! Map) {
        // A 200 with something that is not a route object. Worth distinguishing
        // from "no route": the first is a server fault and the second is a real
        // answer, and they read the same if they are collapsed.
        throw const NavigationFailure('Directions did not come back properly.');
      }
      return TripRoute.fromJson(Map<String, dynamic>.from(data));
    } on NavigationFailure {
      rethrow;
    } catch (e) {
      // The function answers an error status with `{"error": "<string>"}` and
      // `functions.invoke` throws rather than returning, so the message is in the
      // exception's details. `describeFunctionFailure` is this project's rule for
      // reading one, and using it here keeps the wording identical to every other
      // function call in the driver app.
      throw NavigationFailure(_readFailure(e));
    }
  }

  static String _readFailure(Object e) {
    // Checked before the duck-typed reads below, because `TimeoutException` has no
    // `details` and `status` and probing for them throws -- which the `catch` at
    // the bottom would turn into the generic sentence, losing the one fact the
    // driver can act on.
    if (e is TimeoutException) {
      return 'Directions took too long. Try again in a moment.';
    }
    try {
      final details = (e as dynamic).details;
      if (details is Map) {
        final message = details['error'];
        if (message is String && message.isNotEmpty) return message;
      }
      if (details is String && details.isNotEmpty) return details;
      final status = (e as dynamic).status;
      if (status == 0) return 'Could not reach the server';
    } catch (_) {
      // Fall through. A failure object that cannot be read is still a failure, and
      // the sentence below is honest about it.
    }
    return 'Could not work out the route';
  }
}

/// [SpeechPort] over `flutter_tts`.
///
/// Two settings here are not defaults and both matter on a phone in a car:
///
/// **Rate.** The platform default is a little fast for a sentence heard over road
/// noise while the driver is concentrating. Slower is understood first time.
///
/// **Language.** Unset on purpose in production terms only: it is set to `en-GB`
/// because the instructions are written in British English ("turn left onto") and a
/// Ghanaian English voice pronounces them the way they were written. It is a
/// constant rather than the device's locale, because a phone set to Twi would
/// otherwise read an English road name with Twi phonemes.
class FlutterTtsSpeech implements SpeechPort {
  FlutterTtsSpeech(this._tts) {
    unawaitedConfigure();
  }

  final dynamic _tts;
  bool _configured = false;

  void unawaitedConfigure() {
    if (_configured) return;
    _configured = true;
    // Fire and forget: configuration is not worth blocking a screen for, and a
    // failure here is not worth surfacing -- the voice simply stays at whatever
    // the platform defaults to.
    () async {
      try {
        await _tts.setLanguage('en-GB');
        await _tts.setSpeechRate(0.45);
        await _tts.awaitSpeakCompletion(false);
      } catch (_) {
        // Nothing. A driver whose phone will not configure text-to-speech still
        // gets the banner, which is the part they cannot do without.
      }
    }();
  }

  @override
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    try {
      await _tts.speak(text);
    } catch (_) {
      // Same reasoning as above: a voice that fails is a nuisance, and a
      // navigation screen that throws because of it is unusable.
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {
      // Nothing.
    }
  }
}
