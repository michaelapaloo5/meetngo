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
      expect(
        canTransition(s, TripState.cancelled),
        isTrue,
        reason: '$s must be cancellable',
      );
    }
    expect(canTransition(TripState.ongoing, TripState.cancelled), isFalse);
    expect(canTransition(TripState.completed, TripState.cancelled), isFalse);
  });

  test('terminal states are terminal', () {
    for (final terminal in [TripState.completed, TripState.cancelled]) {
      for (final target in TripState.values) {
        expect(
          canTransition(terminal, target),
          isFalse,
          reason: '$terminal -> $target',
        );
      }
    }
  });

  test('no skipping ahead and no self-transitions', () {
    expect(canTransition(TripState.requested, TripState.ongoing), isFalse);
    expect(canTransition(TripState.matched, TripState.completed), isFalse);
    expect(canTransition(TripState.requested, TripState.requested), isFalse);
  });

  test('a driver can put an arriving trip back in the pool', () {
    // The one backwards move. `leave-trip` performs it, so a client that refuses
    // it would leave the driver with a button that cannot work.
    expect(canTransition(TripState.arriving, TripState.requested), isTrue);
    // Declining before moving is `offers/decline`, and must not arrive here.
    expect(canTransition(TripState.matched, TripState.requested), isFalse);
    expect(canTransition(TripState.ongoing, TripState.requested), isFalse);
  });

  test('all 36 ordered pairs agree with the eight legal pairs', () {
    const legal = <(TripState, TripState)>{
      (TripState.requested, TripState.matched),
      (TripState.requested, TripState.cancelled),
      (TripState.matched, TripState.arriving),
      (TripState.matched, TripState.cancelled),
      (TripState.arriving, TripState.ongoing),
      (TripState.arriving, TripState.cancelled),
      (TripState.arriving, TripState.requested),
      (TripState.ongoing, TripState.completed),
    };
    expect(legal, hasLength(8), reason: 'the legal set must stay at 8 pairs');

    final mismatches = <String>[];
    for (final from in TripState.values) {
      for (final to in TripState.values) {
        final want = legal.contains((from, to));
        final got = canTransition(from, to);
        if (got != want) {
          mismatches.add('canTransition($from, $to) is $got, want $want');
        }
      }
    }
    expect(
      mismatches,
      isEmpty,
      reason:
          'illegal transition table: ${mismatches.length} of '
          '${TripState.values.length * TripState.values.length} ordered pairs '
          'disagree with the legal set above',
    );
  });

  test('nextState returns the target for a legal move', () {
    expect(
      nextState(TripState.requested, TripState.matched),
      TripState.matched,
    );
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

  test('isTerminal covers completed and cancelled only', () {
    expect(TripState.requested.isTerminal, isFalse);
    expect(TripState.matched.isTerminal, isFalse);
    expect(TripState.arriving.isTerminal, isFalse);
    expect(TripState.ongoing.isTerminal, isFalse);
    expect(TripState.completed.isTerminal, isTrue);
    expect(TripState.cancelled.isTerminal, isTrue);
  });
}
