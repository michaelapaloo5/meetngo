import 'dart:math';

import 'face_reading.dart';

/// One thing the driver is asked to do.
///
/// The set is chosen so that a printed photograph cannot satisfy any of them --
/// a photo has no head pose, no eyelids and no expression, so every challenge
/// here fails on a held-up picture. What they do *not* all defeat is a
/// pre-recorded video of a willing person, or a deepfake; that limit is real,
/// it is stated in [LivenessVerifier]'s docs, and it is why the captured frame
/// still goes to a human for comparison against the licence.
enum LivenessChallenge {
  turnLeft('Turn your head to the left', 'Keep your face in the circle'),
  turnRight('Turn your head to the right', 'Keep your face in the circle'),
  tiltUp('Tilt your head up', 'Keep your face in the circle'),
  tiltDown('Tilt your head down', 'Keep your face in the circle'),
  blink('Blink twice', 'Look at the camera the whole time'),
  smile('Smile', 'Look at the camera the whole time');

  const LivenessChallenge(this.prompt, this.hint);

  /// What the driver is told to do.
  final String prompt;

  /// The standing instruction under it.
  ///
  /// On every challenge rather than only some, because the two that look like
  /// they do not need it -- blink and smile -- are exactly the two where a
  /// driver moves their whole head out of frame to get better light, and then
  /// the detector loses the face and the check times out for no visible reason.
  final String hint;
}

/// The challenges the app actually asks for.
///
/// [LivenessChallenge.blink] is deliberately absent, and that is a decision
/// about this app's sample rate rather than about liveness.
///
/// The check samples the camera at about 3Hz, because a frame is analysed from
/// a still on disk rather than from a live buffer -- see `LivenessSession` for
/// why. A blink lasts a few hundred milliseconds, and a 3Hz sampler misses most
/// of them. The verifier can judge a blink correctly, and the tests prove it,
/// but *asking* for one at 3Hz would produce intermittent failures with no
/// visible cause: the driver blinked, the app did not see it, and the app told
/// them they had not.
///
/// The verifier still supports the challenge, so a faster frame source is a
/// one-line change here rather than a rewrite.
const List<LivenessChallenge> liveCapableChallenges = [
  LivenessChallenge.turnLeft,
  LivenessChallenge.turnRight,
  LivenessChallenge.tiltUp,
  LivenessChallenge.tiltDown,
  LivenessChallenge.smile,
];

/// Where the check has got to, and what it is waiting for.
///
/// Returned rather than held as internal flags, so the screen renders from one
/// value and there is no second copy of "are we done" to drift.
enum LivenessPhase {
  /// Nothing has been seen yet.
  waitingForFace,

  /// A face is there but the driver has not returned to centre, which is
  /// required before a challenge can count.
  waitingForCentre,

  /// A face is centred and the challenge is being looked for.
  performing,

  /// Every challenge was met.
  passed,

  /// The attempt is over and did not pass.
  failed,
}

/// The verdict, with the reason. A bool would throw away the only thing worth
/// telling the driver about why they have to do it again.
enum LivenessOutcome {
  notYet,
  passed,
  tooManyFaces,
  noFace,
  timedOut,

  /// The anti-spoof model called a flat surface too many times in a row.
  ///
  /// Its own outcome rather than a failure with no reason, because "that is a
  /// photograph" and "we could not see you" need different words and a driver
  /// told the wrong one stops trying.
  spoofDetected,

  /// Every challenge was met but the anti-spoof model was never given enough
  /// of a look at the face to reach a verdict.
  ///
  /// Not a pass and not an accusation. It is the only honest outcome when the
  /// model did not run, and it is the reason `assets/models/anti_spoof.tflite`
  /// has to be in the APK: a check that cannot judge is not a check.
  livenessUnproven,

  gaveUp,
}

