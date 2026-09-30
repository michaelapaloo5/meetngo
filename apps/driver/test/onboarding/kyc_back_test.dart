import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_driver/src/onboarding/kyc_controller.dart';

import '../support/fakes.dart';

/// The verification wizard has to be walkable in both directions.
///
/// This exists because it was not, and nothing noticed. `KycController.back()`
/// was written, correct, and never called by anything -- so a driver who
/// reached the review step with a document they wanted to retake had no way
/// back to the list, and the only route forward was into submitting the
/// application they did not want to submit.
///
/// The failure is invisible to a test that only walks forwards, which is how
/// every existing test in this directory was written.
void main() {
  /// A controller parked on [step], with a repository that is never asked
  /// anything.
  ///
  /// `load` is never called, so nothing here touches the network: `back()` is
  /// pure state and that is the whole of what is under test.
  KycController controllerAt(KycStep step) =>
      KycController(StubDriverRepository())..step = step;

  group('back', () {
    test('moves to the previous step', () {
      final c = controllerAt(KycStep.review);

      c.back();

      expect(c.step, KycStep.vehicle);
    });

    test('walks all the way back to the document list', () {
      // The case that motivated the fix: a driver who has finished and wants
      // to retake a document.
      final c = controllerAt(KycStep.review);

      for (var i = 0; i < 5; i++) {
        c.back();
      }

      expect(c.step, KycStep.documents);
    });

    test('does nothing on the first step', () {
      // Not a crash and not a wrap round to the last step, which is what a bare
      // index decrement would do.
      final c = controllerAt(KycStep.documents);

      c.back();
      c.back();

      expect(c.step, KycStep.documents);
    });

    test('does nothing once the application is with an admin', () {
      // These are states the driver is told about, not a form. An arrow here
      // would suggest they could un-submit, which they cannot.
      for (final step in [KycStep.underReview, KycStep.approved]) {
        final c = controllerAt(step);
        c.back();
        expect(c.step, step, reason: 'must not leave $step');
      }
    });

    test('clears the error, so a stale message does not follow them back', () {
      final c = controllerAt(KycStep.review);
      c.error = 'Something went wrong';

      c.back();

      expect(c.error, isNull);
    });
  });
}
