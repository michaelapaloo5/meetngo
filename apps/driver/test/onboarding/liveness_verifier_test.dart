import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_driver/src/onboarding/liveness/face_reading.dart';
import 'package:meetngo_driver/src/onboarding/liveness/liveness_verifier.dart';

/// The liveness check, with no camera and no ML Kit.
///
/// Every case here is an attack or a failure mode, not a happy path. A liveness
/// check whose tests are "turn left, it goes green" proves that the code runs;
/// what matters is that a photograph, a second face, a missing measurement and
/// a sweep of the head all fail.
void main() {
  /// A well-behaved reading: one face, a real mesh, centred, eyes open.
  FaceReading good({
    required DateTime at,
    double yaw = 0,
    double pitch = 0,
    double? leftEye = 0.9,
    double? rightEye = 0.9,
    double? smile = 0.1,
    int faces = 1,
    int points = kMinContourPoints,
  }) =>
      FaceReading(
        at: at,
        faceCount: faces,
        yaw: yaw,
        pitch: pitch,
        leftEyeOpen: leftEye,
        rightEyeOpen: rightEye,
        smile: smile,
        contourPoints: points,
      );

  DateTime t0 = DateTime.utc(2026, 9, 29, 12);

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
      v.observe(good(at: t0.add(const Duration(milliseconds: 100)),
          leftEye: 0.05, rightEye: 0.05));

      expect(v.completed, 0,
          reason: 'eyes were never seen open, so this is not a blink');
    });

    test('a real blink counts, because the eyes open and then shut', () {
      final v = LivenessVerifier([LivenessChallenge.blink]);

      v.observe(good(at: t0));
      v.observe(good(at: t0.add(const Duration(milliseconds: 100))));
      v.observe(good(at: t0.add(const Duration(milliseconds: 200)),
          leftEye: 0.05, rightEye: 0.05));

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
    test('a head that jumps from one extreme to the other does not pass both',
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
      v.observe(good(at: t0.add(const Duration(milliseconds: 100)), yaw: -30));
      expect(v.completed, 1);
      v.observe(good(at: t0.add(const Duration(milliseconds: 200)), yaw: 35));
      v.observe(good(at: t0.add(const Duration(milliseconds: 300)), yaw: 40));
      v.observe(good(at: t0.add(const Duration(milliseconds: 400)), yaw: 38));

      expect(v.completed, 1,
          reason: 'the right turn was never armed, so holding right does '
              'nothing');
    });

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

      v.observe(good(at: t0));
      v.observe(good(at: t0.add(const Duration(milliseconds: 100)), yaw: -30));
      expect(v.completed, 1);
      v.observe(good(at: t0.add(const Duration(milliseconds: 200)), yaw: 30));
      expect(v.completed, 1, reason: 'not re-centred, so the right does not count');
      v.observe(good(at: t0.add(const Duration(milliseconds: 300))));
      v.observe(good(at: t0.add(const Duration(milliseconds: 400)), yaw: 30));
      expect(v.completed, 2);
      v.observe(good(at: t0.add(const Duration(milliseconds: 500))));
      v.observe(good(at: t0.add(const Duration(milliseconds: 600)), pitch: -25));
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
        v.observe(good(at: t0.add(Duration(milliseconds: 100 * i)), pitch: -30));
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
      up.observe(good(at: t0.add(const Duration(milliseconds: 100)), pitch: 30));
      expect(up.completed, 1);

      final down = LivenessVerifier([LivenessChallenge.tiltDown]);
      down.observe(good(at: t0));
      down.observe(good(at: t0.add(const Duration(milliseconds: 100)), pitch: -30));
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
        v.observe(FaceReading(
          at: t0.add(Duration(milliseconds: 100 * i)),
          faceCount: 1,
          // no yaw, no pitch: exactly what a fast-mode detector reports
          contourPoints: kMinContourPoints,
          leftEyeOpen: 0.9,
          rightEyeOpen: 0.9,
        ));
      }

      expect(v.completed, 0);
      expect(v.outcome, isNot(LivenessOutcome.passed));
    });

    test('a null smile cannot satisfy a smile', () {
      final v = LivenessVerifier([LivenessChallenge.smile]);

      v.observe(good(at: t0));
      for (var i = 1; i < 50; i++) {
        v.observe(FaceReading(
          at: t0.add(Duration(milliseconds: 100 * i)),
          faceCount: 1,
          contourPoints: kMinContourPoints,
          smile: null,
          leftEyeOpen: 0.9,
          rightEyeOpen: 0.9,
        ));
      }

      expect(v.completed, 0);
    });

    test('a null eye probability cannot satisfy a blink', () {
      final v = LivenessVerifier([LivenessChallenge.blink]);

      v.observe(good(at: t0));
      for (var i = 1; i < 50; i++) {
        v.observe(FaceReading(
          at: t0.add(Duration(milliseconds: 100 * i)),
          faceCount: 1,
          contourPoints: kMinContourPoints,
        ));
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

      v.observe(good(at: t0));
      v.observe(good(at: t0.add(const Duration(milliseconds: 100))));
      v.observe(good(at: t0.add(const Duration(milliseconds: 200)),
          leftEye: 0.05, rightEye: 0.05));
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
        v.observe(good(at: t0.add(Duration(milliseconds: 100 * i)), smile: 0.45));
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

      expect(seen.length, greaterThan(1),
          reason: 'a fixed order would make this exactly 1');
    });

    test('it asks for no more than exists, and never for none', () {
      for (var seed = 0; seed < 50; seed++) {
        final v = LivenessVerifier.random(count: 4, random: Random(seed));
        expect(v.challenges, hasLength(4));
        expect(v.challenges.toSet(), hasLength(4),
            reason: 'a challenge must not be asked for twice');
      }
    });

    test('a verifier with no challenges is refused', () {
      // Rather than passing instantly, which is what an empty loop would do.
      expect(() => LivenessVerifier(const []), throwsA(isA<AssertionError>()));
    });
  });

  group('progress is a real number so a driver can see they are nearly there', () {
    test('a partial turn shows partial progress', () {
      final v = LivenessVerifier([LivenessChallenge.turnLeft]);

      v.observe(good(at: t0));
      v.observe(good(at: t0.add(const Duration(milliseconds: 100)), yaw: -10));

      // Halfway to the 20 degrees required, and shown as such rather than as
      // nothing happening.
      expect(v.progress, closeTo(0.5, 0.01));
    });

    test('progress is clamped, so a wild angle does not overflow the ring', () {
      final v = LivenessVerifier([LivenessChallenge.turnLeft]);

      v.observe(good(at: t0));
      v.observe(good(at: t0.add(const Duration(milliseconds: 100)), yaw: -180));

      expect(v.progress, 1.0);
    });
  });
}