/// Decides whether a live person is in front of the camera.
///
/// A pure state machine: readings in, one [LivenessPhase] and a progress number
/// out, and nothing else. No camera, no model, no clock of its own -- time
/// arrives on the reading, which is what makes every timeout in here testable in
/// microseconds instead of by waiting.
///
/// ## The two halves, and why both are needed
///
/// **The challenges** ask a single face to turn its head and smile, in an order
/// drawn at random. A printed photograph has no head pose and no expression, so
/// it satisfies none of them, and a driver holding up a picture of themselves is
/// caught by the face count because the detector reports their real face too.
///
/// **The anti-spoof model** looks at the pixels and asks whether what is in
/// front of the camera is a live face or a flat surface. This is what closes
/// the gap the challenges leave: a short video of a real person, played at the
/// camera, satisfies every challenge perfectly, and its pixels are exactly what
/// a small anti-spoofing network is trained to reject.
///
/// Neither is much alone. A random challenge script is defeated by a recording
/// covering all of them, and a 1.85 MB model is defeated by a very good
/// photograph held very still at a good angle. Together they are a check that
/// neither of those gets past, and both of them run on the driver's own phone
/// for no cost per check.
///
/// Neither verdict is instant, which is why the model is counted over the whole
/// attempt rather than required on any one frame. See [kMaxSpoofSamples] and
/// [kMinLiveSamples].
///
/// ## What this does and does not establish
///
/// It establishes that a single live face responded to randomised challenges,
/// and that the anti-spoof model was satisfied repeatedly while it happened.
///
/// It does not establish that the face belongs to the person on the Ghana Card
/// and the licence. That is a face *match*, it needs a face-embedding model,
/// and the honest position is that a bundled model on a budget Android phone in
/// a vehicle at night produces false rejects -- which block a real driver from
/// earning. So the frame goes to the admin page next to the licence photo and a
/// person makes that call, and this class is only ever the "is somebody real
/// here" half.
class LivenessVerifier {
  /// Builds a verifier over [challenges], or a random selection of them.
  ///
  /// The order and the selection are randomised, which is not decoration. A
  /// fixed order is a script: a video recorded once of somebody turning left,
  /// then right, then up would satisfy every run forever. Drawing three from
  /// [pool] means no single recording covers it.
  factory LivenessVerifier.random({
    required int count,
    required Random random,
    List<LivenessChallenge> pool = liveCapableChallenges,
  }) {
    final shuffled = pool.toList()..shuffle(random);
    return LivenessVerifier(shuffled.take(count).toList());
  }

  LivenessVerifier(this.challenges)
    : assert(challenges.isNotEmpty, 'a liveness check needs a challenge');

  /// The challenges, in the randomised order they will be asked for.
  final List<LivenessChallenge> challenges;

  int _index = 0;

  /// Whether the current challenge has seen the eyes open at some point.
  ///
  /// Only meaningful for [LivenessChallenge.blink]. Without it a face caught
  /// with its eyes already shut satisfies the challenge, which is a driver
  /// looking at the screen between two normal blinks.
  bool _sawEyesOpen = false;

  DateTime? _armedAt;
  DateTime? _lastSeenAt;
  LivenessOutcome _outcome = LivenessOutcome.notYet;

  double? _lastYaw;
  double? _lastPitch;
  double? _lastSmile;

  /// How many frames the anti-spoof model called live.
  ///
  /// Counted over the whole attempt rather than required on any one frame,
  /// because the model is a small network reading an 80x80 crop and it is wrong
  /// often enough that a single frame proves nothing in either direction. A live
  /// driver in a moving car gets a handful of wrong verdicts; a screen gets the
  /// same handful and nothing but wrong ones.
  int _liveSamples = 0;

  /// How many frames the anti-spoof model called a flat surface.
  ///
  /// Consecutive, not cumulative. A cumulative count would fail a driver who
  /// turned their phone towards a window over the course of a check, which is
  /// the kind of ordinary accident that loses a real driver their onboarding.
  /// A phone screen does not produce one lucky frame in ten.
  int _spoofStreak = 0;

  /// The most consecutive spoof verdicts seen, for the screen to explain a
  /// failure with.
  int _worstSpoofStreak = 0;

  /// How many frames the model declined to judge at all.
  ///
  /// Tracked so the failure message can tell a driver whose face is too dark
  /// from one whose phone is misbehaving. The two need different advice and
  /// lumping them together produces the worst of both.
  int _unscoredFrames = 0;

