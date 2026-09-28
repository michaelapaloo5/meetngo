import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/auth/auth_controller.dart';
import 'package:meetngo_rider/src/auth/forgot_password_screen.dart';
import 'package:meetngo_rider/src/auth/login_screen.dart';
import 'package:meetngo_rider/src/data/auth_repository.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

class FakeAuthRepository implements AuthRepository {
  String? lastEmail;
  String? lastPassword;
  bool googlePressed = false;
  bool failWith = false;
  String? signUpEmail;
  String? signUpName;

  @override
  Future<void> signInWithPassword(String email, String password) async {
    lastEmail = email;
    lastPassword = password;
    if (failWith) throw const AuthFailure('Incorrect email or password');
  }

  @override
  Future<void> signInWithGoogle() async => googlePressed = true;

  @override
  Future<void> signUp(String email, String password, String fullName) async {
    signUpEmail = email;
    signUpName = fullName;
    if (failWith) throw const AuthFailure('User already registered');
  }

  @override
  Future<void> sendResetOtp(String email) async {}

  @override
  Future<void> verifyOtpAndSetPassword(String email, String code, String password) async {}
}

/// Puts the test surface at the app's design size.
///
/// `flutter test` defaults to 800x600, where `.w` scales by 2.05 and `.h` by
/// 0.525, so the entrance transforms in [LoginScreen] displace widgets far
/// enough that a `tap` lands where nothing is hit-tested. 1170x2532 at dpr 3.0
/// is a logical 390x844, which is the regime the app ships in.
void useDesignSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

Widget wrap(FakeAuthRepository repo) => ScreenUtilInit(
      designSize: const Size(390, 844),
      minTextAdapt: true,
      builder: (_, _) => ChangeNotifierProvider<AuthController>.value(
        value: AuthController(repo),
        // The app theme is what paints the login button amber, so the harness
        // has to carry it. A bare `MaterialApp` leaves the button on the
        // Material default and any colour assertion in here is vacuous. Not
        // `const`: `MngTheme.light` is a `static final` getter, not a constant.
        child: MaterialApp(theme: MngTheme.light, home: const LoginScreen()),
      ),
    );

