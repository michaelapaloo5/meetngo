import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/auth/reset_password_screen.dart';
import 'package:meetngo_rider/src/data/auth_repository.dart';
import 'package:provider/provider.dart';

class RecordingAuthRepository implements AuthRepository {
  String? code;
  String? password;

  @override
  Future<void> verifyOtpAndSetPassword(String email, String code, String password) async {
    this.code = code;
    this.password = password;
  }

  @override
  Future<void> signInWithPassword(String email, String password) async {}

  @override
  Future<void> signInWithGoogle() async {}

  @override
  Future<void> signUp(String email, String password, String fullName) async {}

  @override
  Future<void> sendResetOtp(String email) async {}
}

// `Provider`, not `ChangeNotifierProvider`: `AuthRepository` is not a
// `ChangeNotifier` (`ChangeNotifierProvider<T extends ChangeNotifier?>`), and
// the screen only ever does `context.read<AuthRepository>()`.
Widget wrap(RecordingAuthRepository repo) => ScreenUtilInit(
      designSize: const Size(390, 844),
      builder: (_, _) => Provider<AuthRepository>.value(
        value: repo,
        child: const MaterialApp(home: ResetPasswordScreen(email: 'rider@example.com')),
      ),
    );

void main() {
  testWidgets('renders step two of three with the copy from the reference', (tester) async {
    await tester.pumpWidget(wrap(RecordingAuthRepository()));
    expect(find.text('Create new password'), findsOneWidget);
    expect(find.byKey(const Key('codeField')), findsOneWidget);
    // The step, by value and not just by count: `findsOneWidget` on the type is
    // satisfied by the first step's `0.33` as much as this step's `0.66`, so
    // it did not pin that this is the second of three.
    expect(find.text('2 of 3'), findsOneWidget);
    final indicator =
        tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    expect(indicator.value, closeTo(0.66, 0.0001));
  });

  testWidgets('code shorter than six digits blocks submit', (tester) async {
    final repo = RecordingAuthRepository();
    await tester.pumpWidget(wrap(repo));
    await tester.enterText(find.byKey(const Key('codeField')), '1338');
    await tester.enterText(find.byKey(const Key('newPasswordField')), 'secret123');
    await tester.enterText(find.byKey(const Key('confirmPasswordField')), 'secret123');
    await tester.tap(find.byKey(const Key('resetButton')));
    await tester.pump();
    expect(find.text('Enter the 6-digit code'), findsOneWidget);
    expect(repo.password, isNull);
  });

  testWidgets('password under six characters is rejected', (tester) async {
    final repo = RecordingAuthRepository();
    await tester.pumpWidget(wrap(repo));
    await tester.enterText(find.byKey(const Key('codeField')), '133870');
    await tester.enterText(find.byKey(const Key('newPasswordField')), 'abc12');
    await tester.enterText(find.byKey(const Key('confirmPasswordField')), 'abc12');
    await tester.tap(find.byKey(const Key('resetButton')));
    await tester.pump();
    expect(find.text('At least 6 characters'), findsOneWidget);
    expect(repo.password, isNull);
  });

  testWidgets('mismatched passwords block submit', (tester) async {
    final repo = RecordingAuthRepository();
    await tester.pumpWidget(wrap(repo));
    await tester.enterText(find.byKey(const Key('codeField')), '133870');
    await tester.enterText(find.byKey(const Key('newPasswordField')), 'abc123');
    await tester.enterText(find.byKey(const Key('confirmPasswordField')), 'abc124');
    await tester.tap(find.byKey(const Key('resetButton')));
    await tester.pump();
    expect(find.text('Passwords do not match'), findsOneWidget);
    expect(repo.password, isNull);
  });

  testWidgets('valid reset forwards the code and password', (tester) async {
    final repo = RecordingAuthRepository();
    await tester.pumpWidget(wrap(repo));
    await tester.enterText(find.byKey(const Key('codeField')), '133870');
    await tester.enterText(find.byKey(const Key('newPasswordField')), 'secret123');
    await tester.enterText(find.byKey(const Key('confirmPasswordField')), 'secret123');
    await tester.tap(find.byKey(const Key('resetButton')));
    await tester.pump();
    expect(repo.code, '133870');
    expect(repo.password, 'secret123');
  });

  testWidgets('a matching pair shows the green success state', (tester) async {
    await tester.pumpWidget(wrap(RecordingAuthRepository()));
    await tester.enterText(find.byKey(const Key('codeField')), '133870');
    await tester.enterText(find.byKey(const Key('newPasswordField')), 'secret123');
    await tester.enterText(find.byKey(const Key('confirmPasswordField')), 'secret123');
    await tester.tap(find.byKey(const Key('resetButton')));
    await tester.pumpAndSettle();
    expect(find.text('Password updated'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });

  testWidgets('the password ticks appear only once the rules hold', (tester) async {
    await tester.pumpWidget(wrap(RecordingAuthRepository()));
    expect(find.text('At least 6 characters'), findsNothing);
    expect(find.text('Passwords match'), findsNothing);

    await tester.enterText(find.byKey(const Key('newPasswordField')), 'abc12');
    await tester.pump();
    expect(find.text('At least 6 characters'), findsNothing);

    await tester.enterText(find.byKey(const Key('newPasswordField')), 'secret123');
    await tester.enterText(find.byKey(const Key('confirmPasswordField')), 'secret123');
    await tester.pump();
    expect(find.text('At least 6 characters'), findsOneWidget);
    expect(find.text('Passwords match'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('confirmPasswordField')), 'secret124');
    await tester.pump();
    expect(find.text('Passwords match'), findsNothing);
  });
}
