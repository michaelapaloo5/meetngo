import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

import 'driver_auth_controller.dart';

/// What the driver sees when they tap "Forgot Password?".
///
/// The `otp-mail` Edge Function is still Task 18, so there is no reset flow to
/// push and nothing to call. The link is here because a driver who cannot sign
/// in needs to know that this build cannot help them, and it says so rather
/// than pretending to have sent an email.
const kResetNotAvailableMessage =
    'Password reset is not switched on in this build. It needs the otp-mail '
    'service, which has not been deployed yet. Ask an administrator to reset '
    'your password.';

class DriverLoginScreen extends StatefulWidget {
  const DriverLoginScreen({super.key});

  @override
  State<DriverLoginScreen> createState() => _DriverLoginScreenState();
}

class _DriverLoginScreenState extends State<DriverLoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _explainReset() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('resetUnavailableDialog'),
        title: const Text('Password reset'),
        content: const Text(kResetNotAvailableMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<DriverAuthController>();
    final text = MngTheme.light.textTheme;
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(horizontal: 20.w),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: 60.h),
              Text('Drive with us', style: text.headlineMedium),
              SizedBox(height: 6.h),
              Text(
                'Log in to go online and take rides.',
                style: text.bodySmall,
              ),
              SizedBox(height: 32.h),
              TextField(
                key: const Key('emailField'),
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(hintText: 'Email address'),
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
                      _obscure ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              SizedBox(height: 8.h),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  GestureDetector(
                    key: const Key('forgotPasswordLink'),
                    onTap: _explainReset,
                    child: Text('Forgot Password?', style: text.bodySmall),
                  ),
                ],
              ),
              if (auth.error != null) ...[
                SizedBox(height: 12.h),
                Text(
                  auth.error!,
                  style: const TextStyle(color: MngColors.error),
                ),
              ],
              SizedBox(height: 20.h),
              FilledButton(
                key: const Key('loginButton'),
                onPressed: auth.busy
                    ? null
                    : () => auth.submitPassword(_email.text, _password.text),
                child: auth.busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Log In'),
              ),
              SizedBox(height: 20.h),
              Center(child: Text('Or continue with', style: text.bodySmall)),
              SizedBox(height: 12.h),
              OutlinedButton(
                key: const Key('googleButton'),
                onPressed: auth.busy ? null : () => auth.submitGoogle(),
                // `Flexible` on the label, not decoration: the Flutter test
                // font sets every glyph to a full em box, and a 19-character
                // label at 16px is 304 logical pixels against a 302-pixel
                // button, so the row overflowed and took every test in the file
                // with it. The same row overflows on a phone at a large text
                // scale.
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.g_mobiledata, size: 22),
                    SizedBox(width: 8),
                    Flexible(child: Text('Continue with Google')),
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
