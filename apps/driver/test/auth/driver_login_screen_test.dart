import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_driver/src/auth/driver_auth_controller.dart';
import 'package:meetngo_driver/src/auth/driver_login_screen.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

import '../support/fakes.dart';
import '../support/harness.dart';

Widget wrap(StubDriverAuthRepository repo) => ChangeNotifierProvider<
    DriverAuthController>.value(
  value: DriverAuthController(repo),
  child: const DriverLoginScreen(),
);

void main() {
  late StubDriverAuthRepository repo;

  setUp(() => repo = StubDriverAuthRepository());

  testWidgets('shows the heading, both fields and Google', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(appHarness(wrap(repo)));
    expect(find.text('Drive with us'), findsOneWidget);
    expect(find.text('Log in to go online and take rides.'), findsOneWidget);
    expect(find.byKey(const Key('emailField')), findsOneWidget);
    expect(find.byKey(const Key('passwordField')), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
  });

  testWidgets('no Apple Sign-In, in code or on screen', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(appHarness(wrap(repo)));
    expect(find.textContaining('Apple'), findsNothing);
    expect(find.textContaining('apple'), findsNothing);
    expect(find.byIcon(Icons.apple), findsNothing);
    // The buttons the screen does offer, so the assertion above is about the
    // absence of Apple rather than about the absence of sign-in options.
    expect(find.byKey(const Key('googleButton')), findsOneWidget);
    expect(find.byKey(const Key('loginButton')), findsOneWidget);
  });

  testWidgets('the login button is the amber primary', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(appHarness(wrap(repo)));
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('loginButton')),
    );
    // `FilledButton.style` is the constructor argument and nothing else, and
    // `DriverLoginScreen` passes none, so the effective style is the widget's
    // own or the theme above it.
    final element = tester.element(find.byKey(const Key('loginButton')));
    final style = button.style ?? Theme.of(element).filledButtonTheme.style!;
    expect(style.backgroundColor?.resolve({}), MngColors.primary);
  });

  testWidgets('an empty email is refused before the repository is called', (
    tester,
  ) async {
    useDesignSurface(tester);
    await tester.pumpWidget(appHarness(wrap(repo)));
    await tester.tap(find.byKey(const Key('loginButton')));
    await tester.pump();
    expect(find.text('Enter your email'), findsOneWidget);
    expect(repo.lastEmail, isNull);
  });

  testWidgets('an empty password is refused before the repository is called', (
    tester,
  ) async {
    useDesignSurface(tester);
    await tester.pumpWidget(appHarness(wrap(repo)));
    await tester.enterText(find.byKey(const Key('emailField')), 'd@example.com');
    await tester.tap(find.byKey(const Key('loginButton')));
    await tester.pump();
    expect(find.text('Enter your password'), findsOneWidget);
    expect(repo.lastPassword, isNull);
  });

  testWidgets('a valid submit forwards the credentials, trimmed', (
    tester,
  ) async {
    useDesignSurface(tester);
    await tester.pumpWidget(appHarness(wrap(repo)));
    await tester.enterText(
      find.byKey(const Key('emailField')),
      '  driver@example.com  ',
    );
    await tester.enterText(find.byKey(const Key('passwordField')), 'secret123');
    await tester.tap(find.byKey(const Key('loginButton')));
    await tester.pump();
    expect(repo.lastEmail, 'driver@example.com');
    expect(repo.lastPassword, 'secret123');
  });

  testWidgets('a rejected sign-in is shown, not thrown', (tester) async {
    useDesignSurface(tester);
    repo.failWith = 'Invalid login credentials';
    await tester.pumpWidget(appHarness(wrap(repo)));
    await tester.enterText(find.byKey(const Key('emailField')), 'd@example.com');
    await tester.enterText(find.byKey(const Key('passwordField')), 'wrongpass');
    await tester.tap(find.byKey(const Key('loginButton')));
    await tester.pump();
    expect(find.text('Invalid login credentials'), findsOneWidget);
  });

  testWidgets('the Google button delegates to the repository', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(appHarness(wrap(repo)));
    await tester.tap(find.byKey(const Key('googleButton')));
    await tester.pump();
    expect(repo.googlePressed, isTrue);
  });

  testWidgets('a failed Google launch is shown', (tester) async {
    useDesignSurface(tester);
    repo.failWith = 'Google sign-in could not start';
    await tester.pumpWidget(appHarness(wrap(repo)));
    await tester.tap(find.byKey(const Key('googleButton')));
    await tester.pump();
    expect(find.text('Google sign-in could not start'), findsOneWidget);
  });

  testWidgets('the password visibility toggles', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(appHarness(wrap(repo)));
    final before = tester.widget<TextField>(
      find.byKey(const Key('passwordField')),
    );
    expect(before.obscureText, isTrue);
    await tester.tap(find.byIcon(Icons.visibility_off));
    await tester.pump();
    final after = tester.widget<TextField>(
      find.byKey(const Key('passwordField')),
    );
    expect(after.obscureText, isFalse);
  });

  testWidgets('Forgot Password says the service is off, and claims no email', (
    tester,
  ) async {
    useDesignSurface(tester);
    await tester.pumpWidget(appHarness(wrap(repo)));
    expect(find.text('Forgot Password?'), findsOneWidget);
    // The tap, not just the label: the label is on screen whether or not the
    // GestureDetector under it still has a handler.
    await tester.tap(find.byKey(const Key('forgotPasswordLink')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('resetUnavailableDialog')), findsOneWidget);
    expect(find.textContaining('not switched on in this build'), findsOneWidget);
    // Nothing was sent, and the screen does not pretend otherwise.
    expect(find.textContaining('sent'), findsNothing);
    expect(find.byType(TextField), findsNWidgets(2));
  });

  testWidgets('the reset dialog closes', (tester) async {
    useDesignSurface(tester);
    await tester.pumpWidget(appHarness(wrap(repo)));
    await tester.tap(find.byKey(const Key('forgotPasswordLink')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('resetUnavailableDialog')), findsNothing);
  });

  testWidgets('the link, not the copy, is what opens the dialog', (
    tester,
  ) async {
    useDesignSurface(tester);
    await tester.pumpWidget(appHarness(wrap(repo)));
    await tester.tap(find.text('Forgot Password?'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('resetUnavailableDialog')), findsOneWidget);
  });
}