void main() {
  late FakeAuthRepository repo;

  setUp(() => repo = FakeAuthRepository());

  testWidgets('shows heading, fields, and no Apple button', (tester) async {

    useDesignSurface(tester);    await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();
    expect(find.text('Welcome Back'), findsOneWidget);
    expect(find.text('Login to book a ride in seconds.'), findsOneWidget);
    expect(find.byKey(const Key('emailField')), findsOneWidget);
    expect(find.byKey(const Key('passwordField')), findsOneWidget);
    expect(find.textContaining('Apple'), findsNothing);
    expect(find.text('Continue with Google'), findsOneWidget);
  });

  testWidgets('login button uses the amber primary', (tester) async {

    useDesignSurface(tester);    await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();
    final button = tester.widget<FilledButton>(find.byKey(const Key('loginButton')));
    // `FilledButton.style` is the constructor argument and nothing else
    // (`button_style_button.dart:139`), and `LoginScreen` passes none: the
    // amber comes from `MngTheme.light.filledButtonTheme`. So the effective
    // style is the widget's own, else the theme above it.
    final element = tester.element(find.byKey(const Key('loginButton')));
    final style = button.style ?? Theme.of(element).filledButtonTheme.style!;
    expect(style.backgroundColor?.resolve({}), MngColors.primary);
  });

  testWidgets('empty email shows validation and does not call the repository', (tester) async {

    useDesignSurface(tester);    await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('loginButton')));
    await tester.pump();
    expect(find.text('Enter your email'), findsOneWidget);
    expect(repo.lastEmail, isNull);
  });

  testWidgets('empty password shows validation', (tester) async {

    useDesignSurface(tester);    await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('emailField')), 'rider@example.com');
    await tester.tap(find.byKey(const Key('loginButton')));
    await tester.pump();
    expect(find.text('Enter your password'), findsOneWidget);
    expect(repo.lastPassword, isNull);
  });

  testWidgets('valid submit forwards credentials', (tester) async {

    useDesignSurface(tester);    await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('emailField')), 'rider@example.com');
    await tester.enterText(find.byKey(const Key('passwordField')), 'secret123');
    await tester.tap(find.byKey(const Key('loginButton')));
    await tester.pump();
    expect(repo.lastEmail, 'rider@example.com');
    expect(repo.lastPassword, 'secret123');
  });

  testWidgets('auth failure surfaces an inline error', (tester) async {

    useDesignSurface(tester);    repo.failWith = true;
    await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('emailField')), 'rider@example.com');
    await tester.enterText(find.byKey(const Key('passwordField')), 'wrongpass');
    await tester.tap(find.byKey(const Key('loginButton')));
    await tester.pump();
    expect(find.text('Incorrect email or password'), findsOneWidget);
  });

  testWidgets('google tap delegates to the repository', (tester) async {

    useDesignSurface(tester);    await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();
    await tester.tap(find.text('Continue with Google'));
    await tester.pump();
    expect(repo.googlePressed, isTrue);
  });

  testWidgets('forgot password link opens the reset flow', (tester) async {

    useDesignSurface(tester);    await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();
    expect(find.text('Forgot Password?'), findsOneWidget);
    // The tap, not just the label: the label alone is on the screen whether or
    // not the `GestureDetector` at `login_screen.dart:72-77` still has a
    // handler, so asserting the text proved nothing about the link.
    await tester.tap(find.text('Forgot Password?'));
    await tester.pumpAndSettle();
    expect(find.byType(ForgotPasswordScreen), findsOneWidget);
  });

  testWidgets('password visibility toggles', (tester) async {

    useDesignSurface(tester);    await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byKey(const Key('passwordField')));
    expect(field.obscureText, isTrue);
    await tester.tap(find.byIcon(Icons.visibility_off));
    await tester.pump();
    final after = tester.widget<TextField>(find.byKey(const Key('passwordField')));
    expect(after.obscureText, isFalse);
  });

  group('entrance animation', () {
    // The opacity the heading is actually painted at, read off the nearest
    // enclosing `Opacity`. Asserting the widget merely *exists* would pass even
    // if every band stayed at zero forever, which is the failure this pins.
    // Returns 1.0 when there is no wrapper at all, which is the
    // `animateIn: false` case: nothing fades, so the heading is simply visible.
    double headingOpacity(WidgetTester tester) {
      final finder = find.ancestor(
        of: find.text('Welcome Back'),
        matching: find.byType(Opacity),
      );
      if (finder.evaluate().isEmpty) return 1.0;
      return tester.widget<Opacity>(finder.first).opacity;
    }

    testWidgets('the heading is transparent on the first frame, then opaque',
        (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(wrap(repo));
      await tester.pump();
      expect(headingOpacity(tester), lessThan(0.5));

      await tester.pump(const Duration(milliseconds: 950));
      expect(headingOpacity(tester), 1.0);
    });

    testWidgets('animateIn: false paints everything at full opacity at once',
        (tester) async {
      useDesignSurface(tester);
      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(390, 844),
          minTextAdapt: true,
          builder: (_, _) => ChangeNotifierProvider<AuthController>.value(
            value: AuthController(repo),
            child: MaterialApp(
              theme: MngTheme.light,
              home: const LoginScreen(animateIn: false),
            ),
          ),
        ),
      );
      await tester.pump();
      // No settling pump: the point is that nothing is waiting on a controller.
      expect(headingOpacity(tester), 1.0);
    });
  });

  group('sign up', () {
    testWidgets('the Sign Up label is tappable and reveals the name field',
        (tester) async {
      await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nameField')), findsNothing);

      // The tap, not the label. The label is on the screen whether or not the
      // `GestureDetector` still has a handler, which is exactly how the first
      // pilot build shipped a dead button: the text was there, the tap was not.
      await tester.tap(find.byKey(const Key('signUpToggle')));
      await tester.pumpAndSettle();

      expect(find.text('Create Account'), findsOneWidget);
      expect(find.byKey(const Key('nameField')), findsOneWidget);
      expect(find.text('Sign In'), findsOneWidget);
    });

    testWidgets('signing up sends the name, email and password', (tester) async {

    useDesignSurface(tester);      await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('signUpToggle')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('nameField')),
        'Edem Apaloo',
      );
      await tester.enterText(
        find.byKey(const Key('emailField')),
        'edem@example.com',
      );
      await tester.enterText(find.byKey(const Key('passwordField')), 'Meetngo2026');
      await tester.tap(find.text('Sign Up'));
      await tester.pump();

      expect(repo.signUpName, 'Edem Apaloo');
      expect(repo.signUpEmail, 'edem@example.com');
    });

    testWidgets('a duplicate account reports the reason', (tester) async {

    useDesignSurface(tester);      repo.failWith = true;
      await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('signUpToggle')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('nameField')), 'Edem');
      await tester.enterText(find.byKey(const Key('emailField')), 'edem@example.com');
      await tester.enterText(find.byKey(const Key('passwordField')), 'Meetngo2026');
      await tester.tap(find.text('Sign Up'));
      await tester.pump();

      expect(find.text('User already registered'), findsOneWidget);
    });

    testWidgets('an empty name is refused before the repository is called',
        (tester) async {
      await tester.pumpWidget(wrap(repo));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('signUpToggle')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('emailField')), 'edem@example.com');
      await tester.enterText(find.byKey(const Key('passwordField')), 'Meetngo2026');
      await tester.tap(find.text('Sign Up'));
      await tester.pump();

      expect(find.text('Enter your name'), findsOneWidget);
      expect(repo.signUpEmail, isNull);
    });
  });
}
