import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/auth/phone_gate_screen.dart';
import 'package:mng_core/mng_core.dart';
import 'package:meetngo_rider/src/data/profile_repository.dart';

/// A profile the test can change, standing in for the rider's own `profiles` row.
///
/// `save` applies the same rule the real repository does -- only `full_name` and
/// `phone` are writable -- so a test cannot pass by writing a column the database
/// would refuse.
class FakeProfileRepository implements ProfileRepository {
  FakeProfileRepository({this.phone = '', this.fullName = 'Edem Apaloo'});

  String phone;
  String fullName;

  bool readFails = false;
  bool saveFails = false;
  int saves = 0;

  /// True when a save is asked to write something the real repository would not.
  bool sawUnexpectedColumn = false;

  @override
  Future<RiderProfile?> me() async {
    if (readFails) throw Exception('network');
    return RiderProfile(id: 'p1', fullName: fullName, phone: phone, rating: 5.0, tripCount: 0, kyc: KycStatus.notStarted);
  }

  @override
  Future<RiderProfile?> save({
    required String fullName,
    required String phone,
  }) async {
    saves++;
    if (saveFails) throw Exception('network');
    this.fullName = fullName;
    this.phone = phone;
    return RiderProfile(id: 'p1', fullName: fullName, phone: phone, rating: 5.0, tripCount: 0, kyc: KycStatus.notStarted);
  }
}

Widget wrap(ProfileRepository repo, Widget child) => MaterialApp(
  home: PhoneGate(repository: repo, child: child),
);

void main() {
  group('a rider who already has a number', () {
    testWidgets('goes straight into the app', (tester) async {
      // The case that must never regress: adding a gate that catches everyone,
      // rather than the riders who need it.
      await tester.pumpWidget(
        wrap(FakeProfileRepository(phone: '0241234567'), const Text('the app')),
      );
      await tester.pumpAndSettle();

      expect(find.text('the app'), findsOneWidget);
      expect(find.byKey(const Key('phoneGateField')), findsNothing);
    });
  });

  group('a rider with no number', () {
    testWidgets('is asked for one before reaching the app', (tester) async {
      await tester.pumpWidget(
        wrap(FakeProfileRepository(), const Text('the app')),
      );
      await tester.pumpAndSettle();

      expect(find.text('the app'), findsNothing);
      expect(find.byKey(const Key('phoneGateField')), findsOneWidget);
      expect(
        find.text('So your driver can call you'),
        findsNothing,
        reason: 'that helper belongs to the signup form, not the gate',
      );
    });

    testWidgets('cannot be dismissed into the app', (tester) async {
      // A banner would be dismissible and the app would still be reachable. The
      // whole point is that the rider cannot book a trip nobody can reach them
      // about.
      await tester.pumpWidget(
        wrap(FakeProfileRepository(), const Text('the app')),
      );
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(200, 300));
      await tester.pumpAndSettle();
      expect(find.text('the app'), findsNothing);
    });

    testWidgets('a malformed number is refused', (tester) async {
      // Present but unusable is worse than absent: the driver dials it, or reads
      // it out to a stranger at a kerb. This is why the gate checks rather than
      // merely demanding.
      final repo = FakeProfileRepository();
      await tester.pumpWidget(wrap(repo, const Text('the app')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('phoneGateField')), '12345');
      await tester.tap(find.byKey(const Key('phoneGateSave')));
      await tester.pumpAndSettle();

      expect(repo.saves, 0, reason: 'nothing was written');
      expect(find.text('the app'), findsNothing);
      expect(
        find.textContaining('Ghanaian'),
        findsOneWidget,
        reason: 'and it says why rather than failing quietly',
      );
    });

    testWidgets('an empty number is refused', (tester) async {
      final repo = FakeProfileRepository();
      await tester.pumpWidget(wrap(repo, const Text('the app')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('phoneGateSave')));
      await tester.pumpAndSettle();

      expect(repo.saves, 0);
      expect(find.text('Enter your phone number'), findsOneWidget);
    });

    testWidgets('a good number is saved and the app appears', (tester) async {
      final repo = FakeProfileRepository();
      await tester.pumpWidget(wrap(repo, const Text('the app')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('phoneGateField')),
        '024 123 4567',
      );
      await tester.tap(find.byKey(const Key('phoneGateSave')));
      await tester.pumpAndSettle();

      expect(repo.saves, 1);
      expect(repo.phone, '024 123 4567');
      expect(
        find.text('the app'),
        findsOneWidget,
        reason: 'the gate gets out of the way on its own after a re-read',
      );
    });

    testWidgets('a save that fails says so and does not pretend', (
      tester,
    ) async {
      // The failure mode this whole class of screen exists to avoid: a save that
      // fails silently and a rider who believes they gave a number.
      final repo = FakeProfileRepository()..saveFails = true;
      await tester.pumpWidget(wrap(repo, const Text('the app')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('phoneGateField')),
        '0241234567',
      );
      await tester.tap(find.byKey(const Key('phoneGateSave')));
      await tester.pumpAndSettle();

      expect(find.text('the app'), findsNothing);
      expect(find.textContaining('could not save'), findsOneWidget);
    });

    testWidgets('a number the database rejects says so', (tester) async {
      // `save` returning null is the repository saying no. Treated as success it
      // would drop the rider back into the gate with no explanation.
      final repo = _NullSavingRepository();
      await tester.pumpWidget(wrap(repo, const Text('the app')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('phoneGateField')),
        '0241234567',
      );
      await tester.tap(find.byKey(const Key('phoneGateSave')));
      await tester.pumpAndSettle();

      expect(find.text('the app'), findsNothing);
      expect(find.textContaining('not saved'), findsOneWidget);
    });
  });

  group('a profile that cannot be read', () {
    testWidgets('asks for a number rather than letting the rider in', (
      tester,
    ) async {
      // Unknown is not the same as known-good. Letting somebody in on a failed
      // read is how a rider with no number ends up booking a trip.
      final repo = FakeProfileRepository(phone: '0241234567')..readFails = true;
      await tester.pumpWidget(wrap(repo, const Text('the app')));
      await tester.pumpAndSettle();

      expect(find.text('the app'), findsNothing);
      expect(find.byKey(const Key('phoneGateField')), findsOneWidget);
    });
  });
}

class _NullSavingRepository implements ProfileRepository {
  @override
  Future<RiderProfile?> me() async =>
      RiderProfile(id: 'p1', fullName: 'Edem Apaloo', phone: '', rating: 5.0, tripCount: 0, kyc: KycStatus.notStarted);

  @override
  Future<RiderProfile?> save({
    required String fullName,
    required String phone,
  }) async => null;
}