  /// The challenge being asked for, or null once the check is over.
  LivenessChallenge? get current =>
      (_index < challenges.length) ? challenges[_index] : null;

  /// How many challenges have been met.
  int get completed => _index;

  /// How many there are in total.
  int get total => challenges.length;

  LivenessOutcome get outcome => _outcome;

  /// Whether the attempt is finished, either way.
  ///
  /// "Any outcome but not-yet" rather than "passed or gave up", because
  /// [LivenessOutcome] names the specific reasons -- too many faces, no face,
  /// timed out -- and those are all over too. Testing for two of the five would
  /// have let a rejected check keep evaluating, and the screen would sit on a
  /// failure while the camera kept sending it samples.
  bool get isOver => _outcome != LivenessOutcome.notYet;

  /// Fraction of this challenge that is satisfied, 0 to 1.
  ///
  /// Drives the ring under the prompt. It is a real number rather than a bool
  /// because a head turn of 6 degrees out of the required 20 is visibly closer
  /// than one of 1, and a driver who is nearly there should be told so rather
  /// than told nothing.
  double get progress {
    final challenge = current;
    if (challenge == null) return 1.0;
    switch (challenge) {
      case LivenessChallenge.turnLeft:
      case LivenessChallenge.turnRight:
        final yaw = _lastYaw;
        if (yaw == null) return 0.0;
        return (yaw.abs() / kTurnDegrees).clamp(0.0, 1.0);
      case LivenessChallenge.tiltUp:
      case LivenessChallenge.tiltDown:
        final pitch = _lastPitch;
        if (pitch == null) return 0.0;
        return (pitch.abs() / kTiltDegrees).clamp(0.0, 1.0);
      case LivenessChallenge.blink:
        return _sawEyesOpen ? 0.5 : 0.0;
      case LivenessChallenge.smile:
        final smile = _lastSmile;
        if (smile == null) return 0.0;
        return (smile / kSmileThreshold).clamp(0.0, 1.0);
    }
  }

  /// How many frames the anti-spoof model has called live.
  int get liveSamples => _liveSamples;

  /// The longest run of consecutive spoof verdicts seen so far.
  int get worstSpoofStreak => _worstSpoofStreak;

  /// How many frames the model could not judge.
  int get unscoredFrames => _unscoredFrames;

