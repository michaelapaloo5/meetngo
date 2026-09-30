import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

import 'liveness_session.dart';
import 'liveness_verifier.dart';

/// The face check, run on the phone.
///
/// A live camera preview with the current instruction over it and a ring that
/// fills as the driver gets there. The camera is in-app rather than handed to
/// the system camera app, and that is not a style choice: the system camera
/// gives back one photograph and nothing else, and a liveness check needs to
/// be *watching* a face move over a second or two. There is no way to do that
/// with `ACTION_IMAGE_CAPTURE`.
///
/// What this screen is careful not to do:
///
///  * Claim more than it checked. It says a live face was verified. It does
///    not say the face is the one on your licence, because that is a different
///    check and it is not happening here -- the frame goes to an admin beside
///    the licence photo for that.
///  * Fail silently. No camera, no permission, a driver holding a photograph
///    of themselves, a timeout: each has its own sentence, because "something
///    went wrong" on a screen someone is being asked to put their face in front
///    of is the worst possible thing to show.
class LivenessScreen extends StatefulWidget {
  const LivenessScreen({
    super.key,
    required this.onPassed,
    this.onCancelled,
  });

  /// Called with the frame to be uploaded, once the check passes.
  final Future<void> Function(File proof) onPassed;

  final VoidCallback? onCancelled;

  @override
  State<LivenessScreen> createState() => _LivenessScreenState();
}

class _LivenessScreenState extends State<LivenessScreen> {
  /// Three challenges, drawn at random from the six.
  ///
  /// A fixed order is a script, and a script is exactly what a recorded video
  /// is built to replay. Three is the shortest run that is not guessable from
  /// the first prompt and still short enough that a driver on a bad signal
  /// finishes it.
  static const int _challengeCount = 3;

  LivenessSession? _session;
  CameraController? _camera;
  List<CameraDescription> _cameras = const [];

