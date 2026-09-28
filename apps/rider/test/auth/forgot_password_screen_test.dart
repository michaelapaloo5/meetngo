import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/auth/forgot_password_screen.dart';
import 'package:meetngo_rider/src/data/auth_repository.dart';
import 'package:provider/provider.dart';

class SpyAuthRepository implements AuthRepository {
  final sent = <String>[];
  String? failure;

  @override
  Future<void> sendResetOtp(String email) async {
    if (failure != null) throw AuthFailure(failure!);
    sent.add(email);
  }

  @override
  Future<void> signInWithPassword(String email, String password) async {}

  @override
  Future<void> signInWithGoogle() async {}

  @override
  Future<void> signUp(String email, String password, String fullName) async {}

  @override
  Future<void> verifyOtpAndSetPassword(String email, String code, String password) async {}
}

// `Provider`, not `ChangeNotifierProvider`: `AuthRepository` is not a
// `ChangeNotifier` (`ChangeNotifierProvider<T extends ChangeNotifier?>`), and
// the screen only ever does `context.read<AuthRepository>()`.
Widget wrap(SpyAuthRepository repo) => ScreenUtilInit(
      designSize: const Size(390, 844),
      builder: (_, _) => Provider<AuthRepository>.value(
        value: repo,
        child: const MaterialApp(home: ForgotPasswordScreen()),
      ),
    );

void main() {
  testWidgets('an empty address is refused without calling the repository', (tester) async {
    final repo = SpyAuthRepository();
    await tester.pumpWidget(wrap(repo));
    await tester.tap(find.byKey(const Key('sendCodeButton')));
    await tester.pump();
    expect(find.text('Enter the email on your account'), findsOneWidget);
    expect(repo.sent, isEmpty);
  });

  testWidgets('sending the code calls the repository and shows the check screen', (tester) async {
    final repo = SpyAuthRepository();
    await tester.pumpWidget(wrap(repo));
    await tester.enterText(find.byKey(const Key('emailField')), 'rider@example.com');
    await tester.tap(find.byKey(const Key('sendCodeButton')));
    await tester.pumpAndSettle();
    expect(repo.sent, ['rider@example.com']);
    expect(find.text('Check your email'), findsOneWidget);
  });

  testWidgets('a repository failure surfaces and does not claim a code was sent', (tester) async {
    final repo = SpyAuthRepository()..failure = 'No account for that address';
    await tester.pumpWidget(wrap(repo));
    await tester.enterText(find.byKey(const Key('emailField')), 'rider@example.com');
    await tester.tap(find.byKey(const Key('sendCodeButton')));
    await tester.pumpAndSettle();
    expect(find.text('No account for that address'), findsOneWidget);
    expect(find.text('Check your email'), findsNothing);
  });

  testWidgets('resend is disabled while the countdown runs and reopens when it ends', (tester) async {
    final repo = SpyAuthRepository();
    await tester.pumpWidget(wrap(repo));
    await tester.enterText(find.byKey(const Key('emailField')), 'rider@example.com');
    await tester.tap(find.byKey(const Key('sendCodeButton')));
    await tester.pumpAndSettle();

    final resend = tester.widget<TextButton>(find.byKey(const Key('resendButton')));
    expect(resend.onPressed, isNull);

    await tester.pump(const Duration(seconds: 30));
    final after = tester.widget<TextButton>(find.byKey(const Key('resendButton')));
    expect(after.onPressed, isNotNull);
  });
}
