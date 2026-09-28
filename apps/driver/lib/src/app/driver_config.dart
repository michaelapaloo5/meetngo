/// Supabase connection settings for the driver app, read at compile time.
///
/// A copy of `apps/rider/lib/src/app/app_config.dart` and not an import of it:
/// the two apps are separate packages and neither depends on the other, which
/// is also why this file, `driver_auth_repository.dart` and
/// `function_failure.dart` all exist twice rather than once in a shared place.
///
/// The anon key is not a secret -- it ships inside every app bundle by design
/// and every read it authorises is already filtered by the row level security
/// policies in `supabase/migrations/20260927000001_init.sql`. The service-role
/// key is the one that must never reach a device, and nothing here reads it.
///
/// Supplied either as
/// `--dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...` on the
/// command line, or by editing the two constants below. When neither is set the
/// app still builds and launches and shows what is missing rather than a crash.
abstract final class DriverConfig {
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: '',
  );

  static const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: '',
  );

  static bool get isConfigured =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
}