  /// Feeds one frame in and returns where the check now stands.
  ///
  /// Ordering inside this method is the whole of the check, and it is
  /// deliberate: face count, then mesh, then the anti-spoof streak, then
  /// timing, then the challenge. A frame with two faces never advances a
  /// challenge however much of the challenge it happens to satisfy, and a frame
  /// the anti-spoof model has just called a flat surface never advances one
  /// either.
  LivenessPhase observe(FaceReading reading) {
    if (isOver) return _phase;

    _lastYaw = reading.yaw;
    _lastPitch = reading.pitch;
    _lastSmile = reading.smile;

    // Nothing to measure on nobody. The face must also have a mesh, because a
    // detection without one came from a configuration that will never produce
    // head pose and asking for a head turn on it is a check that can only time
    // out.
    if (!reading.hasOneFace || reading.contourPoints < kMinContourPoints) {
      // A second face is a different failure from an empty frame, and the
      // driver needs to hear the difference: one is "put the photo down", the
      // other is "come closer".
      if (reading.faceCount > 1) {
        _outcome = LivenessOutcome.tooManyFaces;
        return LivenessPhase.failed;
      }
      _outcome = LivenessOutcome.noFace;
      return LivenessPhase.failed;
    }

    _lastSeenAt = reading.at;

    // The anti-spoof verdict is counted before anything else this frame is
    // allowed to do, so a spoof cannot advance a challenge on its way to
    // failing. A screen playing back a recording of somebody turning their head
    // would otherwise complete every challenge and only be caught afterwards.
    final score = reading.spoofScore;
    if (score == null) {
      _unscoredFrames++;
      _spoofStreak = 0;
    } else if (score >= kLiveScoreThreshold) {
      _liveSamples++;
      _spoofStreak = 0;
    } else {
      _spoofStreak++;
      if (_spoofStreak > _worstSpoofStreak) _worstSpoofStreak = _spoofStreak;
      if (_spoofStreak >= kMaxSpoofSamples) {
        _outcome = LivenessOutcome.spoofDetected;
        return LivenessPhase.failed;
      }
    }

    // Arming. A challenge is only armed by a frame where the head is near
    // centre, and from then on the head is free to go wherever the challenge
    // asks it to.
    //
    // The separation is the whole of the re-centre rule, and getting it wrong
    // deadlocks the check: centring checked on the same frame as the challenge
    // means a head turn can never register, because performing the turn is
    // exactly what takes the head off centre. Checked here instead, it both
    // lets a turn count and still stops one sweep of the head from satisfying
    // three challenges in three consecutive frames -- because finishing a
    // challenge clears the arm, and the next has to wait for another centred
    // frame.
    if (_armedAt == null) {
      if (_centred(reading)) _armedAt = reading.at;
      return LivenessPhase.waitingForCentre;
    }

    final challenge = current;
    if (challenge == null) return _phase;

    if (reading.at.difference(_armedAt!) > kChallengeTimeout) {
      _outcome = LivenessOutcome.timedOut;
      return LivenessPhase.failed;
    }

    if (_met(challenge, reading)) {
      _index++;
      _sawEyesOpen = false;
      _armedAt = null;
      if (_index >= challenges.length) {
        // Every challenge met is not yet a pass. The anti-spoof model has to
        // have had enough of a look to agree, and this is where that is
        // enforced.
        //
        // Failing here rather than at the end of the session matters for a
        // driver who never gets a verdict: with this rule the check reports
        // "the face check could not confirm you are real" instead of
        // completing and then failing on the way to the server, which is the
        // same message arriving after they have already been told they passed.
        if (_liveSamples < kMinLiveSamples) {
          _outcome = LivenessOutcome.livenessUnproven;
          return LivenessPhase.failed;
        }
        _outcome = LivenessOutcome.passed;
        return LivenessPhase.passed;
      }
      // The next challenge is not armed yet. Returning to centre between
      // challenges is the same rule applied again one step later.
      return LivenessPhase.waitingForCentre;
    }

    return LivenessPhase.performing;
  }

  /// Whether a frame satisfies the challenge being asked for.
  ///
  /// Gated on [_countable] first, so a frame from a flat surface completes
  /// nothing even while the streak against it is still below the failure
  /// threshold.
  bool _met(LivenessChallenge challenge, FaceReading reading) {
    if (!_countable(reading)) return false;
    return switch (challenge) {
      LivenessChallenge.turnLeft => _yawPast(reading, -kTurnDegrees),
      LivenessChallenge.turnRight => _yawPast(reading, kTurnDegrees),
      // Positive pitch is looking up, which is the convention on
      // `headEulerAngleX` and the one `face_detection_tflite` documents it
      // matches. These two were the wrong way round at first, and the tests
      // caught it: a driver tilting down was asked to tilt up and could not do
      // it in under any circumstances, which reads on a phone as "this check is
      // broken" rather than as "you did it wrong".
      LivenessChallenge.tiltUp => _pitchPast(reading, kTiltDegrees),
      LivenessChallenge.tiltDown => _pitchPast(reading, -kTiltDegrees),
      // Both halves required, and in that order within the same challenge.
      LivenessChallenge.blink => () {
        if (reading.eyesOpen) _sawEyesOpen = true;
        return _sawEyesOpen && reading.eyesShut;
      }(),
      LivenessChallenge.smile => (reading.smile ?? 0) > kSmileThreshold,
    };
  }

  bool _yawPast(FaceReading reading, double threshold) {
    final yaw = reading.yaw;
    // A null yaw is not a zero yaw. Fast mode does not compute it, and a head
    // that "passed" for turning left when the angle was never measured is the
    // one failure this whole class exists to prevent.
    if (yaw == null) return false;
    return threshold > 0 ? yaw >= threshold : yaw <= threshold;
  }

  bool _pitchPast(FaceReading reading, double threshold) {
    final pitch = reading.pitch;
    if (pitch == null) return false;
    return threshold > 0 ? pitch >= threshold : pitch <= threshold;
  }

