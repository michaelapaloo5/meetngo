import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';
import 'auth_controller.dart';
import 'forgot_password_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();
  bool _obscure = true;
  bool _signUp = false;

  void _toggleMode() {
    setState(() => _signUp = !_signUp);
    context.read<AuthController>().clearError();
  }

  @override
  void dispose() {
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
              SizedBox(height: 32.h),
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
                    icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              SizedBox(height: 8.h),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.check_circle, size: 16, color: MngColors.success),
                      SizedBox(width: 6.w),
                      Text('Keep me signed in', style: text.bodySmall),
                    ],
                  ),
                  if (!_signUp)
                    GestureDetector(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const ForgotPasswordScreen()),
                      ),
                      child: Text('Forgot Password?', style: text.bodySmall),
                    ),
                ],
              ),
              if (auth.error != null) ...[
                SizedBox(height: 12.h),
                Text(auth.error!, style: const TextStyle(color: MngColors.error)),
              ],
              SizedBox(height: 20.h),
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
              if (!_signUp) ...[
                SizedBox(height: 20.h),
                Center(child: Text('Or continue with', style: text.bodySmall)),
                SizedBox(height: 12.h),
                OutlinedButton(
                  onPressed: auth.busy ? null : () => auth.submitGoogle(),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.g_mobiledata, size: 22),
                      SizedBox(width: 8),
                      Text('Continue with Google'),
                    ],
                  ),
                ),
              ],
              SizedBox(height: 20.h),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _signUp ? 'Already have an account? ' : "Don't have an account? ",
                    style: text.bodySmall,
                  ),
                  GestureDetector(
                    key: const Key('signUpToggle'),
                    onTap: _toggleMode,
                    child: Text(
                      _signUp ? 'Sign In' : 'Sign Up',
                      style:
                          text.bodySmall?.copyWith(color: MngColors.primary),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
