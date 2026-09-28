import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/app/driver_config.dart';
import 'src/app/driver_flow.dart';
import 'src/app/driver_shell.dart';
import 'src/auth/driver_auth_controller.dart';
import 'src/auth/driver_login_screen.dart';
import 'src/data/driver_auth_repository.dart';
import 'src/data/driver_repository.dart';
import 'src/data/supabase_driver_repository.dart';
import 'src/earnings/earnings_repository.dart';

class DriverNGoApp extends StatelessWidget {
  const DriverNGoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ScreenUtilInit(
      designSize: const Size(390, 844),
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (_, _) {
        if (!DriverConfig.isConfigured) return const _UnconfiguredApp();
        final client = Supabase.instance.client;
        return MultiProvider(
          providers: [
            Provider<DriverAuthRepository>(
              create: (_) => SupabaseDriverAuthRepository(client),
            ),
            Provider<DriverRepository>(
              create: (_) => SupabaseDriverRepository(client),
            ),
            Provider<EarningsRepository>(
              create: (_) => SupabaseEarningsRepository(client),
            ),
            ChangeNotifierProvider<DriverAuthController>(
              create: (c) => DriverAuthController(
                c.read<DriverAuthRepository>(),
              ),
            ),
            ChangeNotifierProvider<DriverFlow>(
              create: (c) => DriverFlow(
                drivers: c.read<DriverRepository>(),
                earnings: c.read<EarningsRepository>(),
              ),
            ),
          ],
          // Not `const`: `MngTheme.light` is a `static final` getter, and a
          // getter call is not a constant expression.
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            title: "Meet 'N Go Driver",
            theme: MngTheme.light,
            home: const _AuthGate(),
          ),
        );
      },
    );
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (DriverConfig.isConfigured) {
    await Supabase.initialize(
      url: DriverConfig.supabaseUrl,
      // `publishableKey`, not `anonKey`: the latter is deprecated in
      // supabase_flutter 2.17.2 and `deprecated_member_use` is info severity,
      // which `flutter analyze --fatal-infos` -- what CI runs -- treats as
      // fatal. The rider app's `main.dart:58` is the same call.
      publishableKey: DriverConfig.supabaseAnonKey,
    );
  }
  runApp(const DriverNGoApp());
}

/// Shows the login screen until there is a session, then the app.
///
/// Driven off `onAuthStateChange` rather than reading `currentSession` once at
/// startup, because the Google sign-in path returns to the app through a deep
/// link: the session is established by the redirect, not by anything this
/// screen awaited.
class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      initialData: null,
      builder: (context, snapshot) {
        final state = snapshot.data;
        if (state == null) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return state.session == null
            ? const DriverLoginScreen()
            : const DriverShell();
      },
    );
  }
}

/// What the app shows when no Supabase project has been pointed at yet.
///
/// A build with no credentials still launches and says which two values are
/// missing, because the alternative -- a crash on the first frame -- tells a
/// first-time runner nothing about what went wrong.
class _UnconfiguredApp extends StatelessWidget {
  const _UnconfiguredApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: "Meet 'N Go Driver",
      theme: MngTheme.light,
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: EdgeInsets.all(24.w),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Meet 'N Go Driver",
                  style: MngTheme.light.textTheme.headlineMedium,
                ),
                SizedBox(height: 12.h),
                Text(
                  'No Supabase project is connected to this build yet.',
                  style: MngTheme.light.textTheme.titleMedium,
                ),
                SizedBox(height: 16.h),
                Text(
                  'Run with the project URL and anon key from your Supabase '
                  'project settings:',
                  style: MngTheme.light.textTheme.bodyMedium,
                ),
                SizedBox(height: 12.h),
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(14.w),
                  decoration: BoxDecoration(
                    color: MngColors.muted,
                    borderRadius: BorderRadius.circular(MngRadius.small),
                  ),
                  child: Text(
                    'flutter run \\\n'
                    '  --dart-define=SUPABASE_URL=https://YOUR-REF.supabase.co \\\n'
                    '  --dart-define=SUPABASE_ANON_KEY=YOUR-ANON-KEY',
                    style: MngTheme.light.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      color: MngColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