  /// Whether a frame is good enough to count towards completing a challenge.
  ///
  /// A frame the anti-spoof model has just called a flat surface is excluded
  /// here as well as being counted towards the failure, so a screen cannot
  /// complete a challenge on the frames that are about to fail the attempt. A
  /// live driver is never excluded: the gate below is only on an outright
  /// spoof verdict, and a wrong one of those resets the streak rather than
  /// ending the check.
  bool _countable(FaceReading reading) => !reading.looksSpoofed;

  /// Whether the head is near enough to centre for a challenge to count.
  bool _centred(FaceReading reading) {
    final yaw = reading.yaw;
    final pitch = reading.pitch;
    // Before the first challenge, and while a head-turn is outstanding, the
    // centre has to be judged on both axes. When a tilt is the challenge, a
    // driver holding their head up to satisfy it is legitimately off-centre
    // on pitch, so centring is judged on the axis that challenge does not use.
    final yawOk = yaw == null || yaw.abs() <= kCentreDegrees;
    switch (current) {
      case LivenessChallenge.tiltUp:
      case LivenessChallenge.tiltDown:
        return yawOk;
      case null:
      case LivenessChallenge.turnLeft:
      case LivenessChallenge.turnRight:
      case LivenessChallenge.blink:
      case LivenessChallenge.smile:
        final pitchOk = pitch == null || pitch.abs() <= kCentreDegrees;
        return yawOk && pitchOk;
    }
  }

  LivenessPhase get _phase {
    if (_outcome == LivenessOutcome.passed) return LivenessPhase.passed;
    if (_outcome != LivenessOutcome.notYet) return LivenessPhase.failed;
    if (_lastSeenAt == null) return LivenessPhase.waitingForFace;
    return LivenessPhase.performing;
  }
}

/// Degrees of head turn that count as turning it.
///
/// Twenty is chosen to be comfortably inside what any adult can do without
/// strain, so nobody is failed for their range of movement, while being far
/// beyond the few degrees of jitter a held photograph produces.
const double kTurnDegrees = 20.0;

/// Degrees of head tilt that count as tilting it.
const double kTiltDegrees = 18.0;

/// How near to centre the head must be for a challenge to count.
const double kCentreDegrees = 8.0;

/// Smile probability that counts as a smile.
const double kSmileThreshold = 0.6;

/// How long one challenge may take before the attempt is over.
///
/// Twelve seconds at a 3Hz sample rate is about 36 looks at the face, which
/// is ample for a head turn and generous for a slow one. It is measured from
/// the moment the challenge was armed, not from the last frame, so a driver who
/// puts the phone down mid-check is told rather than left hanging.
const Duration kChallengeTimeout = Duration(seconds: 12);

/// The fewest contour points a usable detection has.
///
/// MediaPipe's face oval is 36 points and is `null` in fast mode. The threshold
/// is far below 36 rather than equal to it, because the number is here as
/// evidence that a mesh was computed at all rather than as a check on a
/// detector's internals: what matters is that it is not zero. A detector wired
/// up in fast mode then fails on the first frame with one clear message, instead
/// of every driver being asked to turn their head for a model that was never
/// going to answer.
const int kMinContourPoints = 12;

/// How many consecutive spoof verdicts end the attempt.
///
/// Four, out of roughly 36 frames in a check of three challenges. A live driver
/// is sometimes read wrong -- a hand passing in front of the lens, a window
/// behind them, motion blur -- and a rule that failed on the first mistake
/// would be a rule that fails drivers in cars, which is where this runs. A
/// phone screen does not produce one lucky frame in nine.
const int kMaxSpoofSamples = 4;

/// How many live verdicts the model must reach before the check can pass.
///
/// Eight, out of a check that yields about 36 usable frames. This is the other
/// half of the arrangement with [kMaxSpoofSamples]: the model has to have
/// actually looked and agreed, rather than the challenges passing on a handful
/// of frames where it had nothing to say. When it has not, the outcome is
/// [LivenessOutcome.livenessUnproven] and the driver is told the check could
/// not confirm them, which is true, rather than being failed for it.
const int kMinLiveSamples = 8;
