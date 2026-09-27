import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';

void main() {
  test('happy path walks requested to completed', () {
    expect(canTransition(TripState.requested, TripState.matched), isTrue);
    expect(canTransition(TripState.matched, TripState.arriving), isTrue);
    expect(canTransition(TripState.arriving, TripState.ongoing), isTrue);
    expect(canTransition(TripState.ongoing, TripState.completed), isTrue);
  });

  test('cancel is legal from requested, matched and arriving only', () {
    for (final s in [
      TripState.requested,
      TripState.matched,
      TripState.arriving,
    ]) {
      expect(canTransition(s, TripState.cancelled), isTrue,
          reason: '$s must be cancellable');
    }
    expect(canTransition(TripState.ongoing, TripState.cancelled), isFalse);
    expect(canTransition(TripState.completed, TripState.cancelled), isFalse);
  });

  test('terminal states are terminal', () {
    for (final terminal in [TripState.completed, TripState.cancelled]) {
      for (final target in TripState.values) {
        expect(canTransition(terminal, target), isFalse,
            reason: '$terminal -> $target');
      }
    }
  });

  test('no skipping ahead and no self-transitions', () {
    expect(canTransition(TripState.requested, TripState.ongoing), isFalse);
    expect(canTransition(TripState.matched, TripState.completed), isFalse);
    expect(canTransition(TripState.requested, TripState.requested), isFalse);
  });

  test('nextState returns the target for a legal move', () {
    expect(nextState(TripState.requested, TripState.matched), TripState.matched);
  });

  test('nextState throws IllegalTripTransition on an illegal move', () {
    expect(
      () => nextState(TripState.completed, TripState.ongoing),
      throwsA(
        isA<IllegalTripTransition>()
            .having((e) => e.from, 'from', TripState.completed)
            .having((e) => e.to, 'to', TripState.ongoing),
      ),
    );
  });

  test('isActive covers the four in-progress states', () {
    expect(TripState.requested.isActive, isTrue);
    expect(TripState.matched.isActive, isTrue);
    expect(TripState.arriving.isActive, isTrue);
    expect(TripState.ongoing.isActive, isTrue);
    expect(TripState.completed.isActive, isFalse);
    expect(TripState.cancelled.isActive, isFalse);
  });
}
