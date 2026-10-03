import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/app/app_config.dart';
import 'src/app/rider_flow.dart';
import 'src/auth/auth_controller.dart';
import 'src/auth/splash_screen.dart';
import 'src/data/auth_repository.dart';
import 'src/data/chat_repository.dart';
import 'src/data/saved_place_repository.dart';
import 'src/data/trip_report_repository.dart';
import 'src/data/location_service.dart';
import 'src/data/place_service.dart';
import 'src/data/profile_repository.dart';
import 'src/data/supabase_auth_repository.dart';
import 'src/data/supabase_chat_repository.dart';
import 'src/data/supabase_profile_repository.dart';
import 'src/data/supabase_trip_repository.dart';
import 'src/data/trip_functions.dart';
import 'src/data/trip_repository.dart';
import 'src/profile/profile_controller.dart';

class RideNGoApp extends StatelessWidget {
  const RideNGoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ScreenUtilInit(
      designSize: const Size(390, 844),
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (_, _) {
        if (!AppConfig.isConfigured) return const _UnconfiguredApp();
        final client = Supabase.instance.client;
        return MultiProvider(
          providers: [
            // Repositories. All app-wide and all stateless, so one instance
            // each: the four tabs share them, and a second `SupabaseClient`
            // would mean a second realtime socket.
            Provider<AuthRepository>(
              create: (_) => SupabaseAuthRepository(client),
            ),
            Provider<LocationService>(
              create: (_) => const GeolocatorLocationService(),
            ),
            Provider<TripRepository>(
              create: (c) => SupabaseTripRepository(
                client,
                locations: c.read<LocationService>(),
              ),
            ),
            Provider<PlaceService>(create: (_) => NominatimPlaceService()),
            Provider<TripFunctions>(
              create: (_) => SupabaseTripFunctions(client),
            ),
            Provider<ProfileRepository>(
              create: (_) => SupabaseProfileRepository(client),
            ),
            Provider<SavedPlaceRepository>(
              create: (_) => SupabaseSavedPlaceRepository(client),
            ),
            Provider<TripReportRepository>(
              create: (_) => SupabaseTripReportRepository(client),
            ),
            Provider<ChatRepository>(
              create: (_) => SupabaseChatRepository(client),
            ),
            ChangeNotifierProvider<AuthController>(
              create: (c) => AuthController(c.read<AuthRepository>()),
            ),
            // Above the shell rather than inside it: the home screen greets the
            // rider by the name in this row, and a greeting that is only right
            // after the Profile tab has been opened is not a greeting.
            ChangeNotifierProvider<RiderProfileController>(
              create: (c) =>
                  RiderProfileController(c.read<ProfileRepository>())..load(),
            ),
            ChangeNotifierProvider<RiderFlow>(
              create: (c) => RiderFlow(
                trips: c.read<TripRepository>(),
                functions: c.read<TripFunctions>(),
              ),
            ),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            title: "Meet 'N Go",
            theme: MngTheme.light,
            home: const _Boot(),
          ),
        );
      },
    );
  }
}

/// A startup failure that would otherwise leave the phone on a blank grey
/// screen. Release builds render framework errors as grey, so without this the
/// only symptom of a dead `Supabase.initialize` (or anything else that throws
/// before the first frame) is the screenshot the pilot just sent: grey and
/// nothing else.
Object? _bootError;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ErrorWidget.builder = (details) => Directionality(
    textDirection: TextDirection.ltr,
    child: Container(
      color: const Color(0xFFFFFFFF),
      padding: const EdgeInsets.all(24),
      alignment: Alignment.centerLeft,
      child: Text(
        'Meet \'N Go failed to start:\n\n${details.exceptionAsString()}',
        style: const TextStyle(color: Color(0xFF1A1A1A), fontSize: 14),
      ),
    ),
  );
  if (AppConfig.isConfigured) {
    try {
      await Supabase.initialize(
        url: AppConfig.supabaseUrl,
        publishableKey: AppConfig.supabaseAnonKey,
      );
    } catch (e) {
      _bootError = e;
    }
  }
  runApp(
    _bootError == null ? const RideNGoApp() : _BootErrorApp(error: _bootError!),
  );
}

/// What the app shows when `Supabase.initialize` itself throws.
///
/// This is distinct from [_UnconfiguredApp]: that one means the build carries
/// no credentials, this one means it carries credentials that did not work.
class _BootErrorApp extends StatelessWidget {
  const _BootErrorApp({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: "Meet 'N Go",
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
                  "Meet 'N Go",
                  style: MngTheme.light.textTheme.headlineMedium,
                ),
                SizedBox(height: 12.h),
                Text(
                  'The app could not reach its backend:',
                  style: MngTheme.light.textTheme.titleMedium,
                ),
                SizedBox(height: 12.h),
                Text(
                  '$error',
                  style: MngTheme.light.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: MngColors.textPrimary,
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

/// The brand intro, which now opens onto the app itself.
///
/// It used to own a boolean: run [SplashScreen], and swap in [_AuthGate] from an
/// `onDone` callback when the animation finished. That made the handover a frame
/// of nothing between two routes, and it meant the session was only looked up
/// *after* the animation -- so a slow restore showed a spinner with no animation
/// to cover it.
///
/// [SplashScreen] now takes the destination as its child and reveals it, so there
/// is one widget the whole time and the session resolves behind the car.
class _Boot extends StatelessWidget {
  const _Boot();

  @override
  Widget build(BuildContext context) => const SplashScreen();
}

class _UnconfiguredApp extends StatelessWidget {
  const _UnconfiguredApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: "Meet 'N Go",
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
                  "Meet 'N Go",
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
