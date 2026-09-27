import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';
import '../data/auth_repository.dart';
import 'reset_controller.dart';

class ResetPasswordScreen extends StatelessWidget {
  const ResetPasswordScreen({super.key, required this.email, this.repository});
  final String email;
  final AuthRepository? repository;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<ResetController>(
      create: (_) => ResetController(
        repository ?? context.read<AuthRepository>(),
        email,
      ),
      child: _ResetPasswordView(email: email),
    );
  }
}

class _ResetPasswordView extends StatefulWidget {
  const _ResetPasswordView({required this.email});
  final String email;
  @override
  State<_ResetPasswordView> createState() => _ResetPasswordViewState();
}

class _ResetPasswordViewState extends State<_ResetPasswordView> {
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _obscureNew = true;
  bool _obscureConfirm = true;

  @override
  void initState() {
    super.initState();
    // The two rule ticks below read `_password.text` and `_confirm.text`
    // during `build`. Without these listeners a keystroke rebuilds nothing, so
    // "Passwords match" never appears and the green tick is dead UI.
    _password.addListener(_onFieldChanged);
    _confirm.addListener(_onFieldChanged);
  }

  void _onFieldChanged() => setState(() {});

  @override
  void dispose() {
    _password.removeListener(_onFieldChanged);
    _confirm.removeListener(_onFieldChanged);
    _code.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ResetController>();
    final text = MngTheme.light.textTheme;
    if (controller.done) {
      return Scaffold(
        body: SafeArea(
          child: Padding(
            padding: EdgeInsets.all(20.w),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.check_circle, size: 72, color: MngColors.success),
                SizedBox(height: 24.h),
                Text('Password updated', style: text.headlineMedium),
                SizedBox(height: 6.h),
                Text(
                  "You're all set. Log in with your new password to pick up where you left off.",
                  style: text.bodySmall,
                ),
                SizedBox(height: 32.h),
                FilledButton(
                  onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
                  child: const Text('Back to Login'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(backgroundColor: MngColors.page, elevation: 0),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(horizontal: 20.w),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const LinearProgressIndicator(value: 0.66, minHeight: 4),
              SizedBox(height: 8.h),
              Text('2 of 3', style: text.bodySmall),
              SizedBox(height: 32.h),
              const Icon(Icons.key_outlined, size: 48, color: MngColors.primary),
              SizedBox(height: 24.h),
              Text('Create new password', style: text.headlineMedium),
              SizedBox(height: 24.h),
              TextField(
                key: const Key('codeField'),
                controller: _code,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(hintText: '6-digit code'),
              ),
              SizedBox(height: 12.h),
              TextField(
                key: const Key('newPasswordField'),
                controller: _password,
                obscureText: _obscureNew,
                decoration: InputDecoration(
                  hintText: 'New password',
                  suffixIcon: IconButton(
                    icon: Icon(_obscureNew ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _obscureNew = !_obscureNew),
                  ),
                ),
              ),
              SizedBox(height: 12.h),
              TextField(
                key: const Key('confirmPasswordField'),
                controller: _confirm,
                obscureText: _obscureConfirm,
                decoration: InputDecoration(
                  hintText: 'Confirm new password',
                  suffixIcon: IconButton(
                    icon: Icon(_obscureConfirm ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
                  ),
                ),
              ),
              SizedBox(height: 12.h),
              // A green tick must mean the rule holds. Showing both ticks
              // unconditionally paints a passing "At least 6 characters" over a
              // five-character password.
              if (_password.text.length >= 6)
                Row(
                  children: [
                    const Icon(Icons.check_circle, size: 16, color: MngColors.success),
                    SizedBox(width: 6.w),
                    Text('At least 6 characters', style: text.bodySmall),
                  ],
                ),
              if (_confirm.text.isNotEmpty && _password.text == _confirm.text)
                Row(
                  children: [
                    const Icon(Icons.check_circle, size: 16, color: MngColors.success),
                    SizedBox(width: 6.w),
                    Text('Passwords match', style: text.bodySmall),
                  ],
                ),
              if (controller.error != null) ...[
                SizedBox(height: 12.h),
                Text(controller.error!, style: const TextStyle(color: MngColors.error)),
              ],
              SizedBox(height: 24.h),
              FilledButton(
                key: const Key('resetButton'),
                onPressed: () => controller.submit(
                  code: _code.text,
                  password: _password.text,
                  confirm: _confirm.text,
                ),
                child: const Text('Reset Password'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
