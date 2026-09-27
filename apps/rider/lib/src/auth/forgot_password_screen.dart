import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';
import '../data/auth_repository.dart';
import 'reset_password_screen.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});
  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  static const _resendWindow = Duration(seconds: 30);

  final _email = TextEditingController();
  Timer? _ticker;
  String? _error;
  bool _busy = false;
  bool _sent = false;
  int _resendSeconds = 0;

  @override
  void dispose() {
    _ticker?.cancel();
    _email.dispose();
    super.dispose();
  }

  void _startCountdown() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_resendSeconds <= 1) {
        timer.cancel();
        setState(() => _resendSeconds = 0);
      } else {
        setState(() => _resendSeconds -= 1);
      }
    });
  }

  Future<void> _send() async {
    if (_email.text.isEmpty) {
      setState(() => _error = 'Enter the email on your account');
      return;
    }
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      // The repository call is the whole point of this screen. Without it the
      // rider is shown a 6-digit code was sent when nothing was sent, and
      // `otp-mail` never runs.
      await context.read<AuthRepository>().sendResetOtp(_email.text);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _sent = true;
        _resendSeconds = _resendWindow.inSeconds;
      });
      _startCountdown();
    } on AuthFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = MngTheme.light.textTheme;
    return Scaffold(
      appBar: AppBar(backgroundColor: MngColors.page, elevation: 0),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 20.w),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const LinearProgressIndicator(value: 0.33, minHeight: 4),
              SizedBox(height: 8.h),
              Text('1 of 3', style: text.bodySmall),
              SizedBox(height: 32.h),
              const Icon(Icons.lock_outline, size: 48, color: MngColors.primary),
              SizedBox(height: 24.h),
              Text('Forgot password?', style: text.headlineMedium),
              SizedBox(height: 6.h),
              Text(
                "Enter the email on your account and we'll send you a 6-digit code.",
                style: text.bodySmall,
              ),
              SizedBox(height: 28.h),
              TextField(
                key: const Key('emailField'),
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(hintText: 'Email address'),
              ),
              if (_error != null) ...[
                SizedBox(height: 12.h),
                Text(_error!, style: const TextStyle(color: MngColors.error)),
              ],
              SizedBox(height: 20.h),
              FilledButton(
                key: const Key('sendCodeButton'),
                onPressed: _busy ? null : _send,
                child: const Text('Send Code'),
              ),
              SizedBox(height: 12.h),
              Center(
                child: TextButton(
                  key: const Key('resendButton'),
                  // `_resendSeconds > 0`, not `_resendSeconds == 0`: the guard
                  // has to switch the button off *while the countdown runs*,
                  // and `== 0` switches it off only when the countdown is over
                  // and nothing else is true. With `== 0` the rider can tap
                  // resend through all 30 seconds and call `otp-mail` once per
                  // tap, which is the thing the countdown is there to stop.
                  onPressed: _resendSeconds > 0 || _busy ? null : _send,
                  child: Text(
                    _resendSeconds == 0
                        ? "Didn't get it? Resend"
                        : "Didn't get it? Resend in 0:$_resendSeconds",
                    style: text.bodySmall,
                  ),
                ),
              ),
              if (_sent)
                Expanded(
                  // Scrollable, because this panel is the one part of the
                  // screen with no `SizedBox` slack in it: on a short surface,
                  // or at a large text scale, the icon, the two lines of copy
                  // and the button add up to more than the space left under
                  // the form, and a bare `Column` there overflows and takes
                  // the "Check your email" copy off screen with it.
                  child: SingleChildScrollView(
                    padding: EdgeInsets.only(top: 24.h),
                    child: Column(
                      children: [
                        const Icon(Icons.mail_outline, size: 40, color: MngColors.error),
                        SizedBox(height: 12.h),
                        Text('Check your email', style: text.titleLarge),
                        SizedBox(height: 6.h),
                        Text('We sent a 6-digit code to ${_email.text}',
                            style: text.bodySmall),
                        SizedBox(height: 20.h),
                        FilledButton(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ResetPasswordScreen(email: _email.text),
                            ),
                          ),
                          child: const Text('Enter code'),
                        ),
                      ],
                    ),
                  ),
                )
              else
                const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}
