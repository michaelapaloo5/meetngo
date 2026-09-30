import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_driver/src/onboarding/liveness/face_reading.dart';
import 'package:meetngo_driver/src/onboarding/liveness/liveness_session.dart';
import 'package:meetngo_driver/src/onboarding/liveness/liveness_verifier.dart';

/// The liveness check, with no camera and no model.
///
/// Every case here is an attack or a failure mode, not a happy path. A liveness
/// check whose tests are "turn left, it goes green" proves that the code runs;
/// what matters is that a photograph, a second face, a missing measurement and
/// a sweep of the head all fail.
void main() {
  /// A well-behaved reading: one face, a real mesh, centred, eyes open, and the
  /// anti-spoof model satisfied.
  ///
  /// [live] defaults to 0.9 rather than to null, and that default is the whole
  /// reason the older tests kept passing unchanged. A reading with no spoof
  /// score is a real state -- it is what a device where the model would not load
  /// produces on every frame -- but it is a state that cannot pass, and making
  /// it the default would have quietly turned every "a good driver passes"
  /// test into a "the check is broken" test without anybody noticing.
  FaceReading good({
    required DateTime at,
    double yaw = 0,
    double pitch = 0,
    double? leftEye = 0.9,
    double? rightEye = 0.9,
    double? smile = 0.1,
    int faces = 1,
    int points = kMinContourPoints,
    double? live = 0.9,
  }) => FaceReading(
    at: at,
    faceCount: faces,
    yaw: yaw,
    pitch: pitch,
    leftEyeOpen: leftEye,
    rightEyeOpen: rightEye,
    smile: smile,
    contourPoints: points,
    spoofScore: live,
  );

  DateTime t0 = DateTime.utc(2026, 9, 29, 12);

  /// Feeds centred, live frames until the anti-spoof model has been satisfied
  /// [kMinLiveSamples] times, working *backwards* from [start].
  ///
  /// Backwards so a test can keep using `t0` and its own fixed offsets without
  /// renumbering them. The frames are centred, so they arm the first challenge
  /// and change nothing else, and they are 100ms apart, so they cannot eat into
  /// the twelve-second challenge timeout.
  ///
  /// This exists because a pass now needs two things -- the challenges met *and*
  /// the model satisfied -- and a test about the first used to pass with three
  /// frames and now needs eight. Writing the eight out at the top of each such
  /// test would say the same thing more slowly and hide which requirement it is
  /// satisfying.
  void primed(LivenessVerifier v, {DateTime? start}) {
    final from = start ?? t0;
    for (var i = kMinLiveSamples; i > 0; i--) {
      v.observe(good(at: from.subtract(Duration(milliseconds: 100 * i))));
    }
  }

  group('a photograph cannot pass it', () {
    test('a held-up photo has no head pose, so no turn ever counts', () {
      // The core claim. A printed photograph is detected as a face, and every
      // attribute ML Kit reports about it is a guess. The angles come back
      // near zero and never move, so a turn challenge is never satisfied.
      final v = LivenessVerifier([LivenessChallenge.turnLeft]);

      // Twenty seconds of the most responsive possible "photo": a face, a full
      // mesh, and a clean zero angle. A driver turning their head for twenty
      // seconds passes this in about one second.
      for (var i = 0; i < 200; i++) {
        v.observe(good(at: t0.add(Duration(milliseconds: 100 * i))));
      }

      expect(v.outcome, isNot(LivenessOutcome.passed));
      expect(v.completed, 0);
    });

    test('a photo cannot blink', () {
      // Eyelids are what separate a face from a picture of a face. A
      // photograph reports a constant openness, so it can be open or shut but
      // never does both, and the challenge requires both.
      final v = LivenessVerifier([LivenessChallenge.blink]);

      v.observe(good(at: t0));
      for (var i = 1; i < 100; i++) {
        v.observe(good(at: t0.add(Duration(milliseconds: 100 * i))));
      }

      expect(v.completed, 0);
    });

    test('a face caught mid-blink does not count as having blinked', () {
      // The eyes must be seen OPEN first. Without that, a driver who is
      // reading the prompt with their eyes half shut is asked to blink, the
      // detector sees shut eyes, and the challenge passes without a blink.
      final v = LivenessVerifier([LivenessChallenge.blink]);

      v.observe(good(at: t0)); // armed, centred
      v.observe(
        good(
          at: t0.add(const Duration(milliseconds: 100)),
          leftEye: 0.05,
          rightEye: 0.05,
        ),
      );

      expect(
        v.completed,
        0,
        reason: 'eyes were never seen open, so this is not a blink',
      );
    });

    test('a real blink counts, because the eyes open and then shut', () {
      final v = LivenessVerifier([LivenessChallenge.blink]);

      primed(v);
      v.observe(good(at: t0));
      v.observe(good(at: t0.add(const Duration(milliseconds: 100))));
      v.observe(
        good(
          at: t0.add(const Duration(milliseconds: 200)),
          leftEye: 0.05,
          rightEye: 0.05,
        ),
      );

      expect(v.completed, 1);
      expect(v.outcome, LivenessOutcome.passed);
    });
  });

  group('holding up a photo of yourself is caught', () {
    test('two faces fail immediately, and say why', () {
      final v = LivenessVerifier([LivenessChallenge.turnLeft]);

      v.observe(good(at: t0));
      v.observe(good(at: t0.add(const Duration(milliseconds: 100)), faces: 2));

      // Not merely "not passed" -- the driver has to be told to put the photo
      // down, which is a different instruction from "come closer".
      expect(v.outcome, LivenessOutcome.tooManyFaces);
      expect(v.isOver, isTrue);
    });

    test('an empty frame fails rather than waiting forever', () {
      final v = LivenessVerifier([LivenessChallenge.turnLeft]);

      v.observe(FaceReading.noFace(t0));

      expect(v.outcome, LivenessOutcome.noFace);
    });

    test('a detection with no face mesh is refused', () {
      // A detector wired up with `enableContours` off reports a face and no
      // mesh, and would then never produce a usable angle. Refusing here turns
      // a silent every-driver-fails bug into one clear failure at frame one.
      final v = LivenessVerifier([LivenessChallenge.turnLeft]);

      v.observe(good(at: t0, points: 0));

      expect(v.outcome, LivenessOutcome.noFace);
    });
  });

  group('each challenge has to start from centre', () {
    test(
      'a head that jumps from one extreme to the other does not pass both',
      () {
        // The re-centre rule, stated honestly. A head that goes straight from
        // hard-left to hard-right without ever passing through centre cannot
        // clear a right-turn challenge, because the right challenge was never
        // armed -- however long the pose is held.
        final v = LivenessVerifier([
          LivenessChallenge.turnLeft,
          LivenessChallenge.turnRight,
        ]);

        v.observe(good(at: t0));
        v.observe(
          good(at: t0.add(const Duration(milliseconds: 100)), yaw: -30),
        );
        expect(v.completed, 1);
        v.observe(good(at: t0.add(const Duration(milliseconds: 200)), yaw: 35));
        v.observe(good(at: t0.add(const Duration(milliseconds: 300)), yaw: 40));
        v.observe(good(at: t0.add(const Duration(milliseconds: 400)), yaw: 38));

        expect(
          v.completed,
          1,
          reason:
              'the right turn was never armed, so holding right does '
              'nothing',
        );
      },
    );

    test('but a smooth sweep through centre really is two turns', () {
      // The honest counterpoint, and the reason the test above is worded the
      // way it is. A driver whose head passes through centre on the way from
      // left to right has genuinely turned left and genuinely turned right;
      // rejecting that would mean failing somebody for moving normally. An
      // earlier version of this test claimed a sweep was an attack. It is not,
      // and the claim was wrong.
      final v = LivenessVerifier([
        LivenessChallenge.turnLeft,
        LivenessChallenge.turnRight,
      ]);

      v.observe(good(at: t0));
      v.observe(good(at: t0.add(const Duration(milliseconds: 100)), yaw: -30));
      expect(v.completed, 1);
      v.observe(good(at: t0.add(const Duration(milliseconds: 200))));
      v.observe(good(at: t0.add(const Duration(milliseconds: 300)), yaw: 30));

      expect(v.completed, 2);
    });

    test('doing them one at a time, with a return to centre, passes', () {
      final v = LivenessVerifier([
        LivenessChallenge.turnLeft,
        LivenessChallenge.turnRight,
        LivenessChallenge.tiltDown,
      ]);

      primed(v);
      v.observe(good(at: t0));
      v.observe(good(at: t0.add(const Duration(milliseconds: 100)), yaw: -30));
      expect(v.completed, 1);
      v.observe(good(at: t0.add(const Duration(milliseconds: 200)), yaw: 30));
      expect(
        v.completed,
        1,
        reason: 'not re-centred, so the right does not count',
      );
      v.observe(good(at: t0.add(const Duration(milliseconds: 300))));
      v.observe(good(at: t0.add(const Duration(milliseconds: 400)), yaw: 30));
      expect(v.completed, 2);
      v.observe(good(at: t0.add(const Duration(milliseconds: 500))));
      v.observe(
        good(at: t0.add(const Duration(milliseconds: 600)), pitch: -25),
      );
      expect(v.completed, 3);
      expect(v.outcome, LivenessOutcome.passed);
    });
  });

  group('up and down are not the same challenge', () {
    // These were the wrong way round when first written, and the only reason
    // they are pinned here is that a driver tilting down while being asked to
    // tilt up cannot do it under any circumstances -- which on a phone reads
    // as a broken check, not as a driver doing it wrong.
    test('tilting down does not satisfy tilt up', () {
      final v = LivenessVerifier([LivenessChallenge.tiltUp]);

      v.observe(good(at: t0));
      for (var i = 1; i <= 20; i++) {
        v.observe(
          good(at: t0.add(Duration(milliseconds: 100 * i)), pitch: -30),
        );
      }

      expect(v.completed, 0);
    });

    test('tilting up does not satisfy tilt down', () {
      final v = LivenessVerifier([LivenessChallenge.tiltDown]);

      v.observe(good(at: t0));
      for (var i = 1; i <= 20; i++) {
        v.observe(good(at: t0.add(Duration(milliseconds: 100 * i)), pitch: 30));
      }

      expect(v.completed, 0);
    });

    test('each is satisfied by its own direction', () {
      final up = LivenessVerifier([LivenessChallenge.tiltUp]);
      up.observe(good(at: t0));
      up.observe(
        good(at: t0.add(const Duration(milliseconds: 100)), pitch: 30),
      );
      expect(up.completed, 1);

      final down = LivenessVerifier([LivenessChallenge.tiltDown]);
      down.observe(good(at: t0));
      down.observe(
        good(at: t0.add(const Duration(milliseconds: 100)), pitch: -30),
      );
      expect(down.completed, 1);
    });
  });

  group('a missing measurement is not a measurement', () {
    test('a null yaw cannot satisfy a head turn', () {
      // ML Kit only guarantees yaw in accurate mode. In fast mode it is null,
      // and reading null as zero would pass a driver who never turned their
      // head at all -- the single worst possible bug in this file.
      final v = LivenessVerifier([LivenessChallenge.turnLeft]);

      v.observe(good(at: t0));
      for (var i = 1; i < 50; i++) {
        v.observe(
          FaceReading(
            at: t0.add(Duration(milliseconds: 100 * i)),
            faceCount: 1,
            // no yaw, no pitch: exactly what a fast-mode detector reports
            contourPoints: kMinContourPoints,
            leftEyeOpen: 0.9,
            rightEyeOpen: 0.9,
          ),
        );
      }

      expect(v.completed, 0);
      expect(v.outcome, isNot(LivenessOutcome.passed));
    });

    test('a null smile cannot satisfy a smile', () {
      final v = LivenessVerifier([LivenessChallenge.smile]);

      v.observe(good(at: t0));
      for (var i = 1; i < 50; i++) {
        v.observe(
          FaceReading(
            at: t0.add(Duration(milliseconds: 100 * i)),
            faceCount: 1,
            contourPoints: kMinContourPoints,
            smile: null,
            leftEyeOpen: 0.9,
            rightEyeOpen: 0.9,
          ),
        );
      }

      expect(v.completed, 0);
    });

    test('a null eye probability cannot satisfy a blink', () {
      final v = LivenessVerifier([LivenessChallenge.blink]);

      v.observe(good(at: t0));
      for (var i = 1; i < 50; i++) {
        v.observe(
          FaceReading(
            at: t0.add(Duration(milliseconds: 100 * i)),
            faceCount: 1,
            contourPoints: kMinContourPoints,
          ),
        );
      }

      expect(v.completed, 0);
    });
  });

  group('it times out rather than hanging', () {
    test('a driver who never does the thing runs out of time', () {
      final v = LivenessVerifier([LivenessChallenge.turnLeft]);

      v.observe(good(at: t0));
      // Centred, healthy, doing nothing, for far longer than the timeout.
      for (var i = 1; i <= 200; i++) {
        v.observe(good(at: t0.add(Duration(milliseconds: 100 * i))));
      }

      expect(v.outcome, LivenessOutcome.timedOut);
      expect(v.isOver, isTrue);
    });

    test('the timeout is measured from arming, not from the last frame', () {
      // So a long pause with the phone in a pocket fails on the frame that
      // comes back, not on a timer that ran while nothing was being analysed.
      final v = LivenessVerifier([LivenessChallenge.turnLeft]);

      v.observe(good(at: t0));
      v.observe(good(at: t0.add(const Duration(seconds: 20))));

      expect(v.outcome, LivenessOutcome.timedOut);
    });

    test('a passed check ignores later frames', () {
      // The camera does not stop when the check ends. A verifier that kept
      // evaluating would re-decide the outcome on a frame that arrived late.
      final v = LivenessVerifier([LivenessChallenge.blink]);

      primed(v);
      v.observe(good(at: t0));
      v.observe(good(at: t0.add(const Duration(milliseconds: 100))));
      v.observe(
        good(
          at: t0.add(const Duration(milliseconds: 200)),
          leftEye: 0.05,
          rightEye: 0.05,
        ),
      );
      expect(v.outcome, LivenessOutcome.passed);

      v.observe(FaceReading.noFace(t0.add(const Duration(seconds: 5))));

      expect(v.outcome, LivenessOutcome.passed);
    });
  });

  group('thresholds are where they are for a reason', () {
    test('a small turn is not a turn', () {
      // 12 degrees is inside the noise of someone holding a phone at arm's
      // length. Accepting it would pass drivers who did not turn their head.
      final v = LivenessVerifier([LivenessChallenge.turnLeft]);

      v.observe(good(at: t0));
      for (var i = 1; i <= 20; i++) {
        v.observe(good(at: t0.add(Duration(milliseconds: 100 * i)), yaw: -12));
      }

      expect(v.completed, 0);
    });

    test('an obvious turn is', () {
      final v = LivenessVerifier([LivenessChallenge.turnLeft]);

      v.observe(good(at: t0));
      v.observe(good(at: t0.add(const Duration(milliseconds: 100)), yaw: -35));

      expect(v.completed, 1);
    });

    test('left and right are not interchangeable', () {
      // A driver who only ever turns right must not clear a left challenge.
      final v = LivenessVerifier([LivenessChallenge.turnLeft]);

      v.observe(good(at: t0));
      for (var i = 1; i <= 20; i++) {
        v.observe(good(at: t0.add(Duration(milliseconds: 100 * i)), yaw: 35));
      }

      expect(v.completed, 0);
    });

    test('a weak smile is not a smile', () {
      final v = LivenessVerifier([LivenessChallenge.smile]);

      v.observe(good(at: t0));
      for (var i = 1; i <= 20; i++) {
        v.observe(
          good(at: t0.add(Duration(milliseconds: 100 * i)), smile: 0.45),
        );
      }

      expect(v.completed, 0);
    });
  });

  group('the challenges are chosen at random', () {
    test('different runs ask for different things in a different order', () {
      // A fixed order is a script, and a script is what a recorded video is
      // built to. Twenty draws from a seeded generator must not all be the
      // same sequence.
      final seen = <String>{};
      for (var seed = 0; seed < 20; seed++) {
        final v = LivenessVerifier.random(count: 3, random: Random(seed));
        seen.add(v.challenges.join(','));
      }

      expect(
        seen.length,
        greaterThan(1),
        reason: 'a fixed order would make this exactly 1',
      );
    });

    test('it asks for no more than exists, and never for none', () {
      for (var seed = 0; seed < 50; seed++) {
        final v = LivenessVerifier.random(count: 4, random: Random(seed));
        expect(v.challenges, hasLength(4));
        expect(
          v.challenges.toSet(),
          hasLength(4),
          reason: 'a challenge must not be asked for twice',
        );
      }
    });

    test('it never asks for a blink, because the app samples at 3Hz', () {
      // The app reads frames through InputImage.fromFilePath at about 3Hz,
      // and a blink lasts a few hundred milliseconds. Asking for one at that
      // rate would fail drivers who blinked perfectly, intermittently, with no
      // visible cause -- the worst kind of verification bug there is.
      for (var seed = 0; seed < 50; seed++) {
        final v = LivenessVerifier.random(count: 3, random: Random(seed));
        expect(
          v.challenges,
          isNot(contains(LivenessChallenge.blink)),
          reason: 'seed $seed asked for a blink at 3Hz',
        );
      }
    });

    test('the pool it draws from is five live challenges, not six', () {
      expect(liveCapableChallenges, hasLength(5));
      expect(liveCapableChallenges, isNot(contains(LivenessChallenge.blink)));
      // The verifier still supports a blink -- the tests above prove it judges
      // one correctly -- so raising the frame rate is a change to this list and
      // nothing else.
      expect(
        LivenessChallenge.values,
        hasLength(6),
        reason: 'blink stays supported, it is just not asked for',
      );
    });

    test('a verifier with no challenges is refused', () {
      // Rather than passing instantly, which is what an empty loop would do.
      expect(() => LivenessVerifier(const []), throwsA(isA<AssertionError>()));
    });
  });

  group('the camera has to actually be analysed', () {
    // Found on the device. The screen opened, the preview was live and
    // correct, the challenges were drawn at random, and the detector never
    // received a single frame -- because the readiness guard tested
    // `isStreamingImages`, which is only true *after* the call that starts the
    // stream. So a driver sat being asked to tilt their head by a check that
    // was not running, next to a message blaming the camera.
    //
    // A real `CameraController` cannot be built in a test, which is exactly
    // why the guard is a predicate rather than an inline condition. Every other
    // test in this file passed while this bug was live.
    test('readiness is initialised, not streaming', () {
      expect(LivenessSession.canStart(true), isTrue);
      expect(LivenessSession.canStart(false), isFalse);
    });

    test('a camera that is initialised is ready, streaming or not', () {
      // The bug, stated as the thing that must be true. If this ever goes back
      // to asking about streaming, it is false again and the check stops
      // running.
      expect(
        LivenessSession.canStart(true),
        isTrue,
        reason:
            'this is the state the controller is in immediately after '
            'initialize() and immediately before startImageStream()',
      );
    });
  });

  group(
    'progress is a real number so a driver can see they are nearly there',
    () {
      test('a partial turn shows partial progress', () {
        final v = LivenessVerifier([LivenessChallenge.turnLeft]);

        v.observe(good(at: t0));
        v.observe(
          good(at: t0.add(const Duration(milliseconds: 100)), yaw: -10),
        );

        // Halfway to the 20 degrees required, and shown as such rather than as
        // nothing happening.
        expect(v.progress, closeTo(0.5, 0.01));
      });

      test(
        'progress is clamped, so a wild angle does not overflow the ring',
        () {
          final v = LivenessVerifier([LivenessChallenge.turnLeft]);

          v.observe(good(at: t0));
          v.observe(
            good(at: t0.add(const Duration(milliseconds: 100)), yaw: -180),
          );

          expect(v.progress, 1.0);
        },
      );
    },
  );

  group('a replayed video cannot pass it either', () {
    // The gap the challenges leave open, and the one they cannot close.
    //
    // A short video of a real person, played at the camera, satisfies every
    // challenge perfectly: the head really does turn, the eyes really do open,
    // the smile really does appear. Nothing about the *motion* is wrong, so a
    // verifier that only looks at motion passes a recording. These tests are
    // the reason the anti-spoof model is in the check, and they are the only
    // place that claim is tested.

    /// Feeds a complete, flawless performance of [challenges].
    ///
    /// Every challenge met perfectly, on time, with a real mesh, and several
    /// centred frames before each one. This is what a replay looks like to the
    /// motion half of the verifier, and it is indistinguishable from a live
    /// driver doing exactly what they were asked.
    ///
    /// The centred frames are not padding. Without them a three-challenge run
    /// produces six frames and [kMinLiveSamples] is eight, so the live control
    /// below would fail on frame count rather than on anything to do with the
    /// model. A real driver spends a second or two per challenge, which is
    /// where the eight come from.
    LivenessVerifier flawless(
      List<LivenessChallenge> challenges, {
      required double Function(int frame) live,
      int framesPerChallenge = 5,
    }) {
      final v = LivenessVerifier(challenges);
      // 100ms per frame, faster than the 350ms the app samples at. Being
      // generous to the replay is the point: the test has to fail for a reason
      // to do with flatness, not with timing.
      var f = 0;
      DateTime at() => t0.add(Duration(milliseconds: 100 * f++));
      for (final c in challenges) {
        // Centred frames: the driver taking their time, and the challenge being
        // armed by the first of them.
        for (var i = 1; i < framesPerChallenge; i++) {
          v.observe(good(at: at(), live: live(f)));
        }
        // Then one that satisfies it, well past the threshold.
        v.observe(
          good(
            at: at(),
            yaw: c == LivenessChallenge.turnLeft ? -30 : 0,
            pitch: switch (c) {
              LivenessChallenge.tiltUp => 30,
              LivenessChallenge.tiltDown => -30,
              _ => 0,
            },
            smile: c == LivenessChallenge.smile ? 0.9 : 0.1,
            live: live(f),
          ),
        );
      }
      return v;
    }

    test('a video that does every challenge perfectly still fails', () {
      // Every frame called a flat surface, and there are enough frames for the
      // streak to reach its threshold before the last challenge can be met.
      // Three challenges, two frames each, so six spoof frames against a
      // threshold of four: the attempt is over at frame four with nothing
      // completed.
      //
      // The timing here is generous on purpose. If this failed because the
      // frames ran out rather than because the frames were flat, it would be
      // testing the sampling rate and not the model.
      final v = flawless(const [
        LivenessChallenge.turnLeft,
        LivenessChallenge.tiltUp,
        LivenessChallenge.smile,
      ], live: (_) => 0.05);

      expect(v.outcome, LivenessOutcome.spoofDetected);
      expect(v.completed, 0, reason: 'no challenge should have completed');
    });

    test('the same video passes once the model is satisfied', () {
      // The control, and the reason the first test is a real result rather than
      // a tautology. Identical motion, identical timing, and the only
      // difference is what the anti-spoof model said. A verifier that failed
      // this one for any reason other than flatness would be a check nobody
      // could pass.
      final v = flawless(const [
        LivenessChallenge.turnLeft,
        LivenessChallenge.tiltUp,
        LivenessChallenge.smile,
      ], live: (_) => 0.95);

      expect(v.outcome, LivenessOutcome.passed);
      expect(v.liveSamples, greaterThanOrEqualTo(kMinLiveSamples));
    });

    test('one spoof frame does not end a check', () {
      // A car going past a window, a hand across the lens, motion blur. A rule
      // that failed on the first mistake would fail real drivers, which is the
      // same as failing nobody at all.
      final v = LivenessVerifier([LivenessChallenge.turnLeft]);
      v.observe(good(at: t0, live: 0.9));
      // The mistimed frame arrives mid-turn, while the driver is genuinely
      // turning. It is discarded -- see the next test -- but the check carries
      // on rather than ending.
      v.observe(
        good(
          at: t0.add(const Duration(milliseconds: 100)),
          yaw: -15,
          live: 0.2,
        ),
      );

      expect(v.isOver, isFalse);
      expect(v.worstSpoofStreak, 1);
      expect(v.completed, 0);

      // And the turn still counts on the next frame, once the model is happy
      // again. The mistake cost a frame, not the attempt.
      v.observe(
        good(
          at: t0.add(const Duration(milliseconds: 200)),
          yaw: -30,
          live: 0.9,
        ),
      );
      expect(v.completed, 1);
    });

    test('but a run of them does', () {
      // Exactly the threshold, so the test fails if it is moved even by one.
      final v = LivenessVerifier([LivenessChallenge.turnLeft]);
      v.observe(good(at: t0, live: 0.9));
      for (var i = 0; i < kMaxSpoofSamples; i++) {
        v.observe(
          good(at: t0.add(Duration(milliseconds: 100 * (i + 1))), live: 0.1),
        );
      }

      expect(v.outcome, LivenessOutcome.spoofDetected);
    });

    test('a spoof frame cannot complete a challenge on its way out', () {
      // The subtle one. If the streak rule only ran at the end, the replay would
      // bank the first few challenges on its flat frames and then fail, which
      // is a different failure: the driver sees a progress bar fill and then
      // gets told off. Completing on a frame that is already known to be flat is
      // never right.
      final v = LivenessVerifier([LivenessChallenge.turnLeft]);
      v.observe(good(at: t0, live: 0.9));
      v.observe(
        good(
          at: t0.add(const Duration(milliseconds: 100)),
          yaw: -30,
          live: 0.1,
        ),
      );

      expect(v.completed, 0);
    });

    test('a scattered run of spoof frames is not a streak', () {
      // Five spoof frames across a check, never consecutive. A cumulative count
      // would fail this driver; a streak does not, and neither does a real
      // screen, which does not produce lucky frames.
      final v = LivenessVerifier([LivenessChallenge.turnLeft]);
      v.observe(good(at: t0, live: 0.9));
      for (var i = 0; i < kMaxSpoofSamples; i++) {
        v.observe(
          good(at: t0.add(Duration(milliseconds: 100 * (i + 1))), live: 0.2),
        );
        v.observe(
          good(at: t0.add(Duration(milliseconds: 100 * (i + 2))), live: 0.9),
        );
      }

      expect(v.isOver, isFalse);
      expect(v.worstSpoofStreak, 1);
    });
  });

  group('a check the model could not judge is not a pass', () {
    // The state a broken build produces, and the one that must never be allowed
    // to look like success. A liveness check that cannot confirm anybody is not
    // a liveness check, and a driver told "we could not confirm you" is being
    // told the truth about the app rather than about themselves.

    test('a null score is not a zero', () {
      final r = good(at: t0, live: null);

      expect(r.spoofScore, isNull);
      // The one that matters. A null must not read as a confident "spoof",
      // because that fails a driver over the model's silence.
      expect(r.looksSpoofed, isFalse);
      expect(r.looksLive, isFalse);
    });

    test('challenges met with no model output do not pass', () {
      final v = LivenessVerifier([LivenessChallenge.turnLeft]);
      v.observe(good(at: t0, live: null));
      v.observe(
        good(
          at: t0.add(const Duration(milliseconds: 100)),
          yaw: -30,
          live: null,
        ),
      );

      expect(v.outcome, LivenessOutcome.livenessUnproven);
      expect(v.liveSamples, 0);
    });

    test('a few live frames are not enough either', () {
      // The exact boundary, counting the frame that satisfies the challenge as
      // one of them, because it is: it is a frame the model judged. So
      // kMinLiveSamples - 2 centred frames plus the satisfying one lands on
      // exactly one short, and the check refuses.
      //
      // This is what stops a driver getting through on the handful of frames
      // where the model happened to have an opinion.
      final v = LivenessVerifier([LivenessChallenge.turnLeft]);
      var f = 0;
      for (var i = 0; i < kMinLiveSamples - 2; i++) {
        v.observe(
          good(at: t0.add(Duration(milliseconds: 100 * f++)), live: 0.9),
        );
      }
      v.observe(
        good(
          at: t0.add(Duration(milliseconds: 100 * f++)),
          yaw: -30,
          live: 0.9,
        ),
      );

      expect(v.liveSamples, kMinLiveSamples - 1);
      expect(v.completed, 1, reason: 'the challenge itself was satisfied');
      expect(v.outcome, LivenessOutcome.livenessUnproven);
    });

    test('and exactly the minimum does pass', () {
      // The other half of the boundary above, because a test that only checks
      // the refusing side cannot tell a correct threshold from one that is
      // simply too high and fails everyone.
      final v = LivenessVerifier([LivenessChallenge.turnLeft]);
      var f = 0;
      for (var i = 0; i < kMinLiveSamples - 1; i++) {
        v.observe(
          good(at: t0.add(Duration(milliseconds: 100 * f++)), live: 0.9),
        );
      }
      v.observe(
        good(
          at: t0.add(Duration(milliseconds: 100 * f++)),
          yaw: -30,
          live: 0.9,
        ),
      );

      expect(v.liveSamples, kMinLiveSamples);
      expect(v.outcome, LivenessOutcome.passed);
    });

    test('the model is asked about the frame, not about the driver', () {
      // Unscored frames are counted so the screen can say why. A driver whose
      // face is in shadow and a driver whose phone is broken need different
      // advice, and lumping them together gives them both the wrong one.
      final v = LivenessVerifier([LivenessChallenge.turnLeft]);
      v.observe(good(at: t0, live: null));
      v.observe(
        good(at: t0.add(const Duration(milliseconds: 100)), live: null),
      );

      expect(v.unscoredFrames, 2);
    });
  });

  group('the live threshold is the models own, not ours', () {
    test('at the threshold it is live', () {
      // Inclusive, matching the detector's own comparison. A reading of exactly
      // 0.5 is the model's decision boundary and a coin toss; the convention
      // chosen here is "live", and the test is what makes that a decision
      // rather than an accident.
      expect(good(at: t0, live: kLiveScoreThreshold).looksLive, isTrue);
    });

    test('just under it is not', () {
      expect(
        good(at: t0, live: kLiveScoreThreshold - 0.001).looksLive,
        isFalse,
      );
    });
  });
}
