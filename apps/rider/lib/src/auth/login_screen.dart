import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';
import 'auth_controller.dart';
import 'forgot_password_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, this.animateIn = true});
  final bool animateIn;
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();
  bool _obscure = true;
  bool _signUp = false;

  /// Drives the staggered entrance, and re-runs on a mode change so signing up
  /// reads as a fresh arrival rather than a field appearing under the reader's
  /// finger.
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.animateIn) return;
      if (MediaQuery.of(context).disableAnimations) return;
      _intro.forward();
    });
  }

  void _toggleMode() {
    setState(() => _signUp = !_signUp);
    context.read<AuthController>().clearError();
    if (!MediaQuery.of(context).disableAnimations) _intro.forward(from: 0);
  }

  /// One band of the stagger, as an eased fade-and-rise.
  ///
  /// [i] is the element's position in the sequence. The bands overlap so the
  /// screen settles as one motion rather than a queue of separate pops.
  Widget _enter(int i, Widget child) {
    if (!widget.animateIn) return child;
    const band = 0.55;
    final begin = (i * band * 0.45).clamp(0.0, 1.0 - band);
    final animation = CurvedAnimation(
      parent: _intro,
      curve: Interval(begin, begin + band, curve: Curves.easeOutCubic),
    );
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) => Opacity(
        opacity: animation.value,
        child: Transform.translate(
          offset: Offset(0, 16.h * (1 - animation.value)),
          child: child,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _intro.dispose();
    _email.dispose();
    _password.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final text = MngTheme.light.textTheme;
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(horizontal: 20.w),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: 60.h),
              _enter(
                0,
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _signUp ? 'Create Account' : 'Welcome Back',
                      style: text.headlineMedium,
                    ),
                    SizedBox(height: 6.h),
                    Text(
                      _signUp
                          ? 'Sign up to book a ride in seconds.'
                          : 'Login to book a ride in seconds.',
                      style: text.bodySmall,
                    ),
                  ],
                ),
              ),
              SizedBox(height: 32.h),
              _enter(
                1,
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_signUp) ...[
                      TextField(
                        key: const Key('nameField'),
                        controller: _name,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(hintText: 'Full name'),
                      ),
                      SizedBox(height: 12.h),
                    ],
                    TextField(
                      key: const Key('emailField'),
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      decoration:
                          const InputDecoration(hintText: 'Email address'),
                    ),
                    SizedBox(height: 12.h),
                    TextField(
                      key: const Key('passwordField'),
                      controller: _password,
                      obscureText: _obscure,
                      decoration: InputDecoration(
                        hintText: 'Password',
                        suffixIcon: IconButton(
                          icon: Icon(
                              _obscure
                                  ? Icons.visibility_off
                                  : Icons.visibility),
                          onPressed: () =>
                              setState(() => _obscure = !_obscure),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 8.h),
              _enter(
                2,
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // `Flexible` on both halves: the row sits inside a
                    // `stretch` column, so its children get the full width and
                    // neither label is allowed to claim more than its share.
                    Flexible(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.check_circle,
                              size: 16, color: MngColors.success),
                          SizedBox(width: 6.w),
                          Flexible(
                            child: Text(
                              'Keep me signed in',
                              style: text.bodySmall,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!_signUp)
                      Flexible(
                        child: GestureDetector(
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const ForgotPasswordScreen()),
                          ),
                          child: Text(
                            'Forgot Password?',
                            style: text.bodySmall,
                            textAlign: TextAlign.end,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (auth.error != null) ...[
                SizedBox(height: 12.h),
                Text(auth.error!, style: const TextStyle(color: MngColors.error)),
              ],
              SizedBox(height: 20.h),
              _enter(
                3,
                FilledButton(
                  key: const Key('loginButton'),
                  onPressed: auth.busy
                      ? null
                      : () => _signUp
                          ? auth.submitSignUp(
                              _email.text,
                              _password.text,
                              _name.text,
                            )
                          : auth.submitPassword(_email.text, _password.text),
                  child: auth.busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_signUp ? 'Sign Up' : 'Log In'),
                ),
              ),
              if (!_signUp) ...[
                SizedBox(height: 20.h),
                _enter(
                  4,
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                          child:
                              Text('Or continue with', style: text.bodySmall)),
                      SizedBox(height: 12.h),
                      OutlinedButton(
                        onPressed: auth.busy ? null : () => auth.submitGoogle(),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.g_mobiledata, size: 22),
                            const SizedBox(width: 8),
                            // Full-width button means a tight width for the
                            // label, so it ellipsizes rather than overflowing
                            // at a large system font scale.
                            Flexible(
                              child: Text(
                                'Continue with Google',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              SizedBox(height: 20.h),
              _enter(
                5,
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(
                        _signUp
                            ? 'Already have an account? '
                            : "Don't have an account? ",
                        style: text.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    GestureDetector(
                      key: const Key('signUpToggle'),
                      onTap: _toggleMode,
                      child: Text(
                        _signUp ? 'Sign In' : 'Sign Up',
                        style: text.bodySmall
                            ?.copyWith(color: MngColors.primary),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