  String? _error;
  bool _starting = true;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  Future<void> _boot() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() {
          _starting = false;
          _error = 'This phone has no camera the app can use.';
        });
        return;
      }
      // The front camera, always. A liveness check run on the back camera
      // cannot see the driver's face, and asking someone to turn the phone
      // around mid-check is a good way to lose them.
      final front = _cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => _cameras.first,
      );
      final controller = CameraController(
        front,
        // A small resolution on purpose. The pose and eye models run on a
        // downscaled frame anyway, and a 1080p stream on a budget phone costs
        // so much that the accurate-mode detector starves and the check times
        // out for reasons that have nothing to do with the driver.
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      _camera = controller;
      final session = LivenessSession(
        verifier: LivenessVerifier.random(
          count: _challengeCount,
          random: Random(),
        ),
      )..attach(controller);
      _session = session;
      await session.start();
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = session.error;
      });
      // Only once the camera and detector are both up, so the poller is never
      // running against a half-built session.
      _startPolling();
    } on CameraException catch (e) {
      // A denied permission arrives here, and it is the single most likely
      // reason this screen does not come up. "Camera access is needed" is
      // actionable; the platform's own code is not.
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = e.code == 'CameraAccessDenied'
            ? 'Meet \'N Go needs the camera to do this check. Turn it on in '
                'Settings, then try again.'
            : 'The camera could not be started. Try again.';
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = 'The camera could not be started. Try again.';
      });
    }
  }

  @override
  void dispose() {
    // Disposed rather than left running: an image stream and an ML Kit
    // detector left alive behind a popped screen is a camera that keeps the
    // indicator light on after the driver thinks they have stopped.
    unawaited(_session?.dispose());
    unawaited(_camera?.dispose());
    super.dispose();
  }

  Future<void> _retry() async {
    _poll?.cancel();
    setState(() {
      _starting = true;
      _error = null;
    });
    await _session?.dispose();
    await _camera?.dispose();
    _session = null;
    _camera = null;
    await _boot();
  }

  /// Rebuilds on a timer rather than on camera frames.
  ///
  /// The verifier advances on *analysed* frames, not captured ones, and the
  /// session analyses at 8Hz while the camera delivers 30. A screen that
  /// rebuilt per camera frame would animate progress the check had not made,
  /// and would burn battery doing it. 100ms is under the analysis interval, so
  /// no transition can be stepped over.
  Timer? _poll;

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
  }

  void _tick() {
    if (!mounted) return;
    final session = _session;
    if (session == null) return;

    // A passed check is finished with once, and the timer stops. Left running
    // it would call `onPassed` again on the next tick and upload the same face
    // a second time.
    if (session.verifier.outcome == LivenessOutcome.passed) {
      final proof = session.proofFrame;
      if (proof == null) {
        // Passed, but the still has not landed yet. It is taken
        // asynchronously, so this is a real state rather than a bug.
        setState(() {});
        return;
      }
      _poll?.cancel();
      setState(() => _finishing = true);
      unawaited(_finish(proof));
      return;
    }
    setState(() {
      _error = session.error ?? _sentenceFor(session.verifier.outcome);
    });
  }

  Future<void> _finish(File proof) async {
    try {
      await widget.onPassed(proof);
    } on Object {
      if (!mounted) return;
      setState(() {
        _finishing = false;
        _error = 'That photo could not be saved. Try the check again.';
      });
      // Back to watching, so a driver whose upload failed can simply go again
      // rather than being pushed out of the screen they were halfway through.
      _startPolling();
    }
  }

  /// What to say, per outcome.
  ///
  /// Each of these is a different instruction, and the difference is the whole
  /// reason this is a function rather than a single error string.
  String? _sentenceFor(LivenessOutcome outcome) => switch (outcome) {
        LivenessOutcome.notYet => null,
        LivenessOutcome.passed => null,
        LivenessOutcome.tooManyFaces =>
          'Only one face, please. Put any photograph you are holding away.',
        LivenessOutcome.noFace =>
          'We cannot see your face. Hold the phone in front of you, in the light.',
        LivenessOutcome.timedOut =>
          'That took too long. Tap to try that one again.',
        LivenessOutcome.gaveUp => 'Something went wrong. Tap to try again.',
      };

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final verifier = session?.verifier;
    final outcome = verifier?.outcome ?? LivenessOutcome.notYet;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: widget.onCancelled,
        ),
        title: const Text('Face check'),
      ),
      body: _starting
          ? const Center(
              child: CircularProgressIndicator(color: Colors.white),
            )
          : _camera == null
          ? _message(null, onRetry: _retry)
          : Stack(
              fit: StackFit.expand,
              children: [
                if (_finishing)
                  const ColoredBox(
                    color: Colors.black,
                    child: Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  )
                else
                  CameraPreview(_camera!),
                // A scrim behind the prompt only, so the driver's own face is
                // not hidden behind the very words telling them to move it.
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    width: double.infinity,
                    color: Colors.black.withValues(alpha: 0.55),
                    padding: EdgeInsets.fromLTRB(
                      20.w, 20.h, 20.w, 32.h,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (verifier != null)
                          _Progress(
                            done: verifier.completed,
                            total: verifier.total,
                            progress: verifier.progress,
                            failed: outcome != LivenessOutcome.notYet &&
                                outcome != LivenessOutcome.passed,
                          ),
                        SizedBox(height: 16.h),
                        Text(
                          _headline(verifier, outcome),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 6.h),
                        Text(
                          _subtitle(verifier, outcome),
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70),
                        ),
                        if (_error != null) ...[
                          SizedBox(height: 14.h),
                          GestureDetector(
                            key: const Key('livenessError'),
                            onTap: _retry,
                            child: Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: MngColors.error,
                                fontWeight: FontWeight.w600,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  String _headline(LivenessVerifier? v, LivenessOutcome outcome) {
    if (v == null) return 'Getting the camera ready';
    return switch (outcome) {
      LivenessOutcome.passed => 'That worked',
      LivenessOutcome.tooManyFaces => 'One face only',
      LivenessOutcome.noFace => 'We cannot see you',
      LivenessOutcome.timedOut => 'Too slow',
      LivenessOutcome.gaveUp => 'Something went wrong',
      LivenessOutcome.notYet => switch (v.current) {
        // Arming and performing are the same instruction to a driver. "Hold
        // still" and "now do the thing" alternating is a scrimbling nobody can
        // follow, and a driver who cannot tell which one they are being asked
        // to do will fail a check they are capable of passing.
        LivenessChallenge? c => c == null ? 'All done' : c.prompt,
      },
    };
  }

  String _subtitle(LivenessVerifier? v, LivenessOutcome outcome) {
    if (v == null) return 'One moment';
    if (outcome != LivenessOutcome.notYet) {
      return outcome == LivenessOutcome.passed
          ? 'One moment, saving your photo'
          : 'Tap the message to try again';
    }
    return v.current?.hint ?? '';
  }

  Widget _message(String? error, {VoidCallback? onRetry}) => Center(
    child: Padding(
      padding: EdgeInsets.all(28.w),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.face_retouching_natural,
              size: 48, color: Colors.white54),
          SizedBox(height: 16.h),
          Text(
            error ?? 'The face check is not available right now.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white),
          ),
          if (onRetry != null) ...[
            SizedBox(height: 20.h),
            FilledButton(
              key: const Key('livenessRetry'),
              onPressed: onRetry,
              child: const Text('Try again'),
            ),
          ],
        ],
      ),
    ),
  );
}

/// The dots and the ring.
class _Progress extends StatelessWidget {
  const _Progress({
    required this.done,
    required this.total,
    required this.progress,
    required this.failed,
  });

  final int done;
  final int total;
  final double progress;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // One dot per challenge, filled as it is met. Rather than "2 of 3" in
        // words, because a driver holding a phone at arm's length reads a row
        // of dots faster than they read a fraction.
        for (var i = 0; i < total; i++)
          Container(
            width: 10,
            height: 10,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i < done
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.35),
            ),
          ),
        SizedBox(width: 14.w),
        // The ring for the challenge in hand, so a driver who is nearly there
        // is told so rather than told nothing.
        SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(
            value: failed ? 1 : progress,
            strokeWidth: 3,
            backgroundColor: Colors.white24,
            valueColor: AlwaysStoppedAnimation(
              failed ? MngColors.error : Colors.white,
            ),
          ),
        ),
      ],
    );
  }
}
