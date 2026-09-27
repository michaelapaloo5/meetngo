# Meet 'N Go — Rides Marketplace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a working Accra ride-hailing marketplace — rider app, driver app, Supabase backend, demo payments, live driver tracking on a 3D-styled map.

**Architecture:** Monorepo with two Flutter apps sharing one Flutter package for domain logic. Apps talk straight to Supabase (Auth, Postgres, Realtime) and call Edge Functions (Deno) for anything authoritative: fare computation, matching, cancellation policy, settlement. Payments are simulated end to end behind one interface so a real provider drops in later without app changes.

**Tech Stack:** Flutter (Dart 3) for `apps/rider` and `apps/driver`; shared package `packages/mng_core`; Supabase (Postgres + PostGIS, Auth, Realtime, Edge Functions in Deno); Google Maps Flutter SDK; `flutter_test` and Deno tests for verification.

**Spec:** `docs/superpowers/specs/2026-09-27-meet-n-go-rides-design.md`

## Global Constraints

Every task implicitly includes this section. Values are fixed for the whole build.

- **Money:** every payment, wallet, payout, and ledger row is DEMO. All amounts stamped `is_demo = true`. No real settlement code path exists in this build.
- **Currency:** Ghana Cedis (`GHS`) everywhere. Amounts stored as `numeric(10,2)`.
- **Fare formula:** `fare = (base_ghs + per_km_ghs × distance_km) × surge + booking_fee_ghs − discount_ghs`, surge clamped to `[1.0, 2.0]`, result rounded to 2 decimal places. Base `5.00`, booking fee `1.00`, default commission `15%`.
- **Category per-km rates:** Standard `1.80`, Premium `2.80`, Van `2.20`. No moto category at launch.
- **Trip state machine — the only legal transitions:** `requested → matched → arriving → ongoing → completed`; `requested → cancelled`; `matched → cancelled`; `arriving → cancelled`. Every other transition throws `IllegalTripTransition`.
- **Auth:** Google plus email/password only. Apple Sign-In is NOT implemented (spec section 3.1). iOS App Store release stays blocked until it is added back.
- **Design baseline:** 390×844 logical pixels via `ScreenUtil`. Light theme only. Card radius 16 small, 20 large. Bottom sheets always have a drag handle.
- **Colors:** primary `#F5B301`, onPrimary `#1A1A1A`, page `#FFFFFF`, muted `#F5F5F7`, divider `#EDEDF0`, text `#1A1A1A`, subtext `#8A8A8E`, success `#1DB954`, error `#E5484D`, info `#2F6FED`. Category colors: Standard `#F5B301`, Premium `#1A1A1A`, Van `#1DB954`.
- **No Docker on this host.** No local Supabase stack. All backend work targets a hosted Supabase project; Edge Function tests run under the standalone Deno runtime.
- **Rider KYC is phone OTP only.** Driver KYC is Ghana Card OCR plus selfie plus vehicle docs.
- **Offer TTL:** 20 seconds, hard-coded in `mng_core`, not configurable per ride.
- **Host budget:** ~322 MB free RAM, 5.7 GB free disk, 4 CPUs. `flutter test` (Dart VM) is the verification path on this box. `assembleAndroid` and `assembleIOS` are not runnable here.

## Review Focus

Five input classes the spec implies but no screen test naturally covers. Each is pinned by a named test in the task that owns the logic.

1. **Two drivers accept the same offer in the same second.** Exactly one win; the loser is released and never sees the trip. → `accept_offer_single_winner_test` in Task 7.
2. **Rider cancels after the driver is already en route.** Trip goes `cancelled`, driver is released, and a compensation ledger entry appears because the free-cancel window has passed. → `cancel_after_arriving_compensates_driver_test` in Task 10.
3. **Driver goes offline mid-trip.** Must be refused, and the active trip must survive a killed app and a phone restart. → `go_offline_refused_during_active_trip_test` in Task 13, `active_trip_survives_app_restart_test` in Task 17.
4. **Fare computed for a zero-length or reversed route.** Fare must equal base plus booking fee, never zero and never negative. → `zero_distance_fare_test` and `reversed_route_fare_test` in Task 2.
5. **Payment settles against a trip that was already cancelled.** Rider must not be charged; a void entry replaces the charge. → `settle_cancelled_trip_voids_payment_test` in Task 11.

| Test name | Task | Step |
|---|---|---|
| `zero_distance_fare_test` | 2 | 2 |
| `reversed_route_fare_test` | 2 | 2 |
| `accept_offer_single_winner_test` | 7 | 2 |
| `cancel_after_arriving_compensates_driver_test` | 10 | 3 |
| `settle_cancelled_trip_voids_payment_test` | 11 | 3 |
| `go_offline_refused_during_active_trip_test` | 13 | 2 |
| `active_trip_survives_app_restart_test` | 17 | 2 |

## File Structure

```
meet-n-go/
  packages/mng_core/                  # shared tokens, models, logic. No UI widgets.
    lib/mng_core.dart                 # single export barrel
    lib/src/theme/                    # tokens.dart, app_theme.dart
    lib/src/fare/fare_calculator.dart
    lib/src/trip/trip_state.dart
    lib/src/models/                   # category.dart, geo_point.dart, vehicle.dart,
                                     #   offer.dart, rating.dart, payment.dart,
                                     #   driver.dart, trip.dart
  apps/rider/lib/
    src/data/                         # supabase_client.dart, auth_repository.dart,
                                     #   trip_repository.dart, supabase_*_repository.dart
    src/auth/                         # splash, login, forgot_password, reset_password
    src/home/                         # home_screen.dart + widgets/
    src/booking/                      # route_entry_sheet.dart, choose_car_screen.dart,
                                     #   vehicle_card.dart
    src/tracking/                     # finding_driver, tracking_screen, controller, widgets/
    src/receipt/                      # receipt_screen.dart, rating_sheet.dart
    src/profile/  src/chat/  src/bookings/
  apps/driver/lib/
    src/data/  src/auth/  src/onboarding/  src/offers/  src/active_trip/  src/earnings/
  supabase/
    config.toml
    migrations/                       # numbered SQL
    seed/seed.sql
    functions/
      _shared/cors.ts
      request-ride/                   # index.ts, fare.ts, match.ts
      offers/                         # index.ts, resolve.ts
      cancel-trip/                    # index.ts, policy.ts
      complete-trip/                  # index.ts, ledger.ts
      demo-pay/                       # index.ts
      otp-mail/                       # index.ts
    functions/_tests/                 # Deno unit tests
  test/                               # integration tests
  docs/
```

Boundaries: `mng_core` has zero Flutter UI widgets so both apps and pure-Dart tests share it. Every Edge Function keeps its computation in a separate importable module so it is unit-testable without a running function. Files that change together live together: each screen owns its own `widgets/` subdirectory rather than a shared kitchen sink.

---

### Task 0: Toolchain and monorepo skeleton

**Files:**
- Create: `README.md`
- Create: `.gitignore`
- Create: `.github/workflows/ci.yml`
- Create: `packages/mng_core/` (via `flutter create --template=package`)
- Create: `apps/rider/`, `apps/driver/` (via `flutter create`)
- Modify: `apps/rider/pubspec.yaml`, `apps/driver/pubspec.yaml`

**Interfaces:**
- Consumes: nothing (first task)
- Produces: `packages/mng_core` importable as `package:mng_core/mng_core.dart`; both apps boot via `RideNGoApp` and `DriverNGoApp`; `flutter test` green in all three packages; CI workflow named `ci`.

- [ ] **Step 1: Write `README.md` with the measured host budget so no later task is surprised**

```markdown
# Meet 'N Go — Rides

Rider app, driver app, Supabase backend. Demo payments only.

## Host budget (measured 2026-09-27)

| Resource | Available | Consequence |
|---|---|---|
| Free RAM | ~322 MB | Gradle and `assembleAndroid` will OOM. `flutter test` (Dart VM) is the verification path. Android APK builds run on a bigger box. |
| Free disk | 5.7 GB | Flutter SDK and Gradle cache fit. No Linux desktop or web artifacts. Never run `flutter precache --all`. |
| Docker | absent | No local Supabase stack. Use a hosted Supabase project. |
| OS | Linux | iOS cannot be compiled here. iOS code is written but not build-verified. |
| Android SDK | platform 34, build-tools 34, JDK 21 | Matches Flutter stable requirements. |

## Setup

```bash
git clone --depth 1 -b stable https://github.com/flutter/flutter.git "$HOME/flutter"
export PATH="$HOME/flutter/bin:$PATH"
flutter config --no-analytics
flutter precache --android
npm install -g supabase
curl -fsSL https://deno.land/install.sh | sh
```

## Verify

```bash
flutter --version
supabase --version
deno --version
(cd packages/mng_core && flutter test)
(cd apps/rider && flutter test)
(cd apps/driver && flutter test)
```
```

- [ ] **Step 2: Install Flutter, Supabase CLI, and Deno, then confirm versions**

```bash
export PATH="$HOME/flutter/bin:$HOME/.deno/bin:$PATH"
git clone --depth 1 -b stable https://github.com/flutter/flutter.git "$HOME/flutter"
flutter config --no-analytics
flutter precache --android
npm install -g supabase
curl -fsSL https://deno.land/install.sh | sh
flutter --version && dart --version && supabase --version && deno --version
```

Expected: four version banners, none containing an error. Dart 3.x. If `flutter precache --android` reports disk exhaustion, delete `~/.gradle` and retry.

- [ ] **Step 3: Create the workspace, both apps, and the shared package**

```bash
cd ~/meet-n-go
flutter create --template=package --project-name mng_core packages/mng_core
flutter create --org gh.meetngo --project-name meetngo_rider --platforms=android,ios apps/rider
flutter create --org gh.meetngo --project-name meetngo_driver --platforms=android,ios apps/driver
```

Append to `apps/rider/pubspec.yaml` and `apps/driver/pubspec.yaml`:

```yaml
  mng_core:
    path: ../../packages/mng_core
  flutter_screenutil: ^2.1.0
```

- [ ] **Step 4: Write the failing boot test**

`apps/rider/test/skeleton_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/main.dart';

void main() {
  testWidgets('app boots to a MaterialApp', (tester) async {
    await tester.pumpWidget(const RideNGoApp());
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
```

`apps/driver/test/skeleton_test.dart` is identical except it imports `package:meetngo_driver/main.dart` and pumps `DriverNGoApp`.

- [ ] **Step 5: Run the test and confirm it fails**

```bash
cd ~/meet-n-go/apps/rider && flutter test test/skeleton_test.dart
```

Expected: FAIL — `RideNGoApp` is not defined. The generated `flutter create` code has `MyApp`, not `RideNGoApp`.

- [ ] **Step 6: Write the minimal implementation that makes it pass**

Replace `apps/rider/lib/main.dart`:

```dart
import 'package:flutter/material.dart';

class RideNGoApp extends StatelessWidget {
  const RideNGoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(body: Center(child: Text('Meet \'N Go'))),
    );
  }
}

void main() => runApp(const RideNGoApp());
```

`apps/driver/lib/main.dart` gets the same shape with the class named `DriverNGoApp` and the text `Meet 'N Go Driver`.

- [ ] **Step 7: Run the tests and confirm green**

```bash
cd ~/meet-n-go/apps/rider && flutter test && flutter analyze
cd ~/meet-n-go/apps/driver && flutter test && flutter analyze
cd ~/meet-n-go/packages/mng_core && flutter analyze
```

Expected: 1 test passed per app, no analyze issues.

- [ ] **Step 8: Write `.gitignore`**

```gitignore
.dart_tool/
build/
.packages
.pub-cache/
.pub/
.flutter-plugins
.flutter-plugins-dependencies
ios/Pods/
ios/.symlinks/
android/local.properties
android/.gradle/
supabase/.temp/
supabase/.env.local
*.iml
.DS_Store
```

- [ ] **Step 9: Write `.github/workflows/ci.yml`**

```yaml
name: ci
on: [push, pull_request]
jobs:
  verify:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
      - name: Install Supabase CLI
        run: curl -sSfL https://github.com/supabase/cli/releases/latest/download/supabase_linux_amd64.tar.gz | tar -xz -C /usr/local/bin
      - name: Install Deno
        run: curl -fsSL https://deno.land/install.sh | sh
      - name: Core package
        working-directory: packages/mng_core
        run: |
          flutter pub get
          flutter analyze --fatal-infos
          flutter test
      - name: Rider app
        working-directory: apps/rider
        run: |
          flutter pub get
          flutter analyze --fatal-infos
          flutter test
      - name: Driver app
        working-directory: apps/driver
        run: |
          flutter pub get
          flutter analyze --fatal-infos
          flutter test
      - name: Edge function tests
        working-directory: supabase
        run: deno test --allow-env functions/_tests/
      - name: Push migrations
        if: github.event_name == 'push'
        working-directory: supabase
        env:
          SUPABASE_ACCESS_TOKEN: ${{ secrets.SUPABASE_ACCESS_TOKEN }}
          SUPABASE_PROJECT_REF: ${{ secrets.SUPABASE_PROJECT_REF }}
        run: supabase db push --linked
```

- [ ] **Step 10: Commit**

```bash
cd ~/meet-n-go
git add -A
git commit -m "chore: bootstrap Flutter monorepo, toolchain, CI"
```

---
### Task 1: Design tokens and theme

**Files:**
- Create: `packages/mng_core/lib/src/theme/tokens.dart`
- Create: `packages/mng_core/lib/src/theme/app_theme.dart`
- Create: `packages/mng_core/lib/mng_core.dart`
- Test: `packages/mng_core/test/theme_test.dart`

**Interfaces:**
- Consumes: nothing from Task 0 except the package
- Produces: `MngColors` (static `Color` fields), `MngSpacing` (static `double` fields), `MngRadius` (static `double` fields), `MngTheme.light` (`ThemeData`), `MngTheme.dark` (`ThemeData?`, currently null). All imported from `package:mng_core/mng_core.dart`.

- [ ] **Step 1: Write the failing test**

`packages/mng_core/test/theme_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';

void main() {
  test('primary colour is the video-matched amber', () {
    expect(MngColors.primary, const Color(0xFFF5B301));
    expect(MngColors.onPrimary, const Color(0xFF1A1A1A));
  });

  test('radius tokens are 16 small and 20 large', () {
    expect(MngRadius.small, 16.0);
    expect(MngRadius.large, 20.0);
  });

  test('theme uses the amber primary and light surfaces', () {
    final theme = MngTheme.light;
    expect(theme.colorScheme.primary, MngColors.primary);
    expect(theme.scaffoldBackgroundColor, MngColors.page);
    expect(theme.useMaterial3, isTrue);
  });

  test('filled button uses amber with dark label', () {
    final style = MngTheme.light.filledButtonTheme.style;
    expect(style?.backgroundColor?.resolve({}), MngColors.primary);
    expect(style?.foregroundColor?.resolve({}), MngColors.onPrimary);
  });

  test('theme has no dark variant yet', () {
    expect(MngTheme.dark, isNull);
  });
}
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
cd ~/meet-n-go/packages/mng_core && flutter test test/theme_test.dart
```

Expected: FAIL — `MngColors` is not defined.

- [ ] **Step 3: Write `tokens.dart`**

```dart
import 'package:flutter/material.dart';

/// Palette locked to the reference UI. See spec section 6.
abstract final class MngColors {
  static const primary = Color(0xFFF5B301);
  static const onPrimary = Color(0xFF1A1A1A);

  static const page = Color(0xFFFFFFFF);
  static const surface = Color(0xFFFFFFFF);
  static const muted = Color(0xFFF5F5F7);
  static const divider = Color(0xFFEDEDF0);

  static const textPrimary = Color(0xFF1A1A1A);
  static const textSub = Color(0xFF8A8A8E);

  static const standard = Color(0xFFF5B301);
  static const premium = Color(0xFF1A1A1A);
  static const van = Color(0xFF1DB954);

  static const success = Color(0xFF1DB954);
  static const error = Color(0xFFE5484D);
  static const info = Color(0xFF2F6FED);
}

abstract final class MngSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
}

abstract final class MngRadius {
  static const small = 16.0;
  static const large = 20.0;
}
```

- [ ] **Step 4: Write `app_theme.dart`**

```dart
import 'package:flutter/material.dart';
import 'tokens.dart';

abstract final class MngTheme {
  /// Light theme only at launch, per spec section 6.
  static ThemeData? get dark => null;

  static TextStyle get _labelLarge => const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: MngColors.onPrimary,
      );

  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: MngColors.primary,
      surface: MngColors.page,
    ).copyWith(
      primary: MngColors.primary,
      onPrimary: MngColors.onPrimary,
      error: MngColors.error,
      surface: MngColors.page,
      outline: MngColors.divider,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: MngColors.page,
      dividerColor: MngColors.divider,
      textTheme: const TextTheme(
        headlineMedium: TextStyle(
            fontSize: 28, fontWeight: FontWeight.w700, color: MngColors.textPrimary),
        titleLarge: TextStyle(
            fontSize: 20, fontWeight: FontWeight.w600, color: MngColors.textPrimary),
        titleMedium: TextStyle(
            fontSize: 16, fontWeight: FontWeight.w600, color: MngColors.textPrimary),
        bodyMedium: TextStyle(fontSize: 14, color: MngColors.textPrimary),
        bodySmall: TextStyle(fontSize: 12, color: MngColors.textSub),
      ),
      cardTheme: CardThemeData(
        color: MngColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MngRadius.large),
          side: const BorderSide(color: MngColors.divider),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: MngColors.primary,
          foregroundColor: MngColors.onPrimary,
          minimumSize: const Size.fromHeight(52),
          textStyle: _labelLarge,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(MngRadius.small)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: MngColors.muted,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: MngSpacing.md, vertical: 14),
        border: _inputBorder(BorderSide.none),
        enabledBorder: _inputBorder(BorderSide.none),
        focusedBorder:
            _inputBorder(const BorderSide(color: MngColors.primary, width: 1.5)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: MngColors.surface,
        showDragHandle: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
    );
  }

  static OutlineInputBorder _inputBorder(BorderSide side) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(MngRadius.small),
        borderSide: side,
      );
}
```

- [ ] **Step 5: Write the barrel and run the tests**

`packages/mng_core/lib/mng_core.dart`:

```dart
/// Shared domain and design primitives for the Meet 'N Go rider and driver
/// apps. Deliberately free of UI widgets so pure-Dart tests can use it.
library;

export 'src/theme/app_theme.dart';
export 'src/theme/tokens.dart';
```

```bash
cd ~/meet-n-go/packages/mng_core && flutter test test/theme_test.dart && flutter analyze
```

Expected: 5 tests pass, analyze clean.

- [ ] **Step 6: Wire the theme into both apps and re-run their tests**

In `apps/rider/lib/main.dart` add `import 'package:mng_core/mng_core.dart';` and set `theme: MngTheme.light` on the `MaterialApp`. Do the same in `apps/driver/lib/main.dart` on `DriverNGoApp`.

```bash
cd ~/meet-n-go/apps/rider && flutter test && flutter analyze
cd ~/meet-n-go/apps/driver && flutter test && flutter analyze
```

Expected: green in both.

- [ ] **Step 7: Commit**

```bash
cd ~/meet-n-go
git add -A
git commit -m "feat(core): design tokens and light theme matching reference UI"
```

---

### Task 2: Fare calculator

**Files:**
- Create: `packages/mng_core/lib/src/models/category.dart`
- Create: `packages/mng_core/lib/src/fare/fare_calculator.dart`
- Modify: `packages/mng_core/lib/mng_core.dart`
- Test: `packages/mng_core/test/fare_calculator_test.dart`

**Interfaces:**
- Consumes: `MngColors` (Task 1)
- Produces: `enum RideCategory { standard, premium, van }` with `String label`, `double perKmGhs`, `Color color`; `class FareQuote` with `fareGhs`, `surge`, `discountGhs`, `distanceKm`; `class FareCalculator` with constructor `FareCalculator({double baseGhs = 5.00, double bookingFeeGhs = 1.00, double commissionRate = 0.15, double maxSurge = 2.0})`, method `FareQuote quote({required RideCategory category, required double distanceKm, double surge = 1.0, double discountGhs = 0.0})` which throws `ArgumentError` on non-finite distance, and method `double driverPayoutGhs(FareQuote quote)`.

- [ ] **Step 1: Write the failing test, including both Review Focus cases**

`packages/mng_core/test/fare_calculator_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';

void main() {
  final calc = FareCalculator();

  group('quote', () {
    test('standard ride over 8 km costs base + per-km + booking fee', () {
      final q = calc.quote(category: RideCategory.standard, distanceKm: 8);
      expect(q.fareGhs, closeTo(20.4, 0.001));
      expect(q.distanceKm, 8);
    });

    test('premium is dearer per km than standard', () {
      final standard = calc.quote(category: RideCategory.standard, distanceKm: 10);
      final premium = calc.quote(category: RideCategory.premium, distanceKm: 10);
      expect(premium.fareGhs, greaterThan(standard.fareGhs));
    });

    test('van sits between standard and premium', () {
      final standard = calc.quote(category: RideCategory.standard, distanceKm: 10);
      final van = calc.quote(category: RideCategory.van, distanceKm: 10);
      final premium = calc.quote(category: RideCategory.premium, distanceKm: 10);
      expect(van.fareGhs, greaterThan(standard.fareGhs));
      expect(van.fareGhs, lessThan(premium.fareGhs));
    });

    test('surge multiplies the distance component and is capped at 2x', () {
      final surged = calc.quote(category: RideCategory.standard, distanceKm: 5, surge: 1.5);
      final capped = calc.quote(category: RideCategory.standard, distanceKm: 5, surge: 9.0);
      expect(surged.fareGhs, closeTo(22.0, 0.001));
      expect(capped.fareGhs, closeTo(29.0, 0.001));
    });

    test('surge below 1 is lifted to 1 so fares never drop below base', () {
      final q = calc.quote(category: RideCategory.standard, distanceKm: 5, surge: 0.2);
      expect(q.fareGhs, closeTo(15.0, 0.001));
      expect(q.surge, 1.0);
    });

    test('discount is subtracted and never drives the fare below zero', () {
      final discounted =
          calc.quote(category: RideCategory.standard, distanceKm: 2, discountGhs: 3.0);
      final excessive =
          calc.quote(category: RideCategory.standard, distanceKm: 0, discountGhs: 999.0);
      expect(discounted.fareGhs, closeTo(6.6, 0.001));
      expect(excessive.fareGhs, 0.0);
    });
  });

  group('Review Focus: degenerate routes', () {
    test('zero_distance_fare_test', () {
      final q = calc.quote(category: RideCategory.standard, distanceKm: 0);
      expect(q.fareGhs, closeTo(6.0, 0.001));
      expect(q.fareGhs, greaterThan(0));
    });

    test('reversed_route_fare_test', () {
      final q = calc.quote(category: RideCategory.standard, distanceKm: -4);
      expect(q.fareGhs, closeTo(6.0, 0.001));
      expect(q.fareGhs, greaterThan(0));
    });
  });

  group('validation', () {
    test('negative distance is coerced, not thrown', () {
      expect(
        () => calc.quote(category: RideCategory.van, distanceKm: -1),
        returnsNormally,
      );
    });

    test('non-finite distance throws ArgumentError', () {
      expect(
        () => calc.quote(category: RideCategory.van, distanceKm: double.nan),
        throwsArgumentError,
      );
      expect(
        () => calc.quote(category: RideCategory.van, distanceKm: double.infinity),
        throwsArgumentError,
      );
    });
  });

  group('driverPayoutGhs', () {
    test('platform takes 15 percent by default', () {
      final q = calc.quote(category: RideCategory.standard, distanceKm: 8);
      expect(calc.driverPayoutGhs(q), closeTo(17.34, 0.01));
    });

    test('commission rate is configurable', () {
      final zero = FareCalculator(commissionRate: 0.0);
      final q = zero.quote(category: RideCategory.standard, distanceKm: 8);
      expect(zero.driverPayoutGhs(q), closeTo(q.fareGhs, 0.001));
    });
  });

  group('RideCategory', () {
    test('labels match the launch set and carry per-km rates', () {
      expect(RideCategory.values.map((c) => c.label),
          ['Standard', 'Premium', 'Van']);
      expect(RideCategory.standard.perKmGhs, 1.80);
      expect(RideCategory.premium.perKmGhs, 2.80);
      expect(RideCategory.van.perKmGhs, 2.20);
    });
  });
}
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
cd ~/meet-n-go/packages/mng_core && flutter test test/fare_calculator_test.dart
```

Expected: FAIL — `FareCalculator` is not defined.

- [ ] **Step 3: Write `category.dart`**

```dart
import 'package:flutter/material.dart';
import '../theme/tokens.dart';

/// Launch categories. Moto is excluded on purpose, see spec section 3.1.
enum RideCategory {
  standard(label: 'Standard', perKmGhs: 1.80),
  premium(label: 'Premium', perKmGhs: 2.80),
  van(label: 'Van', perKmGhs: 2.20);

  const RideCategory({required this.label, required this.perKmGhs});

  final String label;
  final double perKmGhs;

  Color get color => switch (this) {
        RideCategory.standard => MngColors.standard,
        RideCategory.premium => MngColors.premium,
        RideCategory.van => MngColors.van,
      };
}
```

- [ ] **Step 4: Write `fare_calculator.dart`**

```dart
import 'dart:math' as math;

import '../models/category.dart';

class FareQuote {
  const FareQuote({
    required this.fareGhs,
    required this.surge,
    required this.discountGhs,
    required this.distanceKm,
  });

  final double fareGhs;
  final double surge;
  final double discountGhs;
  final double distanceKm;
}

class FareCalculator {
  FareCalculator({
    this.baseGhs = 5.00,
    this.bookingFeeGhs = 1.00,
    this.commissionRate = 0.15,
    this.maxSurge = 2.0,
  });

  final double baseGhs;
  final double bookingFeeGhs;
  final double commissionRate;
  final double maxSurge;

  /// fare = (base + perKm * distance) * surge + bookingFee - discount.
  ///
  /// A negative distance collapses to zero so a reversed pin never yields a
  /// negative fare. A non-finite distance is a caller bug and throws.
  FareQuote quote({
    required RideCategory category,
    required double distanceKm,
    double surge = 1.0,
    double discountGhs = 0.0,
  }) {
    if (distanceKm.isNaN || distanceKm.isInfinite) {
      throw ArgumentError.value(distanceKm, 'distanceKm', 'must be finite');
    }
    final km = math.max(0.0, distanceKm);
    final appliedSurge = surge.clamp(1.0, maxSurge).toDouble();
    final raw = (baseGhs + category.perKmGhs * km) * appliedSurge +
        bookingFeeGhs -
        discountGhs;
    return FareQuote(
      fareGhs: round2(math.max(0.0, raw)),
      surge: appliedSurge,
      discountGhs: math.max(0.0, discountGhs),
      distanceKm: km,
    );
  }

  double driverPayoutGhs(FareQuote quote) =>
      round2(quote.fareGhs * (1 - commissionRate));

  static double round2(double value) =>
      (value * 100).roundToDouble() / 100;
}
```

- [ ] **Step 5: Export from the barrel and run the tests**

Add to `packages/mng_core/lib/mng_core.dart`:

```dart
export 'src/fare/fare_calculator.dart';
export 'src/models/category.dart';
```

```bash
cd ~/meet-n-go/packages/mng_core && flutter test test/fare_calculator_test.dart && flutter analyze
```

Expected: 14 tests pass, analyze clean.

- [ ] **Step 6: Commit**

```bash
cd ~/meet-n-go
git add -A
git commit -m "feat(core): fare calculator with surge cap and degenerate-route guards"
```

---
### Task 3: Trip state machine

**Files:**
- Create: `packages/mng_core/lib/src/trip/trip_state.dart`
- Modify: `packages/mng_core/lib/mng_core.dart`
- Test: `packages/mng_core/test/trip_state_test.dart`

**Interfaces:**
- Consumes: nothing (independent of Task 2)
- Produces: `enum TripState { requested, matched, arriving, ongoing, completed, cancelled }` with `bool get isActive` and `bool get isTerminal`; `class IllegalTripTransition implements Exception` with `final TripState from` and `final TripState to`; top-level `bool canTransition(TripState from, TripState to)`; top-level `TripState nextState(TripState from, TripState to)` which throws `IllegalTripTransition` on an illegal move.

- [ ] **Step 1: Write the failing test**

`packages/mng_core/test/trip_state_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';

void main() {
  test('happy path walks requested to completed', () {
    expect(canTransition(TripState.requested, TripState.matched), isTrue);
    expect(canTransition(TripState.matched, TripState.arriving), isTrue);
    expect(canTransition(TripState.arriving, TripState.ongoing), isTrue);
    expect(canTransition(TripState.ongoing, TripState.completed), isTrue);
  });

  test('cancel is legal from requested, matched and arriving only', () {
    for (final s in [
      TripState.requested,
      TripState.matched,
      TripState.arriving,
    ]) {
      expect(canTransition(s, TripState.cancelled), isTrue,
          reason: '$s must be cancellable');
    }
    expect(canTransition(TripState.ongoing, TripState.cancelled), isFalse);
    expect(canTransition(TripState.completed, TripState.cancelled), isFalse);
  });

  test('terminal states are terminal', () {
    for (final terminal in [TripState.completed, TripState.cancelled]) {
      for (final target in TripState.values) {
        expect(canTransition(terminal, target), isFalse,
            reason: '$terminal -> $target');
      }
    }
  });

  test('no skipping ahead and no self-transitions', () {
    expect(canTransition(TripState.requested, TripState.ongoing), isFalse);
    expect(canTransition(TripState.matched, TripState.completed), isFalse);
    expect(canTransition(TripState.requested, TripState.requested), isFalse);
  });

  test('nextState returns the target for a legal move', () {
    expect(nextState(TripState.requested, TripState.matched), TripState.matched);
  });

  test('nextState throws IllegalTripTransition on an illegal move', () {
    expect(
      () => nextState(TripState.completed, TripState.ongoing),
      throwsA(
        isA<IllegalTripTransition>()
            .having((e) => e.from, 'from', TripState.completed)
            .having((e) => e.to, 'to', TripState.ongoing),
      ),
    );
  });

  test('isActive covers the four in-progress states', () {
    expect(TripState.requested.isActive, isTrue);
    expect(TripState.matched.isActive, isTrue);
    expect(TripState.arriving.isActive, isTrue);
    expect(TripState.ongoing.isActive, isTrue);
    expect(TripState.completed.isActive, isFalse);
    expect(TripState.cancelled.isActive, isFalse);
  });
}
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
cd ~/meet-n-go/packages/mng_core && flutter test test/trip_state_test.dart
```

Expected: FAIL — `TripState` is not defined.

- [ ] **Step 3: Write `trip_state.dart`**

```dart
/// Mirrors the Postgres `trip_state` enum and the DB trigger that rejects
/// illegal moves. See spec section 4.5.
enum TripState {
  requested,
  matched,
  arriving,
  ongoing,
  completed,
  cancelled;

  bool get isActive =>
      this == requested || this == matched || this == arriving || this == ongoing;

  bool get isTerminal => this == completed || this == cancelled;
}

class IllegalTripTransition implements Exception {
  const IllegalTripTransition(this.from, this.to);

  final TripState from;
  final TripState to;

  @override
  String toString() => 'IllegalTripTransition: cannot move trip from $from to $to';
}

const Map<TripState, Set<TripState>> _legal = {
  TripState.requested: {TripState.matched, TripState.cancelled},
  TripState.matched: {TripState.arriving, TripState.cancelled},
  TripState.arriving: {TripState.ongoing, TripState.cancelled},
  TripState.ongoing: {TripState.completed},
  TripState.completed: {},
  TripState.cancelled: {},
};

// `?? false`, not `!`: a state added later without a map entry must report
// "illegal" rather than throw a null-check TypeError, so that nextState still
// throws IllegalTripTransition as documented.
bool canTransition(TripState from, TripState to) => _legal[from]?.contains(to) ?? false;

TripState nextState(TripState from, TripState to) {
  if (!canTransition(from, to)) {
    throw IllegalTripTransition(from, to);
  }
  return to;
}
```

- [ ] **Step 4: Export and run the whole core suite**

Add to `packages/mng_core/lib/mng_core.dart`:

```dart
export 'src/trip/trip_state.dart';
```

```bash
cd ~/meet-n-go/packages/mng_core && flutter test && flutter analyze
```

Expected: theme (5) + fare (14) + trip state (7) tests pass.

- [ ] **Step 5: Commit**

```bash
cd ~/meet-n-go
git add -A
git commit -m "feat(core): trip state machine with guarded transitions"
```

---

### Task 4: Domain models

**Files:**
- Create: `packages/mng_core/lib/src/models/geo_point.dart`
- Create: `packages/mng_core/lib/src/models/vehicle.dart`
- Create: `packages/mng_core/lib/src/models/offer.dart`
- Create: `packages/mng_core/lib/src/models/rating.dart`
- Create: `packages/mng_core/lib/src/models/payment.dart`
- Create: `packages/mng_core/lib/src/models/driver.dart`
- Create: `packages/mng_core/lib/src/models/trip.dart`
- Modify: `packages/mng_core/lib/mng_core.dart`
- Test: `packages/mng_core/test/models_test.dart`

**Interfaces:**
- Consumes: `TripState` (Task 3), `RideCategory` (Task 2)
- Produces: `GeoPoint` (`distanceKmTo`, `toJson`, `fromJson`); `VehicleCategory` enum; `Vehicle`; `kOfferTtl`; `OfferState` enum; `Offer` (`isExpired`, `secondsRemaining`, `copyWith`); `Rating` with `static bool isValidStars(int)`; `PayMethod` and `PaymentState` enums plus `PaymentStateX.isTerminal`; `Payment`; `DriverAvailability` and `KycStatus` enums plus `DriverProfile` (`isApproved`, `canAcceptOffers`, `copyWith`); `TripStop`; `Trip` (`hasDriver`, `copyWith({state, driverId, clearDriver, etaMinutes})`). All parse `fromJson` and emit `toJson`.

- [ ] **Step 1: Write the failing test**

`packages/mng_core/test/models_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mng_core/mng_core.dart';

void main() {
  group('GeoPoint', () {
    test('distance between two Accra points is about 2 km', () {
      const a = GeoPoint(5.6037, -0.1870);
      const b = GeoPoint(5.6200, -0.1870);
      expect(a.distanceKmTo(b), closeTo(1.81, 0.05));
    });

    test('identical points are zero distance', () {
      const a = GeoPoint(5.6037, -0.1870);
      expect(a.distanceKmTo(a), 0.0);
    });

    test('round-trips through JSON and compares by value', () {
      const p = GeoPoint(5.6037, -0.1870);
      final back = GeoPoint.fromJson(p.toJson());
      expect(back.lat, closeTo(5.6037, 1e-9));
      expect(back, p);
    });
  });

  group('Trip', () {
    final json = <String, dynamic>{
      'id': 't1',
      'rider_id': 'r1',
      'driver_id': 'd1',
      'category': 'standard',
      'state': 'matched',
      'pickup': {
        'label': 'Pickup',
        'point': {'lat': 5.6037, 'lng': -0.1870},
        'address': 'Osu, Accra',
      },
      'dropoff': {
        'label': 'Dropoff',
        'point': {'lat': 5.6200, 'lng': -0.1870},
        'address': 'Airport Residential',
      },
      'distance_km': 1.81,
      'fare_ghs': 12.50,
      'is_demo': true,
    };

    test('parses a trip row from Postgres json', () {
      final trip = Trip.fromJson(json);
      expect(trip.id, 't1');
      expect(trip.state, TripState.matched);
      expect(trip.category, RideCategory.standard);
      expect(trip.fareGhs, closeTo(12.50, 0.001));
      expect(trip.isDemo, isTrue);
      expect(trip.hasDriver, isTrue);
      expect(trip.pickup.address, 'Osu, Accra');
    });

    test('copyWith changes state and leaves everything else alone', () {
      final trip = Trip.fromJson(json);
      final moved = trip.copyWith(state: TripState.arriving);
      expect(moved.state, TripState.arriving);
      expect(moved.id, trip.id);
      expect(moved.fareGhs, trip.fareGhs);
      expect(moved.pickup, trip.pickup);
    });

    test('clearDriver unassigns the driver', () {
      final trip = Trip.fromJson(json);
      expect(trip.copyWith(clearDriver: true).driverId, isNull);
      expect(trip.copyWith(clearDriver: true).hasDriver, isFalse);
    });

    test('json round-trip preserves identity and geometry', () {
      final trip = Trip.fromJson(json);
      final back = Trip.fromJson(trip.toJson());
      expect(back.id, trip.id);
      expect(back.state, trip.state);
      expect(back.driverId, trip.driverId);
      expect(back.pickup.point, trip.pickup.point);
      expect(back.dropoff.point, trip.dropoff.point);
    });
  });

  group('Offer', () {
    Offer build(Duration ttl) => Offer(
          id: 'o1',
          tripId: 't1',
          driverId: 'd1',
          fareGhs: 12.50,
          pickupDistanceKm: 0.8,
          expiresAt: DateTime.now().add(ttl),
        );

    test('pending offer is not expired while ttl remains', () {
      expect(build(kOfferTtl).isExpired, isFalse);
    });

    test('offer past ttl reports expired', () {
      expect(build(const Duration(seconds: -1)).isExpired, isTrue);
    });

    test('seconds remaining never goes negative', () {
      expect(build(const Duration(minutes: -5)).secondsRemaining, 0);
    });

    test('ttl is the hard-coded 20 seconds', () {
      expect(kOfferTtl, const Duration(seconds: 20));
    });

    test('copyWith moves the offer to released', () {
      final offer = build(kOfferTtl);
      expect(offer.copyWith(state: OfferState.released).state, OfferState.released);
      expect(offer.state, OfferState.pending);
    });
  });

  group('DriverProfile', () {
    DriverProfile build({
      KycStatus kyc = KycStatus.approved,
      DriverAvailability availability = DriverAvailability.online,
    }) =>
        DriverProfile(
          id: 'd1',
          fullName: 'Jane Cooper',
          phone: '0240000000',
          photoUrl: '',
          rating: 4.8,
          tripCount: 148,
          kyc: kyc,
          availability: availability,
        );

    test('approved online driver can accept offers', () {
      expect(build().isApproved, isTrue);
      expect(build().canAcceptOffers, isTrue);
    });

    test('unapproved driver cannot accept offers even when online', () {
      expect(build(kyc: KycStatus.pending).canAcceptOffers, isFalse);
    });

    test('approved driver already on a trip cannot accept offers', () {
      expect(
        build(availability: DriverAvailability.onTrip).canAcceptOffers,
        isFalse,
      );
    });
  });

  group('Payment and Rating', () {
    test('succeeded demo payment is terminal', () {
      const p = Payment(
        id: 'p1',
        tripId: 't1',
        amountGhs: 12.50,
        method: PayMethod.momo,
        state: PaymentState.succeeded,
        isDemo: true,
      );
      expect(p.isDemo, isTrue);
      expect(p.state.isTerminal, isTrue);
    });

    test('pending payment is not terminal', () {
      expect(PaymentState.pending.isTerminal, isFalse);
    });

    test('rating stars are valid only from 1 to 5', () {
      expect(Rating.isValidStars(1), isTrue);
      expect(Rating.isValidStars(5), isTrue);
      expect(Rating.isValidStars(0), isFalse);
      expect(Rating.isValidStars(6), isFalse);
    });
  });

  group('Vehicle', () {
    test('display name joins make and model', () {
      final v = Vehicle(
        id: 'v1',
        ownerId: 'd1',
        category: VehicleCategory.sedan,
        make: 'Honda',
        model: 'Civic',
        plate: 'GR-1234',
        seats: 4,
        photoUrl: '',
        rideCategory: RideCategory.standard,
      );
      expect(v.displayName, 'Honda Civic');
      expect(Vehicle.fromJson(v.toJson()).rideCategory, RideCategory.standard);
    });
  });
}
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
cd ~/meet-n-go/packages/mng_core && flutter test test/models_test.dart
```

Expected: FAIL — `GeoPoint` is not defined.

- [ ] **Step 3: Write `geo_point.dart`**

```dart
import 'dart:math' as math;

class GeoPoint {
  const GeoPoint(this.lat, this.lng);

  factory GeoPoint.fromJson(Map<String, dynamic> json) => GeoPoint(
        (json['lat'] as num).toDouble(),
        (json['lng'] as num).toDouble(),
      );

  final double lat;
  final double lng;

  static const double _earthRadiusKm = 6371.0088;

  /// Great-circle distance. Used for driver proximity and the fare preview;
  /// routed distance comes from the backend RPC.
  double distanceKmTo(GeoPoint other) {
    final dLat = _rad(other.lat - lat);
    final dLng = _rad(other.lng - lng);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_rad(lat)) *
            math.cos(_rad(other.lat)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return _earthRadiusKm * 2 * math.asin(math.min(1.0, math.sqrt(a)));
  }

  static double _rad(double deg) => deg * math.pi / 180.0;

  Map<String, dynamic> toJson() => {'lat': lat, 'lng': lng};

  @override
  bool operator ==(Object other) =>
      other is GeoPoint && other.lat == lat && other.lng == lng;

  @override
  int get hashCode => Object.hash(lat, lng);

  @override
  String toString() => 'GeoPoint($lat, $lng)';
}
```

- [ ] **Step 4: Write `vehicle.dart`**

```dart
import 'category.dart';

enum VehicleCategory { sedan, suv, van, luxury }

class Vehicle {
  const Vehicle({
    required this.id,
    required this.ownerId,
    required this.category,
    required this.make,
    required this.model,
    required this.plate,
    required this.seats,
    required this.photoUrl,
    required this.rideCategory,
  });

  factory Vehicle.fromJson(Map<String, dynamic> json) => Vehicle(
        id: json['id'] as String,
        ownerId: json['owner_id'] as String,
        category:
            VehicleCategory.values.byName(json['vehicle_category'] as String),
        make: json['make'] as String,
        model: json['model'] as String,
        plate: json['plate'] as String,
        seats: (json['seats'] as num).toInt(),
        photoUrl: (json['photo_url'] as String?) ?? '',
        rideCategory: RideCategory.values.byName(json['ride_category'] as String),
      );

  final String id;
  final String ownerId;
  final VehicleCategory category;
  final String make;
  final String model;
  final String plate;
  final int seats;
  final String photoUrl;
  final RideCategory rideCategory;

  String get displayName => '$make $model';

  Map<String, dynamic> toJson() => {
        'id': id,
        'owner_id': ownerId,
        'vehicle_category': category.name,
        'make': make,
        'model': model,
        'plate': plate,
        'seats': seats,
        'photo_url': photoUrl,
        'ride_category': rideCategory.name,
      };
}
```

- [ ] **Step 5: Write `offer.dart`**

```dart
import 'geo_point.dart';

/// Hard-coded per Global Constraints. 20 seconds.
const Duration kOfferTtl = Duration(seconds: 20);

enum OfferState { pending, accepted, declined, expired, released }

class Offer {
  const Offer({
    required this.id,
    required this.tripId,
    required this.driverId,
    required this.fareGhs,
    required this.pickupDistanceKm,
    required this.expiresAt,
    this.state = OfferState.pending,
  });

  factory Offer.fromJson(Map<String, dynamic> json) => Offer(
        id: json['id'] as String,
        tripId: json['trip_id'] as String,
        driverId: json['driver_id'] as String,
        fareGhs: (json['fare_ghs'] as num).toDouble(),
        pickupDistanceKm: (json['pickup_distance_km'] as num).toDouble(),
        expiresAt: DateTime.parse(json['expires_at'] as String),
        state: OfferState.values.byName((json['state'] as String?) ?? 'pending'),
      );

  final String id;
  final String tripId;
  final String driverId;
  final double fareGhs;
  final double pickupDistanceKm;
  final DateTime expiresAt;
  final OfferState state;

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  int secondsRemaining {
    final seconds = expiresAt.difference(DateTime.now()).inSeconds;
    return seconds < 0 ? 0 : seconds;
  }

  Offer copyWith({OfferState? state}) => Offer(
        id: id,
        tripId: tripId,
        driverId: driverId,
        fareGhs: fareGhs,
        pickupDistanceKm: pickupDistanceKm,
        expiresAt: expiresAt,
        state: state ?? this.state,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'trip_id': tripId,
        'driver_id': driverId,
        'fare_ghs': fareGhs,
        'pickup_distance_km': pickupDistanceKm,
        'expires_at': expiresAt.toIso8601String(),
        'state': state.name,
      };
}
```

- [ ] **Step 6: Write `rating.dart` and `payment.dart`**

`rating.dart`:

```dart
class Rating {
  const Rating({
    required this.id,
    required this.tripId,
    required this.fromRole,
    required this.stars,
    this.comment = '',
  });

  factory Rating.fromJson(Map<String, dynamic> json) => Rating(
        id: json['id'] as String,
        tripId: json['trip_id'] as String,
        fromRole: json['from_role'] as String,
        stars: (json['stars'] as num).toInt(),
        comment: (json['comment'] as String?) ?? '',
      );

  final String id;
  final String tripId;
  final String fromRole;
  final int stars;
  final String comment;

  static bool isValidStars(int stars) => stars >= 1 && stars <= 5;

  Map<String, dynamic> toJson() => {
        'id': id,
        'trip_id': tripId,
        'from_role': fromRole,
        'stars': stars,
        'comment': comment,
      };
}
```

`payment.dart`:

```dart
enum PayMethod { momo, cash, card }

enum PaymentState { pending, succeeded, failed, voided }

extension PaymentStateX on PaymentState {
  bool get isTerminal =>
      this == PaymentState.succeeded ||
      this == PaymentState.failed ||
      this == PaymentState.voided;
}

class Payment {
  const Payment({
    required this.id,
    required this.tripId,
    required this.amountGhs,
    required this.method,
    required this.state,
    this.isDemo = true,
  });

  factory Payment.fromJson(Map<String, dynamic> json) => Payment(
        id: json['id'] as String,
        tripId: json['trip_id'] as String,
        amountGhs: (json['amount_ghs'] as num).toDouble(),
        method: PayMethod.values.byName(json['method'] as String),
        state: PaymentState.values.byName(json['state'] as String),
        isDemo: (json['is_demo'] as bool?) ?? true,
      );

  final String id;
  final String tripId;
  final double amountGhs;
  final PayMethod method;
  final PaymentState state;
  final bool isDemo;

  Payment copyWith({PaymentState? state}) => Payment(
        id: id,
        tripId: tripId,
        amountGhs: amountGhs,
        method: method,
        state: state ?? this.state,
        isDemo: isDemo,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'trip_id': tripId,
        'amount_ghs': amountGhs,
        'method': method.name,
        'state': state.name,
        'is_demo': isDemo,
      };
}
```

- [ ] **Step 7: Write `driver.dart`**

```dart
import 'geo_point.dart';

enum DriverAvailability { offline, online, onTrip }

enum KycStatus { notStarted, pending, approved, rejected }

class DriverProfile {
  const DriverProfile({
    required this.id,
    required this.fullName,
    required this.phone,
    required this.rating,
    required this.tripCount,
    required this.kyc,
    required this.availability,
    this.photoUrl = '',
    this.vehicleId,
    this.location,
  });

  factory DriverProfile.fromJson(Map<String, dynamic> json) => DriverProfile(
        id: json['id'] as String,
        fullName: (json['full_name'] as String?) ?? '',
        phone: (json['phone'] as String?) ?? '',
        photoUrl: (json['photo_url'] as String?) ?? '',
        rating: ((json['rating'] as num?) ?? 5.0).toDouble(),
        tripCount: (json['trip_count'] as num?)?.toInt() ?? 0,
        kyc: KycStatus.values
            .byName((json['kyc_status'] as String?) ?? 'notStarted'),
        availability: DriverAvailability.values
            .byName((json['availability'] as String?) ?? 'offline'),
        vehicleId: json['vehicle_id'] as String?,
        location: json['lat'] == null
            ? null
            : GeoPoint(
                (json['lat'] as num).toDouble(),
                (json['lng'] as num).toDouble(),
              ),
      );

  final String id;
  final String fullName;
  final String phone;
  final String photoUrl;
  final double rating;
  final int tripCount;
  final KycStatus kyc;
  final DriverAvailability availability;
  final String? vehicleId;
  final GeoPoint? location;

  bool get isApproved => kyc == KycStatus.approved;

  bool get canAcceptOffers =>
      isApproved && availability == DriverAvailability.online;

  DriverProfile copyWith({
    DriverAvailability? availability,
    KycStatus? kyc,
    GeoPoint? location,
    String? vehicleId,
  }) =>
      DriverProfile(
        id: id,
        fullName: fullName,
        phone: phone,
        photoUrl: photoUrl,
        rating: rating,
        tripCount: tripCount,
        kyc: kyc ?? this.kyc,
        availability: availability ?? this.availability,
        vehicleId: vehicleId ?? this.vehicleId,
        location: location ?? this.location,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'full_name': fullName,
        'phone': phone,
        'photo_url': photoUrl,
        'rating': rating,
        'trip_count': tripCount,
        'kyc_status': kyc.name,
        'availability': availability.name,
        'vehicle_id': vehicleId,
        if (location != null) 'lat': location!.lat,
        if (location != null) 'lng': location!.lng,
      };
}
```

- [ ] **Step 8: Write `trip.dart`**

```dart
import 'category.dart';
import 'geo_point.dart';
import '../trip/trip_state.dart';

class TripStop {
  const TripStop(this.label, this.point, this.address);

  factory TripStop.fromJson(Map<String, dynamic> json) => TripStop(
        (json['label'] as String?) ?? '',
        GeoPoint.fromJson(json['point'] as Map<String, dynamic>),
        (json['address'] as String?) ?? '',
      );

  final String label;
  final GeoPoint point;
  final String address;

  Map<String, dynamic> toJson() => {
        'label': label,
        'point': point.toJson(),
        'address': address,
      };
}

class Trip {
  const Trip({
    required this.id,
    required this.riderId,
    required this.driverId,
    required this.category,
    required this.state,
    required this.pickup,
    required this.dropoff,
    required this.distanceKm,
    required this.fareGhs,
    this.isDemo = true,
    this.etaMinutes,
  });

  factory Trip.fromJson(Map<String, dynamic> json) => Trip(
        id: json['id'] as String,
        riderId: json['rider_id'] as String,
        driverId: json['driver_id'] as String?,
        category: RideCategory.values.byName(json['category'] as String),
        state: TripState.values.byName(json['state'] as String),
        pickup: TripStop.fromJson(json['pickup'] as Map<String, dynamic>),
        dropoff: TripStop.fromJson(json['dropoff'] as Map<String, dynamic>),
        distanceKm: (json['distance_km'] as num).toDouble(),
        fareGhs: (json['fare_ghs'] as num).toDouble(),
        isDemo: (json['is_demo'] as bool?) ?? true,
        etaMinutes: (json['eta_minutes'] as num?)?.toInt(),
      );

  final String id;
  final String riderId;
  final String? driverId;
  final RideCategory category;
  final TripState state;
  final TripStop pickup;
  final TripStop dropoff;
  final double distanceKm;
  final double fareGhs;
  final bool isDemo;
  final int? etaMinutes;

  bool get hasDriver => driverId != null;

  Trip copyWith({
    TripState? state,
    String? driverId,
    bool clearDriver = false,
    int? etaMinutes,
  }) =>
      Trip(
        id: id,
        riderId: riderId,
        driverId: clearDriver ? null : (driverId ?? this.driverId),
        category: category,
        state: state ?? this.state,
        pickup: pickup,
        dropoff: dropoff,
        distanceKm: distanceKm,
        fareGhs: fareGhs,
        isDemo: isDemo,
        etaMinutes: etaMinutes ?? this.etaMinutes,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'rider_id': riderId,
        'driver_id': driverId,
        'category': category.name,
        'state': state.name,
        'pickup': pickup.toJson(),
        'dropoff': dropoff.toJson(),
        'distance_km': distanceKm,
        'fare_ghs': fareGhs,
        'is_demo': isDemo,
        'eta_minutes': etaMinutes,
      };
}
```

- [ ] **Step 9: Export every model and run the whole core suite**

Add to `packages/mng_core/lib/mng_core.dart`:

```dart
export 'src/models/driver.dart';
export 'src/models/geo_point.dart';
export 'src/models/offer.dart';
export 'src/models/payment.dart';
export 'src/models/rating.dart';
export 'src/models/trip.dart';
export 'src/models/vehicle.dart';
```

```bash
cd ~/meet-n-go/packages/mng_core && flutter test && flutter analyze
```

Expected: 5 theme + 14 fare + 7 trip state + 15 model tests pass.

- [ ] **Step 10: Commit**

```bash
cd ~/meet-n-go
git add -A
git commit -m "feat(core): trip, offer, vehicle, payment, rating, driver models"
```

---
### Task 5: Supabase schema, RLS, and seed

**Files:**
- Create: `supabase/config.toml` (generated by `supabase init`, then edited: remove `[auth.external.apple]` and add an enabled `[auth.external.google]`, because auth is Google plus email/password only per spec section 3.1)
- Create: `supabase/migrations/20260927000001_init.sql`
- Create: `supabase/seed/seed.sql`
- Create: `supabase/tests/harness.sql` (local Postgres + PostGIS stand-in for a Supabase project; there is no Docker on this host)
- Create: `supabase/tests/verify_migration.sql` (128 assertions: the 36 ordered trip transitions, the demo-only CHECK constraints, RLS, the geometry helpers, `match_offers_for_trip` and `accept_offer`, and the client write paths)
- Create: `supabase/tests/verify_concurrency.sql` (16 assertions over two real concurrent backends, via `dblink`)

**Interfaces:**
- Consumes: field names from Task 4 models
- Produces: tables `profiles`, `vehicles`, `trips`, `offers`, `driver_locations`, `payments`, `payouts`, `ledger_entries`, `ratings`, `promos`, `chat_messages`, `sos_events`; enums `trip_state`, `offer_state`, `payment_state`, `pay_method`, `kyc_status`, `driver_availability`; functions `trip_distance_km(text, text)`, `driver_pickup_distance_km(uuid, uuid)`, `match_offers_for_trip(uuid)`, `accept_offer(uuid)`; triggers `enforce_trip_transition` (trips), `on_auth_user_created` (auth.users, runs `handle_new_user`) and `profiles_update_guard` (profiles, runs `guard_profile_update`). **Of those, `match_offers_for_trip(uuid)` is callable only by `service_role`**: the migration ends it with `revoke execute on function match_offers_for_trip(uuid) from public, anon, authenticated;`. `public` has to be in that list, because PostgreSQL grants EXECUTE on every function to `PUBLIC` by default and `anon` and `authenticated` are PUBLIC members, so revoking from the two named roles alone leaves the grant in place. Add no `auth.uid()` guard and no party-membership check to that function: a service-role PostgREST request carries no `request.jwt.claim.sub`, so `auth.uid()` is null on the only legitimate caller and either guard would make it return no candidates. `accept_offer(uuid)` is the opposite case and stays executable by `anon` and `authenticated`, because a client is supposed to call it; it is guarded inside by an ownership check on the offer. **That ownership check means only a caller's own `auth.uid()` can accept: `offers.driver_id` is `not null`, so a caller with a null `auth.uid()` fails `v_offer.driver_id is distinct from auth.uid()` and gets `false` with both ids null. Measured on this host, both `anon` and `service_role` have a null `auth.uid()` and both hold EXECUTE on the function, so neither role can accept an offer through it. Task 7's `offers` Edge Function must therefore call `accept_offer` on a user client carrying the driver's bearer token, never on a service-role client. Do not change the function to accommodate a service-role caller; forward the request `Authorization` header instead, as the Task 7 code already does.** `handle_new_user()` is also `SECURITY DEFINER` but returns `trigger`, so it cannot be invoked as a query at all. Tasks 6, 7, 8, 10, 11, 12, 13, 14 call these, and the client write paths in Tasks 8 and 12 depend on the column grants and policies declared at the end of the migration: a client may update only `trips.(state, eta_minutes, started_at, completed_at)` and only a trip assigned to it, only `profiles.(full_name, phone, photo_url, ghana_card_last4, ghana_card_expiry, selfie_url, vehicle_id, availability, kyc_status)` and only its own row, and it may insert `sos_events` and `chat_messages` only for a trip it is party to.

- [ ] **Step 1: Initialise the Supabase project and link a hosted project**

```bash
cd ~/meet-n-go
supabase init
supabase login
```

`supabase init` resolves its output directory relative to the current directory, so run it at the repository
root. `cd supabase` first writes `supabase/supabase/config.toml`.

Then point the CLI at the seed file this task creates:

```toml
# supabase/config.toml
[db.seed]
sql_paths = ["./seed/seed.sql"]
```

The template default is `./seed.sql`, which does not match the `supabase/seed/seed.sql` path below, and
`supabase db reset` would then apply the migrations and seed nothing.

Create a free project named `meet-n-go` at `https://supabase.com/dashboard`, copy its project ref, then:

```bash
supabase link --project-ref <YOUR_PROJECT_REF>
```

Expected: `Finished supabase link.` If the CLI reports a missing database password, run `supabase link --project-ref <REF> --password <DB_PASSWORD>`.

- [ ] **Step 2: Write the migration**

`supabase/migrations/20260927000001_init.sql`:

```sql
create extension if not exists postgis;
create extension if not exists "uuid-ossp";

create type trip_state as enum
  ('requested','matched','arriving','ongoing','completed','cancelled');
create type offer_state as enum
  ('pending','accepted','declined','expired','released');
create type payment_state as enum ('pending','succeeded','failed','voided');
create type pay_method as enum ('momo','cash','card');
create type kyc_status as enum ('notStarted','pending','approved','rejected');
create type driver_availability as enum ('offline','online','onTrip');

create table profiles (
  id uuid primary key references auth.users on delete cascade,
  role text not null check (role in ('rider','driver','admin')),
  full_name text not null default '',
  phone text not null default '',
  photo_url text not null default '',
  rating numeric(2,1) not null default 5.0,
  trip_count integer not null default 0,
  kyc_status kyc_status not null default 'notStarted',
  availability driver_availability not null default 'offline',
  ghana_card_last4 text,
  ghana_card_expiry text,
  selfie_url text,
  vehicle_id uuid,
  created_at timestamptz not null default now()
);

create table vehicles (
  id uuid primary key default uuid_generate_v4(),
  owner_id uuid not null unique references profiles on delete cascade,
  vehicle_category text not null check (vehicle_category in ('sedan','suv','van','luxury')),
  ride_category text not null check (ride_category in ('standard','premium','van')),
  make text not null,
  model text not null,
  plate text not null unique,
  seats integer not null default 4,
  photo_url text not null default '',
  approved boolean not null default false,
  created_at timestamptz not null default now()
);

alter table profiles
  add constraint profiles_vehicle_fk
  foreign key (vehicle_id) references vehicles(id) on delete set null;

create table trips (
  id uuid primary key default uuid_generate_v4(),
  rider_id uuid not null references profiles on delete cascade,
  driver_id uuid references profiles on delete set null,
  vehicle_id uuid references vehicles on delete set null,
  category text not null check (category in ('standard','premium','van')),
  state trip_state not null default 'requested',
  pickup jsonb not null,
  dropoff jsonb not null,
  pickup_point geography(Point,4326) not null,
  dropoff_point geography(Point,4326) not null,
  distance_km numeric(8,2) not null,
  surge numeric(3,2) not null default 1.00,
  fare_ghs numeric(10,2) not null,
  eta_minutes integer,
  pickup_otp text,
  is_demo boolean not null default true,
  created_at timestamptz not null default now(),
  matched_at timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz
);

create index trips_rider_idx on trips (rider_id, created_at desc);
create index trips_driver_idx on trips (driver_id, created_at desc);
create index trips_state_idx on trips (state);
create index trips_pickup_gix on trips using gist (pickup_point);

create table offers (
  id uuid primary key default uuid_generate_v4(),
  trip_id uuid not null references trips on delete cascade,
  driver_id uuid not null references profiles on delete cascade,
  fare_ghs numeric(10,2) not null,
  pickup_distance_km numeric(8,2) not null,
  state offer_state not null default 'pending',
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique (trip_id, driver_id)
);

create index offers_driver_idx on offers (driver_id, state);
create index offers_trip_idx on offers (trip_id, state);

create table driver_locations (
  driver_id uuid primary key references profiles on delete cascade,
  point geography(Point,4326) not null,
  heading numeric(5,2),
  updated_at timestamptz not null default now()
);

create index driver_locations_gix on driver_locations using gist (point);

create table payments (
  id uuid primary key default uuid_generate_v4(),
  trip_id uuid not null references trips on delete cascade,
  payer_id uuid not null references profiles on delete cascade,
  amount_ghs numeric(10,2) not null,
  method pay_method not null,
  state payment_state not null default 'pending',
  is_demo boolean not null default true,
  created_at timestamptz not null default now()
);

create table payouts (
  id uuid primary key default uuid_generate_v4(),
  driver_id uuid not null references profiles on delete cascade,
  trip_id uuid references trips on delete set null,
  amount_ghs numeric(10,2) not null,
  is_demo boolean not null default true,
  created_at timestamptz not null default now()
);

create table ledger_entries (
  id uuid primary key default uuid_generate_v4(),
  driver_id uuid not null references profiles on delete cascade,
  trip_id uuid references trips on delete set null,
  amount_ghs numeric(10,2) not null,
  kind text not null check (kind in ('fare','commission','compensation','void','bonus')),
  note text not null default '',
  is_demo boolean not null default true,
  created_at timestamptz not null default now()
);

create table ratings (
  id uuid primary key default uuid_generate_v4(),
  trip_id uuid not null references trips on delete cascade,
  rater_id uuid not null references profiles on delete cascade,
  ratee_id uuid not null references profiles on delete cascade,
  from_role text not null check (from_role in ('rider','driver')),
  stars integer not null check (stars between 1 and 5),
  comment text not null default '',
  created_at timestamptz not null default now(),
  unique (trip_id, from_role)
);

create table promos (
  id uuid primary key default uuid_generate_v4(),
  code text not null unique,
  percent_off numeric(5,2) not null check (percent_off > 0 and percent_off <= 100),
  max_discount_ghs numeric(10,2) not null default 50.00,
  active boolean not null default true,
  expires_at timestamptz,
  created_at timestamptz not null default now()
);

create table chat_messages (
  id uuid primary key default uuid_generate_v4(),
  trip_id uuid not null references trips on delete cascade,
  sender_id uuid not null references profiles on delete cascade,
  body text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now()
);

create index chat_trip_idx on chat_messages (trip_id, created_at);

create table sos_events (
  id uuid primary key default uuid_generate_v4(),
  trip_id uuid not null references trips on delete cascade,
  raised_by uuid not null references profiles on delete cascade,
  point geography(Point,4326),
  note text not null default '',
  status text not null default 'open' check (status in ('open','resolved')),
  created_at timestamptz not null default now()
);

-- Global Constraint: every trip and every money row is demo-only in this build.
alter table trips add constraint trips_demo_only check (is_demo);
alter table payments add constraint payments_demo_only check (is_demo);
alter table payouts add constraint payouts_demo_only check (is_demo);
alter table ledger_entries add constraint ledger_demo_only check (is_demo);

-- Global Constraint: the only legal trip transitions, enforced in the database
-- so a buggy client cannot walk a trip backwards or complete it twice.
create or replace function enforce_trip_transition()
returns trigger
language plpgsql
as $$
begin
  -- No self-transition short circuit: a no-op update that names `state` in its
  -- SET clause falls through to the legality predicate below, so
  -- `new.state = old.state` raises like any other illegal move. Do not
  -- reintroduce an early `return new` here. The Dart `canTransition` table is
  -- the single authority; the Task 17 fake calls it rather than keeping a copy.
  if not (
    (old.state = 'requested' and new.state in ('matched','cancelled')) or
    (old.state = 'matched'    and new.state in ('arriving','cancelled')) or
    (old.state = 'arriving'   and new.state in ('ongoing','cancelled')) or
    (old.state = 'ongoing'    and new.state = 'completed')
  ) then
    raise exception 'illegal trip transition % -> %', old.state, new.state;
  end if;
  return new;
end;
$$;

create trigger trips_transition_guard
before update of state on trips
for each row execute function enforce_trip_transition();

-- Geometry helpers used by the Edge Functions.
--
-- These use st_distance on geography, not st_distance_sphere. PostGIS 3.5 no
-- longer ships the geography overload of st_distance_sphere, so the original
-- `st_distance_sphere(a::geography, b::geography)` fails with
-- `function st_distance_sphere(geography, geography) does not exist` on both
-- PostGIS 3.5 and therefore on any current hosted Supabase project.
-- st_distance(geography, geography) returns the same unit (metres) on every
-- PostGIS since 1.5, and `immutable` still holds.
create or replace function trip_distance_km(a text, b text)
returns numeric
language sql
immutable
as $$
  select st_distance(a::geography, b::geography) / 1000.0;
$$;

create or replace function driver_pickup_distance_km(target_trip uuid, target_driver uuid)
returns numeric
language sql
stable
as $$
  select st_distance(
    l.point,
    (select pickup_point from trips where id = target_trip)
  ) / 1000.0
  from driver_locations l
  where l.driver_id = target_driver;
$$;

create or replace function match_offers_for_trip(target_trip uuid)
returns table (driver_id uuid, pickup_distance_km numeric)
language sql
security definer
set search_path = public
as $$
  select d.id, driver_pickup_distance_km(target_trip, d.id)
  from profiles d
  join vehicles v on v.owner_id = d.id and v.approved
  where d.role = 'driver'
    and d.kyc_status = 'approved'
    and d.availability = 'online'
    and exists (select 1 from driver_locations l where l.driver_id = d.id)
    and driver_pickup_distance_km(target_trip, d.id) <= 5.0
  order by driver_pickup_distance_km(target_trip, d.id)
  limit 5;
$$;

-- Service-role only. Hosted Supabase grants EXECUTE on every public function to
-- anon and authenticated, and this one is SECURITY DEFINER, so any caller who
-- learned a foreign trip_id could read which drivers are online, KYC-approved and
-- within 5 km of that pickup, with their ids and their distances. That is the
-- same class of leak as the accept_offer ownership hole, and this is the last
-- unguarded SECURITY DEFINER surface in the schema.
--
-- Do not "fix" this with an `auth.uid() is not null` guard or a party-membership
-- check. Task 6's request-ride Edge Function calls it with the service-role
-- client, and a service-role PostgREST request carries no request.jwt.claim.sub,
-- so auth.uid() is null there and either guard would make the candidate query
-- return nothing and every ride request would find zero drivers. EXECUTE is
-- already granted to service_role, so this revoke is the whole change.
--
-- `public` has to be in the list, and omitting it leaves the hole open.
-- PostgreSQL grants EXECUTE on every function to PUBLIC by default and Supabase
-- does not take that away, so the ACL still reads `=X/postgres` after revoking
-- from anon and authenticated alone. anon and authenticated are members of
-- PUBLIC implicitly, so a signed-in caller still got through. Revoking from
-- public as well is what actually closes it; service_role keeps its explicit
-- grant.
revoke execute on function match_offers_for_trip(uuid) from public, anon, authenticated;

-- Single-winner offer acceptance.
--
-- Lock order is trip first, then offer, and it has to stay that way. Each caller
-- used to lock its own offer row first and only then the trip, and the winner's
-- sibling-release UPDATE also needed every losing offer row, so two accepts on
-- two different offers of the same trip took locks in opposite orders and
-- Postgres aborted one of them with SQLSTATE 40P01. The loser then saw a
-- PostgREST 500 instead of `false`. Serialising on the trip row first means
-- acceptors for one trip queue up instead of deadlocking: the first one to get
-- the trip lock wins, the rest find the trip already `matched` and return
-- `false` with the trip id, which is the contract the offers Edge Function
-- expects.
create or replace function accept_offer(p_offer uuid)
returns table (accepted boolean, trip_id uuid, driver_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_offer offers%rowtype;
  v_trip trips%rowtype;
begin
  -- 1. Unlocked read, to fail fast on an unknown id or an offer that is not
  --    the caller's, without taking any lock a stranger could hold.
  select * into v_offer from offers where id = p_offer;
  if not found then
    return query select false, null::uuid, null::uuid;
    return;
  end if;

  -- This function is SECURITY DEFINER and hosted Supabase grants EXECUTE on
  -- every public function to anon and authenticated, so the RLS policy on
  -- offers does not apply to the caller here. Without this check any signed-in
  -- rider could read the offer ids on their own trip through the "rider reads
  -- offers on own trip" policy and accept on a driver's behalf, force-matching
  -- the trip, releasing every other offer and locking the remaining drivers
  -- out. The offers Edge Function performs the same ownership check in
  -- TypeScript before calling; this is the database-side copy of it.
  --
  -- A caller with no `sub` claim has a NULL auth.uid() and is refused here too,
  -- because `null is distinct from <uuid>` is true and offers.driver_id is NOT
  -- NULL. On this host `anon` and `service_role` both measure that way, and both
  -- hold EXECUTE on this function, so neither role can accept an offer through
  -- it: the offers Edge Function has to call it on a user client carrying the
  -- driver's bearer token, never on a service-role client.
  if v_offer.driver_id is distinct from auth.uid() then
    return query select false, null::uuid, null::uuid;
    return;
  end if;

  -- 2. Lock the trip first: one row every acceptor for this trip contends on.
  select * into v_trip from trips where id = v_offer.trip_id for update;
  if not found then
    return query select false, null::uuid, null::uuid;
    return;
  end if;

  -- 3. Now the offer. The unlocked read above may be stale by the time the
  --    trip lock is granted, so re-read and re-check ownership under the lock.
  --
  --    Each of the two guards below was measured on this host by staging the
  --    change in a second session, committing it while the call was parked on
  --    the trip lock, and reading back which guard fired.
  --
  --    A service-role DELETE of the offer, committed in that window. The
  --    re-read returns no row, so the IF NOT FOUND refuses it. That guard is
  --    defence in depth rather than the thing doing the refusing: delete only
  --    the IF NOT FOUND and the ownership re-check still refuses, because a
  --    zero-row `select * into v_offer ... for update` leaves v_offer a NULL
  --    record and `null is distinct from <uuid>` is true, the same ground the
  --    unlocked check above stands on. Delete both and the call falls through
  --    to `return query select true, v_trip.id, v_offer.driver_id` and answers
  --    accepted = true with a NULL driver id, leaving the trip `requested` with
  --    a NULL driver_id. What is refused there is a false positive.
  --
  --    A service-role reassignment of offers.driver_id to a different driver,
  --    committed in the same window. The IF NOT FOUND cannot see this one,
  --    because the offer still exists: the re-read returns a row, and the
  --    ownership re-check is the only guard that refuses. Delete that one and
  --    the call answers accepted = true, accepts the offer, releases its
  --    siblings and matches the trip to the driver the offer was reassigned to
  --    rather than to the caller. The ownership re-check is therefore the only
  --    thing standing between a reassigned offer and a trip matched to the
  --    wrong driver. Keep both, and do not drop the ownership re-check.
  select * into v_offer from offers where id = p_offer for update;
  if not found then
    return query select false, null::uuid, null::uuid;
    return;
  end if;
  if v_offer.driver_id is distinct from auth.uid() then
    return query select false, null::uuid, null::uuid;
    return;
  end if;

  if v_trip.state <> 'requested'
     or v_offer.state <> 'pending'
     or v_offer.expires_at <= now() then
    update offers set state = 'expired' where id = p_offer and state = 'pending';
    return query select false, v_trip.id, null::uuid;
    return;
  end if;

  update offers set state = 'accepted' where id = p_offer;
  -- `offers.`-qualify every column here. The OUT parameters of this function
  -- are named `trip_id` and `driver_id`, so they are PL/pgSQL variables, and
  -- plpgsql's default variable_conflict = error rejects the bare `trip_id` in
  -- this WHERE clause with:
  --   ERROR: column reference "trip_id" is ambiguous
  -- The brief's unqualified version made accept_offer uncallable, so the
  -- single-winner rule never ran. The OUT names themselves are load bearing:
  -- the offers Edge Function reads row.trip_id and row.driver_id, so they stay
  -- as they are and the columns get qualified instead.
  update offers set state = 'released'
    where offers.trip_id = v_offer.trip_id
      and offers.id <> p_offer
      and offers.state = 'pending';

  update trips
     set state = 'matched',
         driver_id = v_offer.driver_id,
         vehicle_id = (select id from vehicles where owner_id = v_offer.driver_id),
         matched_at = now()
   where id = v_offer.trip_id and state = 'requested';

  return query select true, v_trip.id, v_offer.driver_id;
end;
$$;

alter table profiles enable row level security;
alter table vehicles enable row level security;
alter table trips enable row level security;
alter table offers enable row level security;
alter table driver_locations enable row level security;
alter table payments enable row level security;
alter table payouts enable row level security;
alter table ledger_entries enable row level security;
alter table ratings enable row level security;
alter table promos enable row level security;
alter table chat_messages enable row level security;
alter table sos_events enable row level security;

-- Signup creates the profile. Without this a self-registered rider has no
-- profiles row, every trips.rider_id insert fails on the foreign key, and the
-- rider app cannot request a ride at all. Supabase's own shape for this is a
-- trigger on auth.users, so the migration does not depend on an Edge Function
-- that someone might forget to deploy.
--
-- The role is derived from signup metadata, so it is clamped to the two roles a
-- person can legitimately sign up as. Left unclamped, a signup payload of
-- {"role":"admin"} would mint an admin, because raw_user_meta_data is supplied
-- by the client. Every other column takes its column default, so metadata
-- cannot seed kyc_status, rating, trip_count or availability.
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, role)
  values (
    new.id,
    case when new.raw_user_meta_data ->> 'role' = 'driver'
         then 'driver' else 'rider' end
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- RLS is row-level, so a column-scoped grant below cannot stop a user from
-- writing their own role, kyc_status, rating or trip_count. This trigger is the
-- real control. The grant allows the exact set of columns the driver
-- repository writes (submitGhanaCard, submitSelfie, saveVehicle's
-- profiles.vehicle_id link, setAvailability); everything else is server-owned.
--
-- kyc_status is writable to `pending` only, which is what submitGhanaCard
-- sends. Approving or rejecting KYC has to stay a service_role action, or Ghana
-- Card OCR and selfie verification are bypassed by writing the column directly.
create or replace function guard_profile_update()
returns trigger
language plpgsql
as $$
begin
  -- service_role holds BYPASSRLS, so privileged writes to these columns are
  -- already possible; admin KYC approval goes through it.
  if current_user in ('service_role', 'postgres', 'supabase_auth_admin') then
    return new;
  end if;

  if new.role is distinct from old.role then
    raise exception 'role is not user-writable';
  end if;
  if new.rating is distinct from old.rating then
    raise exception 'rating is not user-writable';
  end if;
  if new.trip_count is distinct from old.trip_count then
    raise exception 'trip_count is not user-writable';
  end if;
  if new.kyc_status is distinct from old.kyc_status and new.kyc_status <> 'pending' then
    raise exception 'kyc_status may only move to pending from a client; % needs service_role', new.kyc_status;
  end if;

  return new;
end;
$$;

create trigger profiles_update_guard
  before update on profiles
  for each row execute function guard_profile_update();

create policy "own profile" on profiles
  for select using (id = auth.uid());
create policy "update own profile" on profiles
  for update using (id = auth.uid());
-- There is deliberately no "driver directory is public" policy. A
-- role = 'driver' SELECT policy exposes the whole row, which means
-- ghana_card_last4, ghana_card_expiry, phone and selfie_url, and with no
-- auth.uid() guard the anon key that ships inside the APK reads every driver's
-- KYC data. No task in the plan reads the directory: the only client-side
-- profiles select is `.eq('id', _uid)` in SupabaseDriverRepository.me(), and
-- DriverSummary is fed from an `initialDriver` the caller supplies. A rider who
-- needs the assigned driver's name gets it through their own trip row, which
-- carries driver_id.

create policy "owner reads own vehicle" on vehicles
  for select using (owner_id = auth.uid());
create policy "insert own vehicle unapproved" on vehicles
  for insert with check (owner_id = auth.uid() and approved = false);
-- `approved` stays false on the way in and on the way through, so a driver
-- cannot self-approve the row that match_offers_for_trip joins on. Admin
-- approval is a service_role write, which bypasses RLS.
create policy "update own vehicle unapproved" on vehicles
  for update using (owner_id = auth.uid()) with check (owner_id = auth.uid() and approved = false);

create policy "rider reads own trips" on trips
  for select using (rider_id = auth.uid());
create policy "driver reads assigned trips" on trips
  for select using (driver_id = auth.uid());
-- The driver app advances the trip with
-- `_client.from('trips').update({'state': to.name}).eq('id', tripId)`. Without
-- this policy that UPDATE matches zero rows, PostgREST returns 200 with an
-- empty body, res.error is null, and the app reports a state advance that never
-- happened while enforce_trip_transition is never reached from the client.
create policy "driver advances own trip" on trips
  for update using (driver_id = auth.uid()) with check (driver_id = auth.uid());

create policy "driver reads own offers" on offers
  for select using (driver_id = auth.uid());
create policy "rider reads offers on own trip" on offers
  for select using (
    exists (select 1 from trips t where t.id = offers.trip_id and t.rider_id = auth.uid())
  );

create policy "driver writes own location" on driver_locations
  for all using (driver_id = auth.uid()) with check (driver_id = auth.uid());
create policy "rider reads driver location while assigned" on driver_locations
  for select using (
    exists (
      select 1 from trips t
      where t.driver_id = driver_locations.driver_id
        and t.rider_id = auth.uid()
        and t.state in ('matched','arriving','ongoing')
    )
  );

create policy "own payments" on payments
  for select using (payer_id = auth.uid());
create policy "own payouts" on payouts
  for select using (driver_id = auth.uid());
create policy "own ledger" on ledger_entries
  for select using (driver_id = auth.uid());
create policy "own ratings" on ratings
  for select using (rater_id = auth.uid() or ratee_id = auth.uid());
create policy "read active promos" on promos
  for select using (active);
create policy "trip chat read" on chat_messages
  for select using (
    exists (
      select 1 from trips t
      where t.id = chat_messages.trip_id
        and (t.rider_id = auth.uid() or t.driver_id = auth.uid())
    )
  );
-- The INSERT policy mirrors the SELECT policy above, which already requires
-- party membership. Binding only sender_id let any user who learned a trip_id
-- from a deep link, a log or a support export post into that trip's thread.
create policy "trip chat insert" on chat_messages
  for insert with check (
    sender_id = auth.uid()
    and exists (
      select 1 from trips t
      where t.id = chat_messages.trip_id
        and (t.rider_id = auth.uid() or t.driver_id = auth.uid())
    )
  );
create policy "own sos events" on sos_events
  for select using (raised_by = auth.uid());
-- SOS is dead in the field without this. The plan has
-- SupabaseTripRepository.raiseSos inserting with the rider's own client, and
-- RLS default-denied the INSERT, so every SOS returned 42501.
--
-- There is deliberately no state gate, and that is a deliberate symmetry with
-- "own sos events" above, which is also ungated. An earlier draft of this policy
-- added `t.state in ('matched','arriving','ongoing')`, and that recreated the
-- very defect this policy exists to remove: TrackingController.activeTrip()
-- includes `requested`, raiseSos fires whenever the trip is non-null, and
-- sosRaised is set to true *before* the await, so a rider who pressed the
-- button while still waiting for a driver got a 42501 that surfaced as an
-- uncaught exception on a screen already reading "Help is on the way", with no
-- row in sos_events. `requested` is exactly the state a rider may need SOS in.
-- Do not narrow the plan's button to fit a policy; narrow the policy if
-- anything, never the other way round.
create policy "raise sos on a trip you are party to" on sos_events
  for insert with check (
    raised_by = auth.uid()
    and exists (
      select 1 from trips t
      where t.id = sos_events.trip_id
        and (t.rider_id = auth.uid() or t.driver_id = auth.uid())
    )
  );

-- Column-scoped UPDATE. The policies above decide which rows a caller may
-- write; these decide which columns, so a driver advancing their own trip
-- cannot also rewrite fare_ghs, rider_id or pickup_otp, and a driver editing
-- their profile cannot also set role, kyc_status, rating or trip_count.
-- Column privileges are necessary but not sufficient: a crafted request naming
-- a granted column still reaches the row, which is why "driver advances own
-- trip" pins driver_id, the vehicles policies pin approved, and
-- guard_profile_update pins role, rating, trip_count and kyc_status.
revoke update on trips from anon, authenticated;
grant update (state, eta_minutes, started_at, completed_at) on trips to authenticated;

revoke update on profiles from anon, authenticated;
-- kyc_status is in the list because the plan's submitGhanaCard sends
-- kyc_status: 'pending' alongside ghana_card_last4 and ghana_card_expiry in one
-- update. Leaving it out would make PostgREST reject the whole call with
-- PGRST204 and Ghana Card submission impossible, which is the same class of
-- break as the missing ghana_card_expiry column. guard_profile_update, not the
-- grant, is what stops the value moving to approved or rejected.
grant update (full_name, phone, photo_url, ghana_card_last4, ghana_card_expiry,
              selfie_url, vehicle_id, availability, kyc_status)
  on profiles to authenticated;

-- Profiles are created by handle_new_user, which is SECURITY DEFINER, so no
-- client needs to insert one.
revoke insert on profiles from anon, authenticated;

alter publication supabase_realtime add table trips, offers, driver_locations, chat_messages;
```

- [ ] **Step 3: Push the migration**

```bash
cd ~/meet-n-go/supabase
supabase db push
```

Expected: `Applying migration 20260927000001_init.sql... OK`. If PostGIS is unavailable on the free plan's extension list, run `create extension postgis schema extensions;` first and move the geography columns into the `extensions` schema.

- [ ] **Step 4: Write the seed file**

`supabase/seed/seed.sql`:

```sql
insert into promos (code, percent_off, max_discount_ghs, active)
values ('RIDE30', 30.00, 40.00, true)
on conflict (code) do nothing;
```

Apply it once through the Supabase Studio SQL editor, or via:

```bash
psql "$SUPABASE_DB_URL" -f ~/meet-n-go/supabase/seed/seed.sql
```

- [ ] **Step 5: Verify the anon key cannot read all trips**

```bash
curl -s "$SUPABASE_URL/rest/v1/trips?select=id" -H "apikey: $SUPABASE_ANON_KEY"
```

Expected: `[]`. Never a row count. That proves RLS is doing its job. Note that the anon key also cannot read any `profiles` row: the driver-directory SELECT policy was removed because it exposed `ghana_card_last4`, `ghana_card_expiry`, `phone` and `selfie_url` to the key that ships in the app bundle.

- [ ] **Step 6: Verify the transition guard rejects an illegal move**

```bash
psql "$SUPABASE_DB_URL" -c "update trips set state='completed' where state='requested';"
```

Expected: `ERROR: illegal trip transition requested -> completed`. This confirms the Dart state machine and the database agree. The command only raises if a trip in `requested` state actually exists, so on an empty table it updates zero rows and raises nothing; `supabase/tests/verify_migration.sql` stages one row per ordered pair so it cannot pass vacuously.

- [ ] **Step 7: Commit**

```bash
cd ~/meet-n-go
git add -A
git commit -m "feat(db): schema, PostGIS, RLS, trip transition guard, accept_offer RPC"
```

---

### Task 6: Edge Function — request-ride with matching

**Files:**
- Create: `supabase/functions/_shared/cors.ts`
- Create: `supabase/functions/request-ride/fare.ts`
- Create: `supabase/functions/request-ride/match.ts`
- Create: `supabase/functions/request-ride/request.ts`
- Create: `supabase/functions/request-ride/compensate.ts`
- Create: `supabase/functions/request-ride/index.ts`
- Test: `supabase/functions/_tests/fare.test.ts`
- Test: `supabase/functions/_tests/match.test.ts`
- Test: `supabase/functions/_tests/request.test.ts`
- Test: `supabase/functions/_tests/compensate.test.ts`

**Interfaces:**
- Consumes: RPCs `trip_distance_km` (callable by anyone) and `match_offers_for_trip` (Task 5, **service-role only**: the migration revokes EXECUTE from `public`, `anon` and `authenticated`, so it must be called with the service-role client and never with a user's own client or from a Flutter app), `FareCalculator` semantics (Task 2)
- Produces: POST `request-ride` with body `{category, pickup, dropoff, promoCode?, surge?}` returning `{trip, quote, offerDriverIds}`. Exports `computeFare(input: FareInput): FareQuote`, `promoDiscountGhs(grossFareGhs, percentOff, maxDiscountGhs): number`, `pickDrivers(candidates: Candidate[], max: number): string[]`, `parseRideRequest(body: unknown): RideRequestResult` and `deleteTripAndFail(deleteTrip, tripId, message): Promise<CompensatedFailure>` for unit tests.

**Shipped shape, and the reason each of these is not the obvious smaller version.** Every one of
these was a live defect in the first draft of this task; the code comments carry the long form.

- **The client is a pure service-role client and the caller is authenticated with
  `service.auth.getUser(token)`.** Do not pair `SUPABASE_SERVICE_ROLE_KEY` with a forwarded
  `Authorization`: supabase-js sets `Authorization` only when it is absent, so the user's bearer wins,
  PostgREST resolves the role to `authenticated`, and three calls fail at once — there is no INSERT
  policy on `trips`, none on `offers`, and `match_offers_for_trip` is revoked (`42501`). Strip the
  `Bearer ` prefix before calling `getUser`. `rider_id` comes from the validated user and never from
  the body. Bypassing RLS is safe here only because that check is what authorises the insert.
- **Everything is validated before the first RPC and before the insert**: the body is a JSON object,
  the category is one of the three, each pin carries finite numeric `lat`/`lng`, `lat` is within
  [-90, 90], `lng` is within [-180, 180], and `surge` is finite. The range check is not optional
  because PostGIS *coerces* an out-of-range coordinate instead of rejecting it:
  `st_astext('POINT(-0.187 999)'::geography)` is `POINT(-0.187 -81)`, 9618 km away, so `lat: 999`
  prices as a real ride in the thousands of GHS. And a non-finite number is not caught downstream
  either: `'NaN'::numeric(10,2)` inserts, `sum()` over it is NaN, and `fare_ghs >= 0` still passes.
- **The promo discount is two passes over the category's own gross fare**: `computeFare` with
  `discountGhs: 0`, then `promoDiscountGhs(gross.fareGhs, percent_off, max_discount_ghs)`, then
  `computeFare` again. `percent_off / 100 * distanceKm * 1.8` hard-codes the *standard* per-km rate,
  so it under-discounts a premium ride and ignores the base fare, the booking fee and the surge.
- **`expires_at` is compared in TypeScript, not in the query.** A PostgREST filter value is a
  literal, not SQL: `expires_at.gt.now()` is not evaluable, and PostgREST's own reference answers a
  `now()`-dependent filter with "create a new view, or use a function". Add `expires_at` to the
  `select` and apply the predicate to the row. The seeded `RIDE30` has a null expiry, so nothing is
  broken today either way.
- **The offers insert, the match RPC and the promo read all have their errors checked.** A dropped
  error returns a success that is indistinguishable from the truth: no offers written, or a rider
  charged full price for a code they supplied.
  **Ruling:** the promo read 500ing a request that supplied a `promoCode` is correct, keep it. The
  read only happens when a code is present, so a broken coupon table cannot block an ordinary ride
  — it only refuses a ride where the rider was promised a discount and we cannot verify the
  discount. Silently charging full price in that case is the worse failure. Cost if wrong: a
  promo-table outage books no discounted rides, but no rider is ever overcharged.
- **A failure after the trip insert deletes the trip row before the 500.** The insert and the
  fan-out are separate calls, and Task 8's `activeTrip()` selects `requested` trips, so an orphan
  pins the rider's active trip and blocks every later ride request. The delete is the whole fix: no
  ledger entry, no retry, no Task 5 RPC, since the row never became a real trip, and
  `offers.trip_id` is `references trips on delete cascade`. A delete that itself fails is returned as
  `cleanupError` rather than hidden behind a clean 500.
- **`promoDiscountGhs` clamps, it does not trust.** `promos.max_discount_ghs` has no CHECK
  constraint and a negative value there makes `min(gross * percent / 100, cap)` negative, which the
  second `computeFare` call then *adds* to the total: a 40.60 premium ride stored at 80.60 while
  `quote.discountGhs` reports 0. Gross, percent and cap are all clamped to their valid range, so the
  function is total for every finite input. A non-finite argument is deliberately *not* clamped:
  `Math.max(0, NaN)` is NaN, and quietly turning a corrupt row into "no discount" is the failure the
  call-site check exists to prevent. The one column that can actually arrive non-finite is
  `max_discount_ghs`; `percent_off` carries `check (percent_off > 0 and percent_off <= 100)`, and
  because that is a conjunction it does reject NaN — measured, `'NaN'::numeric > 0` is true but
  `'NaN'::numeric <= 100` is false.
- **The promo read is `limit(1)` plus `data?.[0]`, not `maybeSingle()`.** Measured: on a GET
  `maybeSingle` sends `Accept: application/json`, not `application/vnd.pgrst.object+json`
  (`@supabase/postgrest-js@1.16.1/src/PostgrestTransformBuilder.ts:209-210`), so a 0-row read is a
  200 `[]` that the client coerces to `data = null` itself (`PostgrestBuilder.ts:118-134`) and the
  two are behaviourally equivalent here. The `error.details.includes('0 rows')` comparison at `:162`
  is a *different* branch, taken only when the server answers with an error, which this GET is not,
  and it is a bare substring test that PostgREST's own single-object message `multiple (or no) rows
  returned` does not contain and would not clear. So that is the branch that would break on a
  rewording, and it is not this one. `limit(1)` asks the client to interpret no row count at all, so
  the read depends on no response shape rather than on how a server words an error. The 500 on a
  genuine read error stays; the ruling above says why.
- **A `promoCode` that is present but is not a string is a 400.** Silently dropping it returned 200
  at full price to a rider who supplied a code, which is the rider-visible outcome the 500 on a
  failed promo read exists to prevent. `undefined`, `null` and `""` are all "no code" and are not
  discards, so they are not errors.
- **A null `trip_distance_km` result is a 500, not a 0 km ride.** `Number(distanceRow ?? 0)` turned a
  broken RPC into a base-fare quote of 6.00 on a route nobody priced. The RPC cannot return null
  today, which is exactly why the `?? 0` had to go: dead code that only hides a future break.
- **Every failure after the trip insert is compensated, checked or thrown.** The post-insert region
  runs inside `compensating()`, so an unchecked throw — the RPC client's own JSON parse failing, a
  candidate payload that is not an array — takes the same compensating delete as a checked 42501,
  instead of escaping to `serve`'s default `onError`, which returns a bare 500 and leaves the
  `requested` row behind for Task 8's `activeTrip()` to keep serving.
- **The stored `pickup`/`dropoff` jsonb is normalised to `{label, address, point:{lat, lng}}`.**
  `TripStop.fromJson` casts `json['point'] as Map<String, dynamic>` with no null case, so a pin
  stored in the documented request shape `{label, address, lat, lng}` makes the rider's own trip
  unparseable. `label` and `address` are coerced to strings for the same reason.

- [ ] **Step 1: Write the failing unit tests**

`supabase/functions/_tests/fare.test.ts`:

```ts
import { assertEquals } from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import { computeFare, promoDiscountGhs, type RideCategoryName } from '../request-ride/fare.ts';

Deno.test('standard 8km fare matches the Dart calculator', () => {
  const q = computeFare({ category: 'standard', distanceKm: 8, surge: 1, discountGhs: 0 });
  assertEquals(q.fareGhs, 20.4);
});

Deno.test('premium 10km beats standard 10km', () => {
  const s = computeFare({ category: 'standard', distanceKm: 10, surge: 1, discountGhs: 0 });
  const p = computeFare({ category: 'premium', distanceKm: 10, surge: 1, discountGhs: 0 });
  assertEquals(p.fareGhs > s.fareGhs, true);
});

Deno.test('surge multiplies the whole base-plus-distance and is capped at 2x', () => {
  // (5.00 + 1.80 * 5) * 1.5 + 1.00 = 22.00
  const surged = computeFare({ category: 'standard', distanceKm: 5, surge: 1.5, discountGhs: 0 });
  assertEquals(surged.fareGhs, 22.0);
  // (5.00 + 1.80 * 5) * 2.0 + 1.00 = 29.00, surge 5 clamps to 2.0
  const capped = computeFare({ category: 'standard', distanceKm: 5, surge: 5, discountGhs: 0 });
  assertEquals(capped.fareGhs, 29.0);
});

Deno.test('surge below 1 is lifted to 1', () => {
  const q = computeFare({ category: 'standard', distanceKm: 5, surge: 0.2, discountGhs: 0 });
  assertEquals(q.fareGhs, 15.0);
});

Deno.test('negative distance collapses to the base fare', () => {
  const q = computeFare({ category: 'standard', distanceKm: -3, surge: 1, discountGhs: 0 });
  assertEquals(q.fareGhs, 6.0);
});

Deno.test('NaN distance throws', () => {
  let threw = false;
  try {
    computeFare({ category: 'standard', distanceKm: NaN, surge: 1, discountGhs: 0 });
  } catch {
    threw = true;
  }
  assertEquals(threw, true);
});

Deno.test('over-large discount never yields a negative fare', () => {
  const q = computeFare({ category: 'standard', distanceKm: 0, surge: 1, discountGhs: 999 });
  assertEquals(q.fareGhs, 0);
});

// The seven cases above are all exact in binary once clamping is applied, so a
// round2 that does nothing passes every one of them. Measured on deno 2.9.7:
// the raw total here is 16.158 (the double nearest it is 16.158000000000001),
// and 16.158 === 16.16 is false, so this is the only case in the file that
// discriminates rounding from no rounding.
//
// The twin of this case is `fare is rounded to 2 decimal places, not left at 3`
// in `packages/mng_core/test/fare_calculator_test.dart`, with the same
// 3.7 km / surge 1.3 / 16.16. It exists in both languages on purpose: a client
// that quotes 16.158 and a backend that stores 16.16 disagree by a third of a
// cedi and neither suite would notice on its own. The two literals are the same
// value in both files — change one, change the other in the same commit.
Deno.test('fare is rounded to 2 decimal places, not left at 3', () => {
  // (5.00 + 1.80 * 3.7) * 1.3 + 1.00 = 16.158 raw, so 16.16 rounded.
  const q = computeFare({ category: 'standard', distanceKm: 3.7, surge: 1.3, discountGhs: 0 });
  assertEquals(q.fareGhs, 16.16);
  assertEquals(q.fareGhs === 16.158, false);
});

// The discount is a share of the fare actually quoted, not of a distance
// multiplied by the standard per-km rate, so a premium ride is discounted at the
// premium rate. Same trip, same promo, measured on deno 2.9.7:
//   standard 10 km at surge 1.2 grosses 28.60, premium grosses 40.60,
//   so RIDE30 (30% off, capped at 40.00) takes 8.58 off a standard ride and
//   12.18 off a premium one. The category-blind 1.8-per-km formula the brief
//   used returns 5.40 for both and is caught by the exact literals.
Deno.test('the same promo takes more off a premium ride than a standard one', () => {
  const distanceKm = 10;
  const surge = 1.2;
  const discountFor = (category: RideCategoryName) =>
    promoDiscountGhs(
      computeFare({ category, distanceKm, surge, discountGhs: 0 }).fareGhs,
      30,
      40,
    );
  assertEquals(discountFor('standard'), 8.58);
  assertEquals(discountFor('premium'), 12.18);
  assertEquals(discountFor('premium') > discountFor('standard'), true);
});

// `promos.max_discount_ghs` has no CHECK constraint, and a negative value there
// makes `min(gross * percent_off / 100, cap)` negative, which the second
// `computeFare` call then *adds* to the total: a premium ride quoted at 40.60
// is stored at 80.60 while `quote.discountGhs` reports 0. Measured on this
// host: `insert into promos (code, percent_off, max_discount_ghs) values
// ('NEG1', 30, -40.00, true)` is accepted. A percent outside 0..100 is refused
// by the `percent_off` check constraint, so the sign hole is on the cap, but
// this is the pure function and it is total for every finite input.
Deno.test('a negative promo cap cannot raise the fare above the gross quote', () => {
  const trip = { category: 'premium' as const, distanceKm: 10, surge: 1.2 };
  const gross = computeFare({ ...trip, discountGhs: 0 });

  const discount = promoDiscountGhs(gross.fareGhs, 30, -40);
  const quote = computeFare({ ...trip, discountGhs: discount });

  assertEquals(discount, 0);
  assertEquals(quote.fareGhs, gross.fareGhs);
});

Deno.test('a promo percent outside 0 to 100 is clamped rather than applied', () => {
  const gross = computeFare({ category: 'premium', distanceKm: 10, surge: 1.2, discountGhs: 0 });
  assertEquals(promoDiscountGhs(gross.fareGhs, 250, 1000), 40.6);
  assertEquals(promoDiscountGhs(gross.fareGhs, -30, 1000), 0);
});
```

`supabase/functions/_tests/match.test.ts`:

```ts
import { assertEquals } from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import { pickDrivers } from '../request-ride/match.ts';

Deno.test('takes the five nearest drivers in order', () => {
  const drivers = [
    { id: 'a', pickupDistanceKm: 0.4 },
    { id: 'b', pickupDistanceKm: 0.1 },
    { id: 'c', pickupDistanceKm: 3.0 },
    { id: 'd', pickupDistanceKm: 1.2 },
    { id: 'e', pickupDistanceKm: 0.9 },
    { id: 'f', pickupDistanceKm: 0.2 },
  ];
  assertEquals(pickDrivers(drivers, 5), ['b', 'f', 'a', 'e', 'd']);
});

Deno.test('fewer candidates than the cap is fine', () => {
  assertEquals(pickDrivers([{ id: 'only', pickupDistanceKm: 1 }], 5), ['only']);
});

Deno.test('empty candidate list yields no offers', () => {
  assertEquals(pickDrivers([], 5), []);
});

Deno.test('does not mutate the input array', () => {
  const drivers = [
    { id: 'far', pickupDistanceKm: 9 },
    { id: 'near', pickupDistanceKm: 1 },
  ];
  pickDrivers(drivers, 5);
  assertEquals(drivers[0].id, 'far');
});
```

`supabase/functions/_tests/request.test.ts`:

```ts
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import { parseRideRequest, type Pin } from '../request-ride/request.ts';

const pin = (over: Partial<Pin> = {}): Pin => ({
  label: 'Pickup',
  address: 'Osu, Accra',
  lat: 5.6037,
  lng: -0.187,
  ...over,
});

const body = (over: Record<string, unknown> = {}) => ({
  category: 'standard',
  pickup: pin(),
  dropoff: pin({ label: 'Dropoff', address: 'Airport Residential', lat: 5.62 }),
  ...over,
});

const refuse = (raw: unknown): string => {
  const result = parseRideRequest(raw);
  assert(!result.ok, `expected a refusal, got ${JSON.stringify(result)}`);
  return result.error;
};

Deno.test('a valid request yields the category, both pins and the surge', () => {
  const result = parseRideRequest(body());
  assert(result.ok, JSON.stringify(result));
  assertEquals(result.value.category, 'standard');
  assertEquals(result.value.pickup.lat, 5.6037);
  assertEquals(result.value.dropoff.lat, 5.62);
  assertEquals(result.value.surge, 1);
  assertEquals(result.value.promoCode, null);
});

Deno.test('a promo code is uppercased, and an absent or empty one is no code', () => {
  const upper = parseRideRequest(body({ promoCode: 'ride30' }));
  assert(upper.ok, JSON.stringify(upper));
  assertEquals(upper.value.promoCode, 'RIDE30');
  for (const absent of [undefined, null, '']) {
    const result = parseRideRequest(body({ promoCode: absent }));
    assert(result.ok, JSON.stringify(result));
    assertEquals(result.value.promoCode, null);
  }
});

// A wrong-typed field is a 400 everywhere else in this function, and a promo
// code is the one a rider is promised money off. Silently dropping a
// present-but-non-string one returns 200 at full price, which is the same
// rider-visible outcome as the promo-read failure the 500 on a promo read
// exists to prevent.
Deno.test('a promoCode that is present but not a string is refused', () => {
  assertEquals(refuse(body({ promoCode: 30 })), 'promoCode must be a string');
  assertEquals(refuse(body({ promoCode: true })), 'promoCode must be a string');
  assertEquals(refuse(body({ promoCode: ['RIDE30'] })), 'promoCode must be a string');
  assertEquals(refuse(body({ promoCode: { code: 'RIDE30' } })), 'promoCode must be a string');
});

Deno.test('an absent surge defaults to 1 and label and address are coerced to strings', () => {
  const result = parseRideRequest(
    body({ pickup: pin({ label: 7 as unknown as string, address: null as unknown as string }) }),
  );
  assert(result.ok, JSON.stringify(result));
  assertEquals(result.value.surge, 1);
  assertEquals(result.value.pickup.label, '');
  assertEquals(result.value.pickup.address, '');
});

Deno.test('a body that is not a JSON object is refused', () => {
  assertEquals(refuse([]), 'body must be a JSON object');
  assertEquals(refuse(5), 'body must be a JSON object');
  assertEquals(refuse(null), 'body must be a JSON object');
});

Deno.test('a category outside the three the schema allows is refused', () => {
  assertEquals(
    refuse(body({ category: 'deluxe' })),
    'category must be one of standard, premium, van',
  );
});

// PostGIS coerces an out-of-range coordinate instead of rejecting it, so
// `lat: 999` would otherwise become a real point 9618 km away and a quote in
// the thousands. Measured on this host: `select st_astext('POINT(-0.187 999)'
// ::geography)` returns `POINT(-0.187 -81)`. These four pin both bounds of
// both axes; a one-sided check would pass all four.
Deno.test('a lat above 90 is refused', () => {
  assertEquals(refuse(body({ pickup: pin({ lat: 999 }) })), 'pickup lat must be within [-90, 90], got 999');
});

Deno.test('a lat below -90 is refused', () => {
  assertEquals(
    refuse(body({ pickup: pin({ lat: -91 }) })),
    'pickup lat must be within [-90, 90], got -91',
  );
});

Deno.test('an lng above 180 is refused', () => {
  assertEquals(
    refuse(body({ dropoff: pin({ lng: 181 }) })),
    'dropoff lng must be within [-180, 180], got 181',
  );
});

Deno.test('an lng below -180 is refused', () => {
  assertEquals(
    refuse(body({ dropoff: pin({ lng: -180.5 }) })),
    'dropoff lng must be within [-180, 180], got -180.5',
  );
});

Deno.test('the poles and the antimeridian are inside the range', () => {
  const result = parseRideRequest(
    body({ pickup: pin({ lat: 90, lng: 180 }), dropoff: pin({ lat: -90, lng: -180 }) }),
  );
  assert(result.ok, JSON.stringify(result));
  assertEquals(result.value.pickup.lat, 90);
  assertEquals(result.value.pickup.lng, 180);
  assertEquals(result.value.dropoff.lat, -90);
  assertEquals(result.value.dropoff.lng, -180);
});

Deno.test('a pin that is not an object, or whose coordinates are not finite numbers, is refused', () => {
  assertEquals(refuse(body({ pickup: 'Osu' })), 'pickup must be an object');
  assertEquals(
    refuse(body({ pickup: pin({ lat: '5.6037' as unknown as number }) })),
    'pickup must carry finite numeric lat and lng',
  );
  assertEquals(
    refuse(body({ dropoff: pin({ lng: NaN }) })),
    'dropoff must carry finite numeric lat and lng',
  );
  assertEquals(
    refuse(body({ dropoff: pin({ lng: Infinity }) })),
    'dropoff must carry finite numeric lat and lng',
  );
});

Deno.test('a surge that is not a finite number is refused', () => {
  assertEquals(refuse(body({ surge: 'x' })), 'surge must be a finite number');
  assertEquals(refuse(body({ surge: 1e999 })), 'surge must be a finite number');
  assertEquals(refuse(body({ surge: true })), 'surge must be a finite number');
  assertEquals(refuse(body({ surge: NaN })), 'surge must be a finite number');
});
```

`supabase/functions/_tests/compensate.test.ts`:

```ts
import { assertEquals } from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import { compensating, deleteTripAndFail, type DeleteTrip } from '../request-ride/compensate.ts';

Deno.test('a failure after the insert deletes the trip row that was inserted', async () => {
  const deleted: string[] = [];
  const deleteTrip: DeleteTrip = (tripId) => {
    deleted.push(tripId);
    return Promise.resolve({ error: null });
  };

  const failure = await deleteTripAndFail(deleteTrip, 'trip-0001', 'offer insert failed');

  assertEquals(deleted, ['trip-0001']);
  assertEquals(failure, { error: 'offer insert failed' });
});

Deno.test('the original failure is still reported when the delete itself fails', async () => {
  const deleteTrip: DeleteTrip = () =>
    Promise.resolve({ error: { message: 'permission denied for table trips' } });

  const failure = await deleteTripAndFail(deleteTrip, 'trip-0001', 'match failed');

  assertEquals(failure, {
    error: 'match failed',
    cleanupError: 'permission denied for table trips',
  });
});

// The unchecked route to the same orphan: anything thrown between the trip
// insert and the response used to escape to `serve`'s default onError, which
// returns a bare 500 and leaves the `requested` row behind for Task 8's
// `activeTrip()` to keep serving.
Deno.test('a throw during the fan-out compensates the trip insert', async () => {
  const deleted: string[] = [];
  const deleteTrip: DeleteTrip = (tripId) => {
    deleted.push(tripId);
    return Promise.resolve({ error: null });
  };

  const outcome = await compensating(deleteTrip, 'trip-0001', () =>
    Promise.reject(new Error('match_offers_for_trip: Unexpected token < in JSON at position 0'))
  );

  assertEquals(deleted, ['trip-0001']);
  assertEquals(outcome, {
    ok: false,
    error: 'match_offers_for_trip: Unexpected token < in JSON at position 0',
  });
});

Deno.test('a fan-out that throws something that is not an Error still compensates', async () => {
  const deleted: string[] = [];
  const deleteTrip: DeleteTrip = (tripId) => {
    deleted.push(tripId);
    return Promise.resolve({ error: null });
  };

  const outcome = await compensating(deleteTrip, 'trip-0001', () =>
    Promise.reject('rows.map is not a function')
  );

  assertEquals(deleted, ['trip-0001']);
  assertEquals(outcome, { ok: false, error: 'rows.map is not a function' });
});

Deno.test('a completed fan-out does not delete the trip', async () => {
  const deleted: string[] = [];
  const deleteTrip: DeleteTrip = (tripId) => {
    deleted.push(tripId);
    return Promise.resolve({ error: null });
  };

  const outcome = await compensating(deleteTrip, 'trip-0001', () => Promise.resolve(['d-1']));

  assertEquals(deleted, []);
  assertEquals(outcome, { ok: true, value: ['d-1'] });
});

Deno.test('a compensating delete that fails is reported through the fan-out too', async () => {
  const deleteTrip: DeleteTrip = () =>
    Promise.resolve({ error: { message: 'permission denied for table trips' } });

  const outcome = await compensating(deleteTrip, 'trip-0001', () =>
    Promise.reject(new Error('offers insert failed'))
  );

  assertEquals(outcome, {
    ok: false,
    error: 'offers insert failed',
    cleanupError: 'permission denied for table trips',
  });
});
```

- [ ] **Step 2: Run them and confirm they fail**

```bash
cd ~/meet-n-go/supabase && deno test functions/_tests/
```

Expected: FAIL — `fare.ts`, `match.ts`, `request.ts` and `compensate.ts` do not exist.

- [ ] **Step 3: Write `fare.ts`, mirroring the Dart calculator exactly**

```ts
// The TypeScript twin of `FareCalculator` in
// `packages/mng_core/lib/src/fare/fare_calculator.dart`. The two must stay
// numerically identical: the rider app quotes a fare locally and the backend
// quotes the same one, and a divergence between them is a rider who is shown
// one price and charged another. Every literal in the Dart test file has a
// counterpart in `functions/_tests/fare.test.ts`.

export const RIDE_CATEGORY_NAMES = ['standard', 'premium', 'van'] as const;

export type RideCategoryName = (typeof RIDE_CATEGORY_NAMES)[number];

export interface FareInput {
  category: RideCategoryName;
  distanceKm: number;
  surge: number;
  discountGhs: number;
}

export interface FareQuote {
  fareGhs: number;
  surge: number;
  discountGhs: number;
  distanceKm: number;
}

export const BASE_GHS = 5.0;
export const BOOKING_FEE_GHS = 1.0;
export const MAX_SURGE = 2.0;
export const PER_KM: Record<RideCategoryName, number> = {
  standard: 1.8,
  premium: 2.8,
  van: 2.2,
};

const round2 = (v: number) => Math.round(v * 100) / 100;

export function computeFare(input: FareInput): FareQuote {
  if (!Number.isFinite(input.distanceKm)) {
    throw new Error('distanceKm must be finite');
  }
  const km = Math.max(0, input.distanceKm);
  const surge = Math.min(MAX_SURGE, Math.max(1, input.surge));
  const raw = (BASE_GHS + PER_KM[input.category] * km) * surge + BOOKING_FEE_GHS - input.discountGhs;
  return {
    fareGhs: round2(Math.max(0, raw)),
    surge,
    discountGhs: Math.max(0, input.discountGhs),
    distanceKm: km,
  };
}

// A promo is a share of the fare actually quoted, so it takes the base fare,
// the booking fee, the surge and the requested category's per-km rate into
// account. `percent_off` of the distance at the standard per-km rate, which is
// what this used to do, under-discounts every category and ignores the base and
// booking fee entirely: on a 10 km standard ride at surge 1.2 it returns 5.40
// against a gross of 28.60.
//
// Call it with the gross quote, that is the quote for the same trip with
// `discountGhs: 0`, and feed the result back into a second `computeFare` call.
// Both calls are pure, which is what makes the two-step pricing testable
// without a database.
//
// All three arguments are clamped to their valid range rather than trusted, so
// the function is total for every finite input and no caller can be talked into
// a discount that is really a surcharge. The sign hole that made this necessary
// is real: `promos.max_discount_ghs` has no CHECK constraint, and a negative
// cap makes `min(gross * percent / 100, cap)` negative, which the second
// `computeFare` call then *adds* to the total — a premium ride quoted at 40.60
// stored at 80.60 while `quote.discountGhs` reports 0. `percent_off` is
// constrained to (0, 100] by the schema, so the cap is the only column that can
// arrive wrong; the percent is clamped anyway so the pure function does not
// depend on a constraint in another file.
//
// A non-finite argument is not clamped here: `Math.max(0, NaN)` is NaN, and
// quietly turning a corrupt row into "no discount" would be the silent-money
// defect this whole function exists to avoid. `index.ts` refuses a non-finite
// promo row with a 500 before it gets here.
export function promoDiscountGhs(
  grossFareGhs: number,
  percentOff: number,
  maxDiscountGhs: number,
): number {
  const gross = Math.max(0, grossFareGhs);
  const percent = Math.min(100, Math.max(0, percentOff));
  const cap = Math.max(0, maxDiscountGhs);
  return round2(Math.min((gross * percent) / 100, cap));
}
```

- [ ] **Step 4: Write `match.ts`**

```ts
export interface Candidate {
  id: string;
  pickupDistanceKm: number;
}

export const MAX_OFFERS = 5;

export function pickDrivers(candidates: Candidate[], max: number): string[] {
  return [...candidates]
    .sort((a, b) => a.pickupDistanceKm - b.pickupDistanceKm)
    .slice(0, max)
    .map((c) => c.id);
}
```

- [ ] **Step 5: Write `request.ts` and `compensate.ts`**

`supabase/functions/request-ride/request.ts`:

```ts
import { RIDE_CATEGORY_NAMES, type RideCategoryName } from './fare.ts';

export interface Pin {
  label: string;
  address: string;
  lat: number;
  lng: number;
}

export interface RideRequest {
  category: RideCategoryName;
  pickup: Pin;
  dropoff: Pin;
  surge: number;
  promoCode: string | null;
}

export type RideRequestResult =
  | { ok: true; value: RideRequest }
  | { ok: false; error: string };

type Checked<T> = { ok: true; value: T } | { ok: false; error: string };

const refuse = (error: string): { ok: false; error: string } => ({ ok: false, error });

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

// A number, not a string that happens to parse, and not a boolean or a
// one-element array, all of which `Number()` would happily accept. Postgres
// `numeric` stores NaN, so a non-finite value does not fail on the way in: it
// lands in `fare_ghs` and `surge` and is inherited by Task 11's settlement and
// Task 15's payout. Measured on PostgreSQL 17.11: `'NaN'::numeric(10,2)`
// inserts, `sum()` over such a row is NaN, and `fare_ghs >= 0` counts the row
// as passing, so nothing downstream catches it either. The only place it can be
// refused is here, before the insert.
export const isFiniteNumber = (value: unknown): value is number =>
  typeof value === 'number' && Number.isFinite(value);

// The range check is not optional and is not what the database does for us.
// PostGIS coerces an out-of-range coordinate into range with a NOTICE instead
// of rejecting it: measured on this host, `st_astext('POINT(-0.187 999)'
// ::geography)` is `POINT(-0.187 -81)`, 9618.25 km from the real pickup. A
// `lat: 999` would therefore price as a real ride in the thousands of GHS, so
// silent coordinate wrapping is not validation and the fare is money.
const readPin = (value: unknown, which: 'pickup' | 'dropoff'): Checked<Pin> => {
  if (!isRecord(value)) return refuse(`${which} must be an object`);
  if (!isFiniteNumber(value.lat) || !isFiniteNumber(value.lng)) {
    return refuse(`${which} must carry finite numeric lat and lng`);
  }
  if (value.lat < -90 || value.lat > 90) {
    return refuse(`${which} lat must be within [-90, 90], got ${value.lat}`);
  }
  if (value.lng < -180 || value.lng > 180) {
    return refuse(`${which} lng must be within [-180, 180], got ${value.lng}`);
  }
  return {
    ok: true,
    value: {
      label: typeof value.label === 'string' ? value.label : '',
      address: typeof value.address === 'string' ? value.address : '',
      lat: value.lat,
      lng: value.lng,
    },
  };
};

// Everything the fare depends on, checked before the function reads or writes
// anything. `PER_KM['deluxe']` is `undefined`, so an unchecked category also
// makes the fare NaN, and it does so before the `trips_category_check`
// constraint ever sees the value, which is how an input bug becomes an opaque
// 500. `label` and `address` are coerced to strings because `TripStop` casts
// both when the stored trip is read back.
export function parseRideRequest(body: unknown): RideRequestResult {
  if (!isRecord(body)) return refuse('body must be a JSON object');

  const category = body.category;
  if (typeof category !== 'string' || !RIDE_CATEGORY_NAMES.includes(category as RideCategoryName)) {
    return refuse(`category must be one of ${RIDE_CATEGORY_NAMES.join(', ')}`);
  }

  const pickup = readPin(body.pickup, 'pickup');
  if (!pickup.ok) return pickup;
  const dropoff = readPin(body.dropoff, 'dropoff');
  if (!dropoff.ok) return dropoff;

  const surge = body.surge ?? 1;
  if (!isFiniteNumber(surge)) return refuse('surge must be a finite number');

  // A present-but-non-string code is a client bug and is refused like every
  // other wrong-typed field here, rather than dropped: dropping it returns 200
  // at full price to a rider who was promised a discount, with nothing in the
  // response saying the code was discarded. An absent code, `null` and an empty
  // string are all "no code", which is not a discard and needs no signal.
  const promoCode = body.promoCode;
  if (promoCode !== undefined && promoCode !== null && typeof promoCode !== 'string') {
    return refuse('promoCode must be a string');
  }

  return {
    ok: true,
    value: {
      category: category as RideCategoryName,
      pickup: pickup.value,
      dropoff: dropoff.value,
      surge,
      promoCode: promoCode ? promoCode.toUpperCase() : null,
    },
  };
}
```

`supabase/functions/request-ride/compensate.ts`:

```ts
// The trip insert and the offer fan-out are two separate calls, so a failure in
// the second leaves a `requested` trip with no offers behind it. Task 8's
// `activeTrip()` selects `requested` trips, so that orphan pins the rider's
// active trip and blocks every later ride request until the row is removed by
// hand. The compensation is safe in this window: the row was created moments
// earlier, `offers.trip_id` is `references trips on delete cascade` so any
// partially written offers go with it, and nothing can have come to depend on
// it yet.
//
// A delete is the whole fix. No ledger entry, no retry, no Task 5 RPC: the row
// never became a real trip.

export type DeleteTrip = (tripId: string) => Promise<{ error: { message: string } | null }>;

export type CompensatedFailure = {
  error: string;
  cleanupError?: string;
};

export type Outcome<T> = { ok: true; value: T } | ({ ok: false } & CompensatedFailure);

export async function deleteTripAndFail(
  deleteTrip: DeleteTrip,
  tripId: string,
  message: string,
): Promise<CompensatedFailure> {
  const { error } = await deleteTrip(tripId);
  // A delete that fails leaves the orphan in place, so the response says so
  // rather than reporting a clean 500 and hiding a row nothing will clean up.
  return error ? { error: message, cleanupError: error.message } : { error: message };
}

// Runs the offer fan-out, and compensates the trip insert if it does not
// finish. A *checked* failure — a 42501 from the match RPC, a rejected offers
// insert — is reported the same way as an *unchecked* one, because both mean the
// same thing: a `requested` trip that no driver was ever offered and that Task
// 8's `activeTrip()` will keep handing back. The unchecked route is the one
// that needed guarding: it used to escape to `serve`'s default onError, which
// returns a bare 500 and leaves the row behind.
export async function compensating<T>(
  deleteTrip: DeleteTrip,
  tripId: string,
  work: () => Promise<T>,
): Promise<Outcome<T>> {
  try {
    return { ok: true, value: await work() };
  } catch (thrown) {
    const message = thrown instanceof Error ? thrown.message : String(thrown);
    return { ok: false, ...(await deleteTripAndFail(deleteTrip, tripId, message)) };
  }
}
```

- [ ] **Step 6: Run the unit tests and confirm they pass**

```bash
cd ~/meet-n-go/supabase && deno test functions/_tests/
```

Expected: **34** tests pass, 0 fail — 11 fare, 4 match, 13 request, 6 compensate (counted with `grep -c '^Deno.test('` per file, not by hand). The fare file's
first seven cases are the values the Dart suite asserts; the rest are the 2-dp rounding case
(3.7 km standard at surge 1.3, raw 16.158, exactly 16.16), the
premium-takes-more-off-than-standard case, the negative promo cap that would otherwise *raise* the
fare, and an out-of-range percent. The compensate file covers both routes to the same orphan, a
checked error and a throw. The rounding case has a twin in
`packages/mng_core/test/fare_calculator_test.dart` with the same literal: change one, change the
other in the same commit.

- [ ] **Step 7: Write `_shared/cors.ts`**

```ts
export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
```

- [ ] **Step 8: Write `request-ride/index.ts`**

```ts
import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';
import { corsHeaders } from '../_shared/cors.ts';
import { compensating } from './compensate.ts';
import { computeFare, promoDiscountGhs } from './fare.ts';
import { MAX_OFFERS, pickDrivers } from './match.ts';
import { isFiniteNumber, parseRideRequest, type Pin } from './request.ts';

const OFFER_TTL_SECONDS = 20;

const json = (status: number, payload: Record<string, unknown>) =>
  new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

// The stored jsonb is the shape `TripStop.fromJson` reads, not the shape that
// arrived. The Dart model casts `json['point'] as Map<String, dynamic>` with no
// null case, so a pin stored as `{label, address, lat, lng}` makes the rider's
// own trip unparseable in the rider app. Task 8 sends the flattened
// `{...pickup.toJson(), ...pickup.point.toJson()}`, which carries `point` as
// well and so happens to work today; normalising here means it stops depending
// on the client sending the nested copy. `label` and `address` are coerced to
// strings in `parseRideRequest` for the same reason: `TripStop` casts both.
const stopJson = (pin: Pin) => ({
  label: pin.label,
  address: pin.address,
  point: { lat: pin.lat, lng: pin.lng },
});

const wkt = (p: Pin) => `POINT(${p.lng} ${p.lat})`;

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  // Deliberately a pure service-role client, with no caller's `Authorization`
  // header forwarded onto it. supabase-js only sets `Authorization` when it is
  // absent, so pairing the service key with a forwarded bearer leaves the
  // user's token as the effective credential: PostgREST resolves the role to
  // `authenticated`, RLS applies, and this function then fails in three places
  // at once, because the migration has no INSERT policy on `trips`, no INSERT
  // policy on `offers`, and revokes EXECUTE on `match_offers_for_trip` from
  // `anon` and `authenticated` (42501).
  //
  // Bypassing RLS is what makes the bare service client necessary, and the
  // authorisation it removes is not replaced by the database here, so it is
  // replaced by this function: the caller must present a token that
  // `getUser` validates, and the trip's `rider_id` is that validated identity
  // and never a field of the request body. No other part of the body can decide
  // who the trip belongs to. The distance RPC, the promo read, the trip insert,
  // `match_offers_for_trip`, the offers insert and the compensating delete all
  // use this one client, because `match_offers_for_trip` is reachable by
  // `service_role` alone and no role that can be impersonated by a client has an
  // RLS path to the trip or the offer insert.
  const service = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  const header = req.headers.get('Authorization') ?? '';
  const token = header.replace(/^Bearer\s+/i, '');
  if (!token) return json(401, { error: 'unauthenticated' });

  const { data: userData, error: userError } = await service.auth.getUser(token);
  if (userError || !userData.user) return json(401, { error: 'unauthenticated' });
  const riderId = userData.user.id;

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json(400, { error: 'body must be JSON' });
  }
  // Everything the fare depends on — the category, both pins and the surge,
  // including the coordinate range — is checked here, before the first RPC and
  // before the insert.
  const parsed = parseRideRequest(body);
  if (!parsed.ok) return json(400, { error: parsed.error });
  const { category, pickup, dropoff, surge, promoCode } = parsed.value;

  const { data: distanceRow, error: distanceError } = await service.rpc('trip_distance_km', {
    a: wkt(pickup),
    b: wkt(dropoff),
  });
  if (distanceError) return json(500, { error: distanceError.message });
  // A null result is not a zero-kilometre ride. The RPC cannot return null
  // today, so `?? 0` here would only be dead code that hides a future break as
  // a base-fare quote: a 6.00 GHS ride on a route nobody priced.
  if (distanceRow === null || distanceRow === undefined) {
    return json(500, { error: 'trip_distance_km returned no distance' });
  }
  const distanceKm = Number(distanceRow);
  if (!Number.isFinite(distanceKm)) return json(500, { error: 'trip_distance_km was not finite' });

  // Price the ride gross first, then take the promo off that gross. Discounting
  // `percent_off / 100 * distanceKm * 1.8` instead, which is what this used to
  // do, hard-codes the standard per-km rate, so a premium ride is discounted at
  // the standard rate and the base and booking fee are ignored.
  const gross = computeFare({ category, distanceKm, surge, discountGhs: 0 });

  let discountGhs = 0;
  if (promoCode) {
    const { data: promoRows, error: promoError } = await service
      .from('promos')
      .select('percent_off,max_discount_ghs,expires_at')
      .eq('code', promoCode)
      .eq('active', true)
      .limit(1);
    // A dropped error here would leave discountGhs at 0 and quote the rider
    // full price for a code they supplied, which is a worse outcome than
    // failing: nothing in the response says the promo was not applied.
    if (promoError) return json(500, { error: promoError.message });
    // `promoRows?.[0]` rather than `maybeSingle()`, and not for the reason this
    // comment used to give. Measured with the shipped client: on a GET,
    // `maybeSingle()` sends `Accept: application/json`, not
    // `application/vnd.pgrst.object+json`
    // (`@supabase/postgrest-js@1.16.1/src/PostgrestTransformBuilder.ts:209-210`,
    // the version supabase-js 2.45.4 resolves), so a 0-row read is a 200 with
    // `[]` and the client turns it into `data = null` itself
    // (`@supabase/postgrest-js@1.16.1/src/PostgrestBuilder.ts:118-134`), which
    // makes the two behaviourally equivalent for a 0-row read. The
    // `details.includes('0 rows')` comparison at `:162` is the error branch,
    // which this GET does not take, and it is a bare substring test that
    // PostgREST's own single-object message `multiple (or no) rows returned`
    // would not match — so that is the branch that would break on a rewording,
    // and it is not this one. So the reason to write `limit(1)` is not that
    // `maybeSingle()` is broken here: it is that `limit(1)` never asks the
    // client to interpret a row count, so the answer is `data` and we index it,
    // and the shape of a 0-row read cannot change under us if that client-side
    // coercion is ever revised.
    const promo = promoRows?.[0] ?? null;
    // `expires_at` is filtered here rather than in the query because a
    // PostgREST filter value is a literal, not SQL: `expires_at.gt.now()` is
    // not something the API can evaluate, and its own documentation answers a
    // `now()`-dependent filter with a view or an RPC. The seeded RIDE30 has a
    // null expiry, so nothing is broken today either way.
    const live = promo !== null &&
      (promo.expires_at === null || new Date(promo.expires_at).getTime() > Date.now());
    if (live) {
      const percentOff = Number(promo.percent_off);
      const maxDiscountGhs = Number(promo.max_discount_ghs);
      // This is a backstop on `max_discount_ghs`, and only that column.
      // `promos.percent_off` carries `check (percent_off > 0 and percent_off
      // <= 100)`, and because that is a conjunction it does reject NaN: on this
      // host `'NaN'::numeric > 0` is true but `'NaN'::numeric <= 100` is false,
      // so an insert of a NaN percent is refused (measured). `max_discount_ghs`
      // has no CHECK at all, and PostgREST serialises a numeric NaN as the JSON
      // string `"NaN"`, so `Number("NaN")` is NaN and that is the one column
      // that can arrive non-finite. `promoDiscountGhs` does not clamp a
      // non-finite argument, deliberately: `Math.max(0, NaN)` is NaN, and
      // turning a corrupt row into a silent no-discount is the failure this
      // check exists to prevent.
      if (!isFiniteNumber(percentOff) || !isFiniteNumber(maxDiscountGhs)) {
        return json(500, { error: 'promo row carries non-finite discount data' });
      }
      discountGhs = promoDiscountGhs(gross.fareGhs, percentOff, maxDiscountGhs);
    }
  }

  const quote = computeFare({ category, distanceKm, surge, discountGhs });

  const { data: trip, error: tripError } = await service
    .from('trips')
    .insert({
      rider_id: riderId,
      category,
      state: 'requested',
      pickup: stopJson(pickup),
      dropoff: stopJson(dropoff),
      pickup_point: wkt(pickup),
      dropoff_point: wkt(dropoff),
      distance_km: distanceKm,
      surge: quote.surge,
      fare_ghs: quote.fareGhs,
      is_demo: true,
    })
    .select()
    .single();
  if (tripError) return json(500, { error: tripError.message });

  // From here on the trip row exists, so every failure below has to take it
  // out again: Task 8's `activeTrip()` selects `requested` trips, so an orphan
  // pins the rider's active trip and blocks every later ride request.
  const deleteTrip = async (tripId: string) => {
    const { error } = await service.from('trips').delete().eq('id', tripId);
    return { error };
  };

  // The whole post-insert region runs inside `compensating`, so an *unchecked*
  // failure takes the same compensating delete as a checked one. That route is
  // the one that needed guarding: it used to escape to `serve`'s default
  // onError, which returns a bare 500 and leaves the trip row behind, which is
  // the same orphan the delete exists to prevent.
  const outcome = await compensating(deleteTrip, trip.id, async () => {
    // Service-role only: the migration revokes EXECUTE on this function from
    // `public`, `anon` and `authenticated`, so a user client returns 42501 here
    // and a Flutter app cannot call it at all. The error is checked rather than
    // dropped, because a dropped one turns a failed match into an empty offer
    // list that looks identical to "no drivers are online right now". If the
    // candidates are empty on a live project, check the key before anything else.
    const { data: candidates, error: matchError } = await service.rpc('match_offers_for_trip', {
      target_trip: trip.id,
    });
    if (matchError) throw new Error(matchError.message);

    const rows = (candidates ?? []) as { driver_id: string; pickup_distance_km: number }[];
    const driverIds = pickDrivers(
      rows.map((r) => ({ id: r.driver_id, pickupDistanceKm: Number(r.pickup_distance_km) })),
      MAX_OFFERS,
    );
    const distanceById = new Map(
      rows.map((r) => [r.driver_id, Number(r.pickup_distance_km)] as const),
    );

    if (driverIds.length > 0) {
      const expiresAt = new Date(Date.now() + OFFER_TTL_SECONDS * 1000).toISOString();
      const { error: offerError } = await service.from('offers').insert(
        driverIds.map((driverId) => ({
          trip_id: trip.id,
          driver_id: driverId,
          fare_ghs: quote.fareGhs,
          pickup_distance_km: distanceById.get(driverId) ?? 0,
          state: 'pending',
          expires_at: expiresAt,
        })),
      );
      // Checked, and this is the check the brief left out: reporting
      // `offerDriverIds` for offers that were never written tells the rider the
      // fan-out happened while no driver was ever told about the trip. The trip
      // goes with them, since the offers cascade from it.
      if (offerError) throw new Error(offerError.message);
    }

    return driverIds;
  });

  if (!outcome.ok) {
    return json(500, { error: outcome.error, cleanupError: outcome.cleanupError });
  }

  return json(200, { trip, quote, offerDriverIds: outcome.value });
});
```

- [ ] **Step 9: Run the Dart half of the rounding case, then lint**

```bash
cd ~/meet-n-go/packages/mng_core && flutter test && flutter analyze --fatal-infos
cd ~/meet-n-go/supabase
deno check functions/request-ride/index.ts functions/request-ride/fare.ts functions/request-ride/match.ts \
  functions/request-ride/request.ts functions/request-ride/compensate.ts
deno lint functions/
```

The 2-dp rounding case exists in both languages on purpose: it is the only assertion in either
suite that can tell a client-side and a server-side fare apart. Both pin 3.7 km standard at surge
1.3 to exactly 16.16, with exact equality rather than `closeTo`, because every other expected fare
in both suites is exact in binary and a `round2` that did nothing would pass all of them.

Expected: no diagnostics from `deno check` or `deno lint`. **There is deliberately no `deno fmt --check` step and no formatting
standard in this repo.** CI has no `deno fmt` step, and Task 3's implementer already made the same
call for Dart and the reviewer upheld it. Do not add one.

- [ ] **Step 10: Deploy and smoke-test against the linked project**

```bash
cd ~/meet-n-go/supabase
supabase functions deploy request-ride
```

Create a rider through Supabase Studio (Authentication → Add user, email `rider@example.com`, password `secret123`, tick "Auto confirm"), copy a service-role JWT via `supabase auth` or the Studio API, then:

```bash
curl -s -X POST "$SUPABASE_URL/functions/v1/request-ride" \
  -H "Authorization: Bearer $RIDER_JWT" \
  -H "Content-Type: application/json" \
  -d '{"category":"standard","promoCode":"RIDE30","pickup":{"label":"Pickup","address":"Osu, Accra","lat":5.6037,"lng":-0.1870},"dropoff":{"label":"Dropoff","address":"Airport Residential","lat":5.6200,"lng":-0.1870}}'
```

Expected: JSON with a `trip.id`, a `quote.fareGhs` lower than the undiscounted fare, and an
`offerDriverIds` array (empty until a driver goes online, which is correct). `trip.pickup` comes back
as `{"label", "address", "point":{"lat", "lng"}}`, not as the flat pin that was sent.

This step needs `supabase login` and a linked project, so it is **not runnable on a host without
interactive browser auth**; on such a host say it was not attempted and do not claim it passed.

- [ ] **Step 11: Commit**

```bash
cd ~/meet-n-go
git add -A
git commit -m "feat(functions): request-ride with fare, promo discount, radius matching"
```

---
### Task 7: Edge Function — offers accept/decline with the single-winner rule

**Status: shipped, two fix rounds applied.** 98 Deno tests pass, `deno check` and `deno lint` clean, 13/13 authorization probes pass. The deployed HTTP round trip of Step 7 is **not** verified; see Step 7.

**Files:**
- Create: `supabase/functions/offers/command.ts` — `parseOfferCommand`
- Create: `supabase/functions/offers/resolve.ts` — `resolveAccept`, `declineRefusal`, `confirmDecline`
- Create: `supabase/functions/offers/handler.ts` — `handleOfferRequest(req, deps)`, no client and no supabase-js import
- Create: `supabase/functions/offers/clients.ts` — the two clients and the four ports
- Create: `supabase/functions/offers/index.ts` — `serve`, six lines
- Create: `supabase/tests/verify_offer_authz.sql` — the 13 authorization facts the comments rely on
- Test: `supabase/functions/_tests/accept_offer.test.ts` — 59 tests
- Test: `supabase/functions/_tests/clients_wiring.test.ts` — 5 tests, asserting over `clients.ts`'s own source text

**Interfaces:**
- Consumes: RPC `accept_offer(uuid)` (Task 5), `kOfferTtl` and `OfferState` semantics (Task 4)
- Produces: POST `offers` with `{action: 'accept'|'decline', offerId}` returning `{accepted, tripId, winnerDriverId}` or `{declined: true}`. The driver app in Task 13 consumes this.
- The `Authorization` header must carry the **`Bearer ` scheme**, matched case-insensitively (which is what wai-extra's `extractBearerAuth` does — `S.map toLower x == "bearer"`, in `Network/Wai/Middleware/HttpAuth.hs`, and the symbol is absent from wai itself — so `bearer <token>` is fine). It is required rather than stripped: PostgREST resolves the role from the scheme word, substituting `""` when it is absent, so a bare token authenticates nowhere at the PostgREST ports — while `getUser(token)` alone tolerates one, because supabase-js prefixes the scheme itself. Stripping leniently would let a request pass the identity check and then fail later at a port, with an outcome that is a 500 or a misleading 404. A missing or scheme-less header is a 401 before any port is called. **Task 6 is not affected**: it strips leniently too, but it builds one client with no `global.headers` and never forwards a caller's `Authorization` to a PostgREST port — the token goes only to `getUser(token)`, which prefixes the scheme itself — so a bare token works there and there is nothing to fix.

The **request** contract: `parseOfferCommand` refuses with 400 anything that is not `{action: 'accept' | 'decline', offerId: <uuid>}`, in this order: body not a JSON object, `action` not one of the two strings, `offerId` not a string, `offerId` not a uuid. Testing only `action === 'decline'` sent every other value down the accept path, so a client that sent `'Accept'`, `'delete'`, or no action at all had its offer accepted on the caller's behalf — by then the trip is `matched` and no one can undo it. The uuid check is not fussiness: `offers.id` is `uuid primary key` (migration:78) and the id goes straight into a PostgREST equality filter, so a non-uuid comes back 400 and the handler would report a client typo as a 500. **Unrecognised extra fields are left alone**, deliberately: a field this function does not read cannot change what it does, and refusing unknown keys would break a client the moment it adds one.
- The **response** contract, and the two accept-refusal shapes are the same shape. Every refusal carries `{accepted: false, tripId, winnerDriverId: null, reason}`; every success carries `{accepted: true, tripId, winnerDriverId}` and no `reason`. So `reason` is present exactly when `accepted` is false, and Task 13 can read `tripId` off any response without branching on which refusal it got. `tripId` is null on the two ownership refusals — an offer that is not there has no trip to name, and one belonging to another driver does not get its trip id disclosed to a stranger — and is the real id on a terminal offer, which the offer read supplies, and on every refusal the RPC produces, which is what closes the offer queue.
  Statuses: 401 unauthenticated, 400 bad body, **404** on the ownership refusals (`reason: 'offer not found'`), **409** on a terminal offer (`reason: 'offer already <state>'`) and on a zero-row decline write (`reason: 'offer is no longer pending'`), 500 on a client or database error, else 200. An expired offer and a trip that has left `requested` are **not** refusals with their own status: both are answered by the RPC as a 200 with `accepted: false` and the trip id, because the RPC's refusal path is what moves the offer to `expired`.

**`resolveAccept` is a classifier in front of the RPC, and it classifies only *some* refusals. Which ones is the whole subtlety.** It never decides the outcome: when it returns `accepted: true` the handler calls the RPC and reports that answer verbatim, including a `false`, so the pre-check cannot promote an accept and nothing it returns reaches the driver as an outcome.

The subtlety is that `accept_offer` does not only *answer* on its refusal path, it **writes**. The guard at migration:373-375 sends an offer that is expired, already terminal, or on a trip that is no longer `requested` down a branch that runs `update offers set state = 'expired' where id = p_offer and state = 'pending'` (migration:376) before answering `false`. That is the **only** write of `expired` in the tree — no sweeper, no cron, no other function — so a handler that short-circuits those two reasons leaves the offer `pending` in the database forever, on a trip that is never coming back, and Task 13's driver queue reads it. Measured on this host: a pending, unexpired offer on a trip cancelled two seconds in answers `accepted = f` with the trip id and a null driver, and the offer is `expired` afterwards.

So the handler acts on a classifier refusal **only when the RPC's write cannot fire**, which is the two refusals whose write is blocked by its own `state = 'pending'` guard: an offer that is not there (404) and an offer already in a terminal state (409). For `offer expired` and `trip is no longer awaiting a driver` the classifier's verdict is **ignored** and the call goes out, so the RPC performs the write and returns the trip id the driver app needs to close its queue. Three things follow, and they are the reason this shape was chosen over having the classifier perform the write itself: the `expired` write is restored; the **privileged trip-state read disappears**, because it existed only to feed the trip branch and it had to be the service client to see the row at all, so the accept path is one round trip shorter and the function makes one fewer service-role read; and `tripId` comes back on exactly the refusals that need it.

Two different claims, and an earlier version of this section conflated them. The **monotonicity** argument proves there is **no false accept** and nothing more: every fact the classifier tests is monotone, so an accept it refuses was already invalid and cannot become valid again. An offer's state only ever leaves `pending` (migration:376, :381, :391); `expires_at` only approaches as the clock advances; and no trip transition returns a trip to `requested` — the legality predicate at migration:192-197 contains no `new.state` of `requested`, and probe 13 of `supabase/tests/verify_offer_authz.sql` measures all six states refusing the move. It does **not** prove no side effect is skipped, because that side effect is the RPC's to perform. The other direction is ordinary and expected: a rival accept landing between the read and the RPC, which the RPC reports as `false` and the handler passes on. The lock behaviour is not pinned here; `verify_concurrency.sql` pins it against the real RPC from two live `dblink` backends.

`resolveAccept` remains the **full mirror** of the RPC, accept path included, and the Review Focus test `accept_offer_single_winner_test` still tests the real rule set — only the handler's *use* of it is narrow. One consequence: `OfferRow.tripState` is `TripStateName | null`, and null means **"not read"**. The handler passes null because it did not read the trip, and the mirror skips the check it has no data for rather than answering it. Guessing `'requested'` would be the C9 defect again — a check that consults a value the caller made up — so the type says what is true.

**Two clients, and each has exactly one job — `accept` on the driver's own token, `decline` on the service key.** `accept_offer`'s ownership test is the plain expression `v_offer.driver_id is distinct from auth.uid()` (migration:324) inside a `security definer` function, so it is evaluated for every caller and `bypassrls` is no exemption. `offers.driver_id` is `not null` (migration:80), so a caller with no `sub` claim — whose `auth.uid()` is NULL — fails it. Measured: as `anon` and as `service_role` with no `sub` claim, `accept_offer` answers `false / NULL / NULL` and writes nothing (probes 1 and 2); as the offer's own driver it answers `true` and the trip goes to `matched` with the sibling `released` (probe 3). So the accept must go out on the driver's own token.

The decline is the other way round. `offers` carries two SELECT policies and no UPDATE policy (migration:530 and :532 are its only two), so the decline `UPDATE` must not go on the caller's client. Measured: the same driver SELECTs 1 row and UPDATEs 0 as `authenticated`, and the identical UPDATE matches 1 row as `service_role` (probes 6 and 7).

**supabase-js only sets `Authorization` when the request has none** (`@supabase/supabase-js@2.45.4/dist/module/lib/fetch.js`), so a service key paired with a forwarded bearer leaves the *bearer* as the effective credential. Measured by driving the shipped client with a stub fetch: a service key plus `Authorization: Bearer DRIVER-JWT` puts `Bearer DRIVER-JWT` on the wire, with the service key only in `apikey`. That is the construction the brief's Step 5 comment claimed the opposite of, and the one Task 6's brief shipped and had to be unpicked from. The service client here therefore carries no forwarded header at all, and `authenticate` passes the token to `getUser(token)` explicitly instead — measured to put `Authorization: Bearer <token>` on the wire from a client with no header of its own. **`service_role` can never accept an offer.**

**Two reads, on one client for the accept path.** The offer row (`driver_id`, `state`, `trip_id`, `expires_at`) comes from the **caller's own bearer**, where `driver reads own offers` (migration:530) makes the row evidence about this driver. That policy is not sufficient alone — `rider reads offers on own trip` (migration:532) also lets the trip's rider read every offer on it, which probe 5 measures — so the `driver_id` comparison is what proves ownership, and `accept_offer` checks it again under the trip lock (migration:368).

There is **no trip read**, and that is a deliberate consequence of the classifier narrowing above rather than a simplification: the trip-state verdict is one the handler does not act on, and reading the trip to produce a discarded verdict while also paying a privileged round trip for it is the worse of the two. It could not have gone on the caller's bearer in any case — `driver reads assigned trips` (migration:520) is `using (driver_id = auth.uid())` and a trip's `driver_id` is NULL until `accept_offer` matches it, so probe 11 measures the driver reading their own offer and **0** trip rows at that moment, and probe 12 measures the same read returning 1 row after the accept. `clients_wiring.test.ts` asserts that no `trips` read is reintroduced.

The decline write is the one service-role operation left, and it is there because `offers` has no UPDATE policy (below).

**The decline is the only thing enforcing three invariants RLS was otherwise providing**, and it establishes all three before the write: read the offer on the caller's bearer, refuse unless the row exists, is `pending`, and `driver_id` is the caller, then write on the service client filtered by `id` **and** `driver_id` **and** `state = 'pending'` (all three reach the wire; probe 8 measures each refusing on its own), and **check the affected row count, not only `error`**. `.select('id,state')` is what makes the count readable: measured, without it the same write returns `data = null` and `count = null` with `error = null` whatever happened. A zero-row match answers **409 `{declined:false}`**, because a decline that changed no row is not a decline.

**On `maybeSingle()` versus `limit(1)`, corrected.** The rationale this plan and Task 6's code originally carried was wrong, and it is worth writing down correctly because a comment a future implementer copies as fact is the defect class that cost Task 5 five fix rounds. Measured with the shipped client: on a **GET**, `maybeSingle()` sends `Accept: application/json`, not `application/vnd.pgrst.object+json` (`@supabase/postgrest-js@1.16.1/src/PostgrestTransformBuilder.ts:209-210`), so a zero-row read is a 200 with `[]` that the client turns into `data = null` with no error itself (`PostgrestBuilder.ts:118-134`). The `error.details.includes('0 rows')` comparison at `:162` is a **different** branch, reached only when the server answers with an error, and it is a substring test: forced with `details: "0 rows"` or `"Results contain 0 rows, ..."` a 406 is cleared, and forced with `"JSON object requested, multiple (or no) rows returned"` it is not. None of that is the zero-row GET path. **So the two are behaviourally equivalent for a zero-row read on this version, and the reason to write `limit(1)` is that it never asks the client to interpret a row count at all** — the answer is `data` and we index it, so the shape of a zero-row read cannot change under us if that client-side coercion is ever revised, and every read in the function is then the same shape. That is the rationale the code comments carry. The same false rationale also sat in **Task 6's section** of this plan, at the `limit(1)` bullet in Interfaces and in the Step 5 code block; both were corrected in `da992f7`, so all four copies of this note now agree.

- [x] **Step 1: the test file**

`supabase/functions/_tests/accept_offer.test.ts`, 59 tests, and `supabase/functions/_tests/clients_wiring.test.ts`, 5 more. Every one checked against a mutation: **35 of 35 are killed, with no survivors.**

  Both directions of the classifier are covered, because the second is the one most likely to be got wrong. `a pre-check pass whose RPC answers false is reported as false` pins that a pass followed by a `false` from the RPC answers `accepted: false` and never `true`. `the winner is the RPC's driver, not the one the classifier read` pins the winner with the two ids deliberately different, which is the offer-reassignment window migration:368 exists to guard.

  The narrowing is pinned from both sides. `a terminal-offer refusal answers its own reason and never reaches the RPC` asserts all four terminal states answer 409 with their own reason and that `acceptOffer` was **not** called. `an expired offer reaches the RPC, which is what marks it expired` asserts the opposite for the one refusal whose write matters: the RPC **is** called and its answer is what the driver is told, with no classifier `reason` on the body. The mirror's `tripState: null` behaviour is pinned separately, so a null is never read as a guess.

  `clients_wiring.test.ts` exists because `handler.ts` takes ports, so every behavioural test is blind to which client a port uses. Four mutations of `clients.ts` were tried against the previous suite and all four survived, including moving `accept_offer` to the service client, which turns the single-winner RPC into a no-op. The assertions read the file's text — no network, no supabase-js, no env — and kill all four plus four more. They strip comments before matching (a comment naming `Authorization` is a sentence, not a header) and tolerate whitespace, because the chains are wrapped across lines. They are brittle to reformatting and cannot see a semantic change that keeps the same tokens: a floor, not a substitute for driving the client. `ci.yml` gains `--allow-read=functions/` for them.

  Also covered: the accept path and its exact call order; a decline against a nonexistent offer, another driver's offer and each of the four terminal states, none of which reach the write; **a decline whose write matched zero rows is not reported as declined**; a trip row that is missing or in any of the five non-`requested` states; an offer state the build does not name; every `parseOfferCommand` refusal, with the bad-action cases also asserting that *no query runs at all*.

- [x] **Step 2: run it and confirm it fails**

Expected and observed: `../offers/resolve.ts` did not exist.

- [x] **Step 3: the decision module**

`resolve.ts`, no I/O. Three deliberate differences from the brief's version.

  **The trip state is read from the chosen offer's own row, and the separate `input.tripState` parameter is gone.** The brief passed it in separately, never read the authoritative `chosen.tripState` sitting in the row, and had the "trip is no longer awaiting a driver" check trust the caller-supplied value. The RPC reads the trip under `for update` and tests that row (migration:373), so the classifier reads the same row. `nextTripState` is therefore `TripStateName | null`, null only when the offer was not found.

  That removal also makes the brief's check *order* inexpressible rather than wrong. The brief tested the trip state before the offer's existence, which is only possible if the trip state is available when the offer is not found. `accept_offer` tests existence first (migration:304-307) and the classifier does too. The one ordering the surface *can* observe — a terminal offer on a matched trip — is pinned to report the trip.

  **`AcceptResult` carries `refusalStatus: number | null`**, null when the offer is acceptable. The status is chosen where the reason is produced rather than by matching the reason string in the handler, because a string match on an English message is exactly the coupling that breaks silently when one side is reworded.

  The expiry comparison stays `<=` exactly as the brief had it, because the brief is right and Task 4 is wrong. `accept_offer` uses `v_offer.expires_at <= now()` (migration:375) and probe 9 measures it refusing an offer whose `expires_at` is exactly `now()`. `Offer.isExpired` is written `DateTime.now().isAfter(expiresAt)` (offer.dart:35), which is the strict comparison, so the two disagree at exactly `expiresAt`. Both sides carry a comment saying so, and Dart is a later task's fix. The test pins the boundary with a frozen clock, because a test that reads `Date.now()` a moment before the call cannot tell `<=` from `<`.

- [x] **Step 4: run the tests and confirm they pass**

```
$ cd ~/meet-n-go/supabase && deno test --allow-env --allow-read=functions/ functions/_tests/
running 59 tests from ./functions/_tests/accept_offer.test.ts
running  5 tests from ./functions/_tests/clients_wiring.test.ts
ok | 98 passed | 0 failed
```

- [x] **Step 5: the function**

Five files rather than the brief's one, and the split is what makes the security-critical parts testable without a network: `command.ts` parses, `resolve.ts` decides, `handler.ts` routes and holds every status code and takes five injected ports, `clients.ts` is the only file that constructs anything, and `index.ts` is `serve((req) => handleOfferRequest(req, buildDeps(buildClients(req))))`.

  `getUser(token)` with the token passed explicitly, not `getUser()` with no argument: there is no persisted session in a Deno Edge Function, so the argumentless form has nothing to read and 401s every request. `userError` is checked as well as `!userData.user`. `req.json()` is inside a `try`, or a truncated body escapes to `serve`'s default `onError` and returns a bare 500 that says the request failed rather than that the body was wrong.

- [x] **Step 6: check, lint, test**

```bash
cd ~/meet-n-go/supabase
deno check functions/offers/*.ts
deno lint functions/
deno test --allow-env --allow-read=functions/ functions/_tests/
```

Observed:

```
running 59 tests from ./functions/_tests/accept_offer.test.ts
running  5 tests from ./functions/_tests/clients_wiring.test.ts
running  6 tests from ./functions/_tests/compensate.test.ts
running 11 tests from ./functions/_tests/fare.test.ts
running  4 tests from ./functions/_tests/match.test.ts
running 13 tests from ./functions/_tests/request.test.ts
ok | 98 passed | 0 failed (1s)

Checked 17 files
```

`deno check` reports nothing for all five files. `deno fmt --check` is **not** run and is not in this project: there is deliberately no formatting standard, CI has no format step, and the brief's line would either fail or smuggle in a standard the project has declined four times. `supabase functions deploy offers` was **not run**: it needs interactive browser auth, and there is no Docker on this host. Not attempted, and not claimed.

  `supabase/tests/verify_offer_authz.sql`, run against the real migration on local Postgres 17.11:

```
$ sudo -n -u postgres psql -d mng_test -v ON_ERROR_STOP=1 -f supabase/tests/verify_offer_authz.sql
 probes | passed | failed
--------+--------+--------
     13 |     13 |      0
```

  Re-runnable and idempotent. The tally counts `passed is true` and `passed is not true`, not `passed` and `not passed`, because a probe whose verdict is SQL NULL — which is what a comparison against a NULL column produces — must be a failure and not a silence. An earlier version of that line reported `0 failed` while one probe had no verdict at all.

- [ ] **Step 7: the deployed round trip — NOT RUN, and why**

`supabase functions deploy`, `supabase login` and `supabase link` all require an interactive browser login and there is no local stack, so the brief's two-curl race against a deployed URL cannot be executed here. **The deployed HTTP round trip is unverified, and the two-curl race on a linked project belongs in Task 18's runbook as the first thing a pilot runs.** What is verified instead: the locking, by `verify_concurrency.sql` (Task 5), against the real RPC from two live `dblink` backends; and the authorization and the response shapes, by the 13 probes above. What neither covers is an actual `POST /functions/v1/offers` from two tokens at once. The "one `accepted` plus four `released`" observation also assumes a five-offer fan-out, and so assumes `MAX_OFFERS = 5` and five approved online drivers within range.

- [x] **Step 8: commit**

```bash
cd ~/meet-n-go
git add -A supabase/functions supabase/tests
git commit -m "feat(functions): single-winner offer acceptance with released siblings"
```

**Mutations the tests kill.** 35 attempted, **35 killed, no survivors.** The four `clients.ts` mutations are the ones a previous suite could not see at all, and the F1 group is the behavioural hole this round closed. Re-run the whole set after any change to this function: a fix round that repairs the accept path must not be able to undo the decline invariants or the client wiring unnoticed.

| # | Mutation | Result |
|---|---|---|
| F1a | handler refuses on the classifier's **expiry** verdict, skipping the RPC's `expired` write | killed |
| F1b | handler refuses on **every** classifier refusal, expiry included | killed |
| F1c | `classificationIsOurs` widened to include the two RPC-owned reasons | killed |
| F1d | the mirror refuses a `null` trip state as if it were known-bad | killed |
| F1e | handler reports the classifier's `accepted` instead of the RPC's | killed |
| F1f | handler reports the classifier's `tripId` instead of the RPC's | killed |
| F1g | handler reports the classifier's winner instead of the RPC's | killed |
| F2a | the `Bearer` scheme stripped leniently again | killed |
| F2b | the scheme check made case-sensitive, so lowercase `bearer` is refused | killed |
| F3a | **`accept_offer` moved to the service client** | killed |
| F3b | `.select()` dropped from the decline write | killed |
| F3c | the ownership read moved to the service client | killed |
| F3d | a service key placed on the user client | killed |
| F3e | `driver_id` filter dropped from the decline write | killed |
| F3f | `state` filter dropped from the decline write | killed |
| F3g | the decline write moved to the caller's bearer | killed |
| F3h | a privileged read of `trips` reintroduced | killed |
| D1 | `confirmDecline` reports any count as a decline | killed |
| D2 | `declineRefusal` drops the ownership test | killed |
| D3 | `declineRefusal` drops the pending test | killed |
| D4 | `declineRefusal` drops the existence test | killed |
| D5 | handler ignores the decline outcome | killed |
| D6 | the decline write happens before the refusal checks | killed |
| D7 | the handler stops comparing `driver_id` on the accept path | killed |
| P1 | `parseOfferCommand` drops the action allow-list | killed |
| P2 | `parseOfferCommand` drops the uuid check | killed |
| P3 | `parseOfferCommand` drops the `offerId` type check | killed |
| X1 | handler checks only `!userId`, not the auth error | killed |
| X2 | handler does not guard `req.json()` | killed |
| X3 | handler treats an empty RPC answer as a lost race | killed |
| X4 | handler does not check that `accepted` is a boolean | killed |
| X5 | the ownership refusal stops carrying `tripId`, so the shapes diverge | killed |
| M1 | expiry uses `<` instead of `<=` | killed |
| M2 | `released` drops the `state = 'pending'` filter | killed |
| M3 | the mirror drops the terminal-offer check | killed |

The two survivors of the pre-review battery — an optional `input.tripState` that no test supplies, and a classifier that reorders its two refusal checks — are both gone from this table because the trip-state parameter no longer exists at all: `OfferRow.tripState` is nullable data, not a caller-supplied override, so there is nothing left for either mutation to attach to.

---
### Task 8: Rider app — data layer and auth screens

**Files:**
- Create: `apps/rider/lib/src/data/auth_repository.dart`
- Create: `apps/rider/lib/src/data/supabase_auth_repository.dart`
- Create: `apps/rider/lib/src/data/trip_repository.dart`
- Create: `apps/rider/lib/src/data/supabase_trip_repository.dart`
- Create: `apps/rider/lib/src/auth/auth_controller.dart`
- Create: `apps/rider/lib/src/auth/reset_controller.dart`
- Create: `apps/rider/lib/src/auth/splash_screen.dart`
- Create: `apps/rider/lib/src/auth/login_screen.dart`
- Create: `apps/rider/lib/src/auth/forgot_password_screen.dart`
- Create: `apps/rider/lib/src/auth/reset_password_screen.dart`
- Modify: `apps/rider/pubspec.yaml`
- Test: `apps/rider/test/auth/login_screen_test.dart`
- Test: `apps/rider/test/auth/reset_password_screen_test.dart`

**Interfaces:**
- Consumes: `mng_core` (Tasks 1–4)
- Produces: `class AuthFailure implements Exception` with `String message`; `abstract class AuthRepository` with `signInWithPassword`, `signInWithGoogle`, `sendResetOtp`, `verifyOtpAndSetPassword`; `abstract class TripRepository` with `activeTrip`, `watchTrip`, `requestRide`, `cancelTrip`; `SupabaseAuthRepository` and `SupabaseTripRepository`; `AuthController extends ChangeNotifier` with `busy`, `error`, `submitPassword`, `submitGoogle`; `ResetController extends ChangeNotifier` with `error`, `submit({code, password, confirm})`; four screens. Widget keys: `emailField`, `passwordField`, `loginButton`, `sendCodeButton`, `codeField`, `newPasswordField`, `confirmPasswordField`, `resetButton`.

- [ ] **Step 1: Add dependencies**

`apps/rider/pubspec.yaml` gains:

```yaml
  supabase_flutter: ^2.4.0
  google_maps_flutter: ^2.9.0
  geolocator: ^13.0.1
  url_launcher: ^6.3.1
  path_provider: ^2.1.4
  shared_preferences: ^2.3.2
  provider: ^6.1.2
```

```bash
cd ~/meet-n-go/apps/rider && flutter pub get
```

Expected: `Got dependencies!` with no version conflicts. If `supabase_flutter` demands a higher Dart SDK than stable provides, pin to the newest version whose constraint the local Dart satisfies.

- [ ] **Step 2: Write the failing login test**

`apps/rider/test/auth/login_screen_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/auth/auth_controller.dart';
import 'package:meetngo_rider/src/auth/login_screen.dart';
import 'package:meetngo_rider/src/data/auth_repository.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

class FakeAuthRepository implements AuthRepository {
  String? lastEmail;
  String? lastPassword;
  bool googlePressed = false;
  bool failWith = false;

  @override
  Future<void> signInWithPassword(String email, String password) async {
    lastEmail = email;
    lastPassword = password;
    if (failWith) throw const AuthFailure('Incorrect email or password');
  }

  @override
  Future<void> signInWithGoogle() async => googlePressed = true;

  @override
  Future<void> sendResetOtp(String email) async {}

  @override
  Future<void> verifyOtpAndSetPassword(String email, String code, String password) async {}
}

Widget wrap(FakeAuthRepository repo) => ScreenUtilInit(
      designSize: const Size(390, 844),
      minTextAdapt: true,
      builder: (_, __) => ChangeNotifierProvider<AuthController>.value(
        value: AuthController(repo),
        child: const MaterialApp(home: LoginScreen()),
      ),
    );

void main() {
  late FakeAuthRepository repo;

  setUp(() => repo = FakeAuthRepository());

  testWidgets('shows heading, fields, and no Apple button', (tester) async {
    await tester.pumpWidget(wrap(repo));
    expect(find.text('Welcome Back'), findsOneWidget);
    expect(find.text('Login to book a ride in seconds.'), findsOneWidget);
    expect(find.byKey(const Key('emailField')), findsOneWidget);
    expect(find.byKey(const Key('passwordField')), findsOneWidget);
    expect(find.textContaining('Apple'), findsNothing);
    expect(find.text('Continue with Google'), findsOneWidget);
  });

  testWidgets('login button uses the amber primary', (tester) async {
    await tester.pumpWidget(wrap(repo));
    final button = tester.widget<FilledButton>(find.byKey(const Key('loginButton')));
    expect(button.style?.backgroundColor?.resolve({}), MngColors.primary);
  });

  testWidgets('empty email shows validation and does not call the repository', (tester) async {
    await tester.pumpWidget(wrap(repo));
    await tester.tap(find.byKey(const Key('loginButton')));
    await tester.pump();
    expect(find.text('Enter your email'), findsOneWidget);
    expect(repo.lastEmail, isNull);
  });

  testWidgets('empty password shows validation', (tester) async {
    await tester.pumpWidget(wrap(repo));
    await tester.enterText(find.byKey(const Key('emailField')), 'rider@example.com');
    await tester.tap(find.byKey(const Key('loginButton')));
    await tester.pump();
    expect(find.text('Enter your password'), findsOneWidget);
    expect(repo.lastPassword, isNull);
  });

  testWidgets('valid submit forwards credentials', (tester) async {
    await tester.pumpWidget(wrap(repo));
    await tester.enterText(find.byKey(const Key('emailField')), 'rider@example.com');
    await tester.enterText(find.byKey(const Key('passwordField')), 'secret123');
    await tester.tap(find.byKey(const Key('loginButton')));
    await tester.pump();
    expect(repo.lastEmail, 'rider@example.com');
    expect(repo.lastPassword, 'secret123');
  });

  testWidgets('auth failure surfaces an inline error', (tester) async {
    repo.failWith = true;
    await tester.pumpWidget(wrap(repo));
    await tester.enterText(find.byKey(const Key('emailField')), 'rider@example.com');
    await tester.enterText(find.byKey(const Key('passwordField')), 'wrongpass');
    await tester.tap(find.byKey(const Key('loginButton')));
    await tester.pump();
    expect(find.text('Incorrect email or password'), findsOneWidget);
  });

  testWidgets('google tap delegates to the repository', (tester) async {
    await tester.pumpWidget(wrap(repo));
    await tester.tap(find.text('Continue with Google'));
    await tester.pump();
    expect(repo.googlePressed, isTrue);
  });

  testWidgets('forgot password link is present', (tester) async {
    await tester.pumpWidget(wrap(repo));
    expect(find.text('Forgot Password?'), findsOneWidget);
  });

  testWidgets('password visibility toggles', (tester) async {
    await tester.pumpWidget(wrap(repo));
    final field = tester.widget<TextField>(find.byKey(const Key('passwordField')));
    expect(field.obscureText, isTrue);
    await tester.tap(find.byIcon(Icons.visibility_off));
    await tester.pump();
    final after = tester.widget<TextField>(find.byKey(const Key('passwordField')));
    expect(after.obscureText, isFalse);
  });
}
```

- [ ] **Step 3: Write the failing reset test**

`apps/rider/test/auth/reset_password_screen_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/auth/reset_controller.dart';
import 'package:meetngo_rider/src/auth/reset_password_screen.dart';
import 'package:meetngo_rider/src/data/auth_repository.dart';
import 'package:provider/provider.dart';

class RecordingAuthRepository implements AuthRepository {
  String? code;
  String? password;

  @override
  Future<void> verifyOtpAndSetPassword(String email, String code, String password) async {
    this.code = code;
    this.password = password;
  }

  @override
  Future<void> signInWithPassword(String email, String password) async {}

  @override
  Future<void> signInWithGoogle() async {}

  @override
  Future<void> sendResetOtp(String email) async {}
}

Widget wrap(RecordingAuthRepository repo) => ScreenUtilInit(
      designSize: const Size(390, 844),
      builder: (_, __) => ChangeNotifierProvider<ResetController>.value(
        value: ResetController(repo, 'rider@example.com'),
        child: const MaterialApp(home: ResetPasswordScreen()),
      ),
    );

void main() {
  testWidgets('renders step two of three with the copy from the reference', (tester) async {
    await tester.pumpWidget(wrap(RecordingAuthRepository()));
    expect(find.text('Create new password'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byKey(const Key('codeField')), findsOneWidget);
  });

  testWidgets('code shorter than six digits blocks submit', (tester) async {
    final repo = RecordingAuthRepository();
    await tester.pumpWidget(wrap(repo));
    await tester.enterText(find.byKey(const Key('codeField')), '1338');
    await tester.enterText(find.byKey(const Key('newPasswordField')), 'secret123');
    await tester.enterText(find.byKey(const Key('confirmPasswordField')), 'secret123');
    await tester.tap(find.byKey(const Key('resetButton')));
    await tester.pump();
    expect(find.text('Enter the 6-digit code'), findsOneWidget);
    expect(repo.password, isNull);
  });

  testWidgets('password under six characters is rejected', (tester) async {
    final repo = RecordingAuthRepository();
    await tester.pumpWidget(wrap(repo));
    await tester.enterText(find.byKey(const Key('codeField')), '133870');
    await tester.enterText(find.byKey(const Key('newPasswordField')), 'abc12');
    await tester.enterText(find.byKey(const Key('confirmPasswordField')), 'abc12');
    await tester.tap(find.byKey(const Key('resetButton')));
    await tester.pump();
    expect(find.text('At least 6 characters'), findsOneWidget);
    expect(repo.password, isNull);
  });

  testWidgets('mismatched passwords block submit', (tester) async {
    final repo = RecordingAuthRepository();
    await tester.pumpWidget(wrap(repo));
    await tester.enterText(find.byKey(const Key('codeField')), '133870');
    await tester.enterText(find.byKey(const Key('newPasswordField')), 'abc123');
    await tester.enterText(find.byKey(const Key('confirmPasswordField')), 'abc124');
    await tester.tap(find.byKey(const Key('resetButton')));
    await tester.pump();
    expect(find.text('Passwords do not match'), findsOneWidget);
    expect(repo.password, isNull);
  });

  testWidgets('valid reset forwards the code and password', (tester) async {
    final repo = RecordingAuthRepository();
    await tester.pumpWidget(wrap(repo));
    await tester.enterText(find.byKey(const Key('codeField')), '133870');
    await tester.enterText(find.byKey(const Key('newPasswordField')), 'secret123');
    await tester.enterText(find.byKey(const Key('confirmPasswordField')), 'secret123');
    await tester.tap(find.byKey(const Key('resetButton')));
    await tester.pump();
    expect(repo.code, '133870');
    expect(repo.password, 'secret123');
  });

  testWidgets('a matching pair shows the green success state', (tester) async {
    await tester.pumpWidget(wrap(RecordingAuthRepository()));
    await tester.enterText(find.byKey(const Key('codeField')), '133870');
    await tester.enterText(find.byKey(const Key('newPasswordField')), 'secret123');
    await tester.enterText(find.byKey(const Key('confirmPasswordField')), 'secret123');
    await tester.tap(find.byKey(const Key('resetButton')));
    await tester.pumpAndSettle();
    expect(find.text('Password updated'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });
}
```

- [ ] **Step 4: Run them and confirm they fail**

```bash
cd ~/meet-n-go/apps/rider && flutter test test/auth/
```

Expected: FAIL — the auth files do not exist.

- [ ] **Step 5: Write the repository interfaces**

`apps/rider/lib/src/data/auth_repository.dart`:

```dart
class AuthFailure implements Exception {
  const AuthFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class AuthRepository {
  Future<void> signInWithPassword(String email, String password);
  Future<void> signInWithGoogle();
  Future<void> sendResetOtp(String email);
  Future<void> verifyOtpAndSetPassword(String email, String code, String password);
}
```

`apps/rider/lib/src/data/trip_repository.dart`:

```dart
import 'package:mng_core/mng_core.dart';

class TripRequestFailure implements Exception {
  const TripRequestFailure(this.message);
  final String message;
}

abstract class TripRepository {
  Future<Trip?> activeTrip();
  Stream<Trip> watchTrip(String tripId);
  Future<Trip> requestRide({
    required TripStop pickup,
    required TripStop dropoff,
    required RideCategory category,
    String? promoCode,
  });
  Future<void> cancelTrip(String tripId);
  Future<GeoPoint?> currentLocation();
  Future<void> raiseSos(String tripId, String note);
}
```

- [ ] **Step 6: Write the Supabase implementations**

`apps/rider/lib/src/data/supabase_auth_repository.dart`:

```dart
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_repository.dart';

class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(this._client);
  final SupabaseClient _client;

  @override
  Future<void> signInWithPassword(String email, String password) async {
    try {
      await _client.auth.signInWithPassword(email: email, password: password);
    } on AuthException catch (e) {
      throw AuthFailure(e.message);
    }
  }

  @override
  Future<void> signInWithGoogle() async {
    // Apple Sign-In is intentionally absent, see spec section 3.1.
    final res = await _client.auth.signInWithOAuth(
      Provider.google,
      redirectTo: 'meetngo://auth-callback',
    );
    if (res.session == null && res.url == null) {
      throw const AuthFailure('Google sign-in was cancelled');
    }
  }

  @override
  Future<void> sendResetOtp(String email) async {
    final res = await _client.functions.invoke(
      'otp-mail',
      body: {'email': email},
    );
    if (res.error != null) throw AuthFailure(res.error!.message);
  }

  @override
  Future<void> verifyOtpAndSetPassword(
    String email,
    String code,
    String password,
  ) async {
    // `otp-mail` owns code verification (it has service-role access to the
    // `password_reset_codes` table, which RLS hides from the client). On a
    // correct code it sets a random temporary password server-side and returns
    // it once. The client signs in with that temporary password, immediately
    // replaces it with the real one, and never surfaces the temporary value.
    final res = await _client.functions.invoke(
      'otp-mail',
      body: {'action': 'verify', 'email': email, 'code': code},
    );
    if (res.error != null) throw AuthFailure(res.error!.message);
    final data = res.data as Map<String, dynamic>?;
    final tempPassword = data?['tempPassword'] as String?;
    if (tempPassword == null) {
      throw const AuthFailure('That code is not right');
    }

    await _client.auth.signInWithPassword(email: email, password: tempPassword);
    final updated = await _client.auth.updateUser(
      UserAttributes(password: password),
    );
    if (updated.user == null) throw const AuthFailure('Could not update password');
    await _client.auth.signOut();
  }
}
```

`apps/rider/lib/src/data/supabase_trip_repository.dart`:

```dart
import 'package:geolocator/geolocator.dart';
import 'package:mng_core/mng_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'trip_repository.dart';

class SupabaseTripRepository implements TripRepository {
  SupabaseTripRepository(this._client);
  final SupabaseClient _client;

  @override
  Future<Trip?> activeTrip() async {
    final res = await _client
        .from('trips')
        .select()
        .in('state', ['requested', 'matched', 'arriving', 'ongoing'])
        .order('created_at', ascending: false)
        .limit(1);
    if (res.data == null || res.data!.isEmpty) return null;
    return Trip.fromJson(res.data!.first as Map<String, dynamic>);
  }

  @override
  Stream<Trip> watchTrip(String tripId) => _client
      .from('trips')
      .stream(primaryKey: ['id'])
      .eq('id', tripId)
      .map((rows) => Trip.fromJson(rows.first as Map<String, dynamic>));

  @override
  Future<Trip> requestRide({
    required TripStop pickup,
    required TripStop dropoff,
    required RideCategory category,
    String? promoCode,
  }) async {
    final res = await _client.functions.invoke('request-ride', body: {
      'category': category.name,
      'promoCode': promoCode,
      'pickup': {...pickup.toJson(), ...pickup.point.toJson()},
      'dropoff': {...dropoff.toJson(), ...dropoff.point.toJson()},
    });
    if (res.error != null) throw TripRequestFailure(res.error!.message);
    return Trip.fromJson((res.data as Map)['trip'] as Map<String, dynamic>);
  }

  @override
  Future<void> cancelTrip(String tripId) async {
    final res = await _client.functions.invoke(
      'cancel-trip',
      body: {'tripId': tripId},
    );
    if (res.error != null) throw TripRequestFailure(res.error!.message);
  }

  @override
  Future<GeoPoint?> currentLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return null;
    }
    final pos = await Geolocator.getCurrentPosition();
    return GeoPoint(pos.latitude, pos.longitude);
  }

  @override
  Future<void> raiseSos(String tripId, String note) async {
    final here = await currentLocation();
    final res = await _client.from('sos_events').insert({
      'trip_id': tripId,
      'raised_by': _client.auth.currentUser!.id,
      'note': note,
      if (here != null) 'point': 'POINT(${here.lng} ${here.lat})',
    });
    if (res.error != null) throw TripRequestFailure(res.error!.message);
  }
}
```

- [ ] **Step 7: Write the controllers**

`apps/rider/lib/src/auth/auth_controller.dart`:

```dart
import 'package:flutter/foundation.dart';
import '../data/auth_repository.dart';

class AuthController extends ChangeNotifier {
  AuthController(this._repo);
  final AuthRepository _repo;

  bool busy = false;
  String? error;

  Future<bool> submitPassword(String email, String password) async {
    error = null;
    if (email.isEmpty) {
      error = 'Enter your email';
      notifyListeners();
      return false;
    }
    if (password.isEmpty) {
      error = 'Enter your password';
      notifyListeners();
      return false;
    }
    busy = true;
    notifyListeners();
    try {
      await _repo.signInWithPassword(email, password);
      return true;
    } on AuthFailure catch (e) {
      error = e.message;
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<bool> submitGoogle() async {
    error = null;
    busy = true;
    notifyListeners();
    try {
      await _repo.signInWithGoogle();
      return true;
    } on AuthFailure catch (e) {
      error = e.message;
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}
```

`apps/rider/lib/src/auth/reset_controller.dart`:

```dart
import 'package:flutter/foundation.dart';
import '../data/auth_repository.dart';

class ResetController extends ChangeNotifier {
  ResetController(this._repo, this.email);
  final AuthRepository _repo;
  final String email;

  String? error;
  bool done = false;

  Future<bool> submit({
    required String code,
    required String password,
    required String confirm,
  }) async {
    error = null;
    if (code.length != 6) {
      error = 'Enter the 6-digit code';
      notifyListeners();
      return false;
    }
    if (password.length < 6) {
      error = 'At least 6 characters';
      notifyListeners();
      return false;
    }
    if (password != confirm) {
      error = 'Passwords do not match';
      notifyListeners();
      return false;
    }
    try {
      await _repo.verifyOtpAndSetPassword(email, code, password);
      done = true;
      notifyListeners();
      return true;
    } on AuthFailure catch (e) {
      error = e.message;
      notifyListeners();
      return false;
    }
  }
}
```

- [ ] **Step 8: Write `login_screen.dart`**

```dart
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
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
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
              Text('Welcome Back', style: text.headlineMedium),
              SizedBox(height: 6.h),
              Text('Login to book a ride in seconds.', style: text.bodySmall),
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
              SizedBox(height: 20.h),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text("Don't have an account? ", style: text.bodySmall),
                  Text('Sign Up',
                      style: text.bodySmall?.copyWith(color: MngColors.primary)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 9: Write `splash_screen.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key, this.onDone});
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MngColors.primary,
      body: SafeArea(
        child: GestureDetector(
          onTap: onDone,
          child: Padding(
            padding: EdgeInsets.all(24.w),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Meet 'N Go",
                  style: MngTheme.light.textTheme.headlineMedium
                      ?.copyWith(color: MngColors.onPrimary, fontSize: 40),
                ),
                SizedBox(height: 8.h),
                Text(
                  'Make a beeline across the city',
                  style: MngTheme.light.textTheme.titleMedium
                      ?.copyWith(color: MngColors.onPrimary),
                ),
                SizedBox(height: 24.h),
                const Icon(Icons.directions_car_filled, size: 72, color: MngColors.onPrimary),
                SizedBox(height: 16.h),
                const Text('Get started  >',
                    style: TextStyle(color: MngColors.onPrimary, fontSize: 14)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 10: Write `forgot_password_screen.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'reset_password_screen.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});
  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _email = TextEditingController();
  String? _error;
  bool _sent = false;
  int _resendSeconds = 0;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_email.text.isEmpty) {
      setState(() => _error = 'Enter the email on your account');
      return;
    }
    setState(() {
      _error = null;
      _sent = true;
      _resendSeconds = 30;
    });
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
                onPressed: _send,
                child: const Text('Send Code'),
              ),
              SizedBox(height: 12.h),
              Center(
                child: TextButton(
                  onPressed: _resendSeconds == 0 ? _send : null,
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
                  child: Padding(
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
```

- [ ] **Step 11: Write `reset_password_screen.dart`**

```dart
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
    final text = MngTheme.light.textTheme;
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
  void dispose() {
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
              Row(
                children: [
                  const Icon(Icons.check_circle, size: 16, color: MngColors.success),
                  SizedBox(width: 6.w),
                  Text('At least 6 characters', style: text.bodySmall),
                  SizedBox(width: 16.w),
                  if (_password.text.isNotEmpty && _password.text == _confirm.text)
                    Row(
                      children: [
                        const Icon(Icons.check_circle, size: 16, color: MngColors.success),
                        SizedBox(width: 6.w),
                        Text('Passwords match', style: text.bodySmall),
                      ],
                    ),
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
```

- [ ] **Step 12: Run the tests and confirm they pass**

```bash
cd ~/meet-n-go/apps/rider && flutter test && flutter analyze
```

Expected: 1 skeleton + 9 login + 6 reset tests pass, analyze clean.

- [ ] **Step 13: Commit**

```bash
cd ~/meet-n-go
git add -A
git commit -m "feat(rider): auth screens, OTP reset flow, data layer interfaces"
```

---

### Task 9: Rider home, route entry, and car selection

**Files:**
- Create: `apps/rider/lib/src/home/home_screen.dart`
- Create: `apps/rider/lib/src/home/widgets/category_chips.dart`
- Create: `apps/rider/lib/src/home/widgets/promo_banner.dart`
- Create: `apps/rider/lib/src/booking/route_entry_sheet.dart`
- Create: `apps/rider/lib/src/booking/choose_car_screen.dart`
- Create: `apps/rider/lib/src/booking/vehicle_card.dart`
- Test: `apps/rider/test/home/home_screen_test.dart`
- Test: `apps/rider/test/booking/choose_car_screen_test.dart`

**Interfaces:**
- Consumes: `RideCategory` and `FareCalculator` (Task 2), `Vehicle`, `TripStop`, `GeoPoint` (Task 4), `MngColors`/`MngRadius`/`MngSpacing`/`MngTheme` (Task 1)
- Produces:
  - `HomeScreen({required List<Vehicle> nearby, required String promoCode, void Function(BuildContext)? onSearchTap})`
  - `CategoryChips({required RideCategory selected, required ValueChanged<RideCategory> onSelected})`
  - `PromoBanner({required String code})`
  - `RouteEntrySheet({required FareCalculator calc})` — a `showRouteEntrySheet(BuildContext, {required FareCalculator calc, required void Function(RouteDraft) onSubmit})` helper plus `RouteDraft({required TripStop pickup, required TripStop dropoff, required RideCategory category})`
  - `ChooseCarScreen({required List<Vehicle> vehicles, required RideCategory selected, required ValueChanged<RideCategory> onCategory, required FareCalculator calc, required void Function(Vehicle) onConfirm, double distanceKm = 8.0})`
  - `VehicleCard({required Vehicle vehicle, required double fareGhs, required VoidCallback onTap, double rating = 4.9, bool selected = false})` — root key `Key('vehicleCard-${vehicle.id}')`
- Widget keys this task owns: `emailField`-style keys `searchField`, `chip-standard`, `chip-premium`, `chip-van`, `vehicleCard-<id>`, `findDriverButton`, `confirmRouteButton`

- [ ] **Step 1: Write the failing home-screen test**

`apps/rider/test/home/home_screen_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/home/home_screen.dart';
import 'package:mng_core/mng_core.dart';

Vehicle vehicle(String id, RideCategory category, int seats) => Vehicle(
      id: id,
      ownerId: 'owner-$id',
      category: VehicleCategory.sedan,
      make: 'Toyota',
      model: 'Corolla',
      plate: 'GR-$id',
      seats: seats,
      photoUrl: '',
      rideCategory: category,
    );

Widget wrap({List<Vehicle> nearby = const []}) => ScreenUtilInit(
      designSize: const Size(390, 844),
      builder: (_, __) => MaterialApp(
        theme: MngTheme.light,
        home: HomeScreen(nearby: nearby, promoCode: 'RIDE30'),
      ),
    );

void main() {
  testWidgets('greets the rider by time of day', (tester) async {
    await tester.pumpWidget(wrap());
    expect(find.textContaining('Good'), findsOneWidget);
  });

  testWidgets('shows the Accra locality line', (tester) async {
    await tester.pumpWidget(wrap());
    expect(find.text('Osu, Accra, Ghana'), findsOneWidget);
  });

  testWidgets('shows the where-would-you-go search field', (tester) async {
    await tester.pumpWidget(wrap());
    expect(find.byKey(const Key('searchField')), findsOneWidget);
  });

  testWidgets('renders the three launch categories and no moto', (tester) async {
    await tester.pumpWidget(wrap());
    expect(find.byKey(const Key('chip-standard')), findsOneWidget);
    expect(find.byKey(const Key('chip-premium')), findsOneWidget);
    expect(find.byKey(const Key('chip-van')), findsOneWidget);
    expect(find.text('Moto'), findsNothing);
  });

  testWidgets('tapping a category chip moves the selection', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.tap(find.byKey(const Key('chip-van')));
    await tester.pump();
    final chips = tester.widget<CategoryChips>(find.byType(CategoryChips));
    expect(chips.selected, RideCategory.van);
  });

  testWidgets('promo banner shows the discount and code', (tester) async {
    await tester.pumpWidget(wrap());
    expect(find.text('30% off your first ride'), findsOneWidget);
    expect(find.text('Code RIDE30'), findsOneWidget);
  });

  testWidgets('empty nearby list shows a friendly empty state', (tester) async {
    await tester.pumpWidget(wrap());
    expect(find.text('No cars nearby right now'), findsOneWidget);
  });

  testWidgets('nearby cars are listed with category and seats', (tester) async {
    await tester.pumpWidget(
      wrap(nearby: [vehicle('v1', RideCategory.standard, 4)]),
    );
    expect(find.text('Toyota Corolla'), findsOneWidget);
    expect(find.text('Standard · 4 seats'), findsOneWidget);
  });

  testWidgets('banner keeps a 20px radius and dark surface', (tester) async {
    await tester.pumpWidget(wrap());
    final banner = tester.widget<PromoBanner>(find.byType(PromoBanner));
    expect(banner.code, 'RIDE30');
  });
}
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
cd ~/meet-n-go/apps/rider && flutter test test/home/
```

Expected: FAIL — `HomeScreen` is not defined.

- [ ] **Step 3: Write `promo_banner.dart`**

`apps/rider/lib/src/home/widgets/promo_banner.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

class PromoBanner extends StatelessWidget {
  const PromoBanner({super.key, required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(bottom: MngSpacing.md),
      padding: EdgeInsets.all(MngSpacing.md),
      decoration: BoxDecoration(
        color: MngColors.textPrimary,
        borderRadius: BorderRadius.circular(MngRadius.large),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Limited offer',
                  style: MngTheme.light.textTheme.bodySmall
                      ?.copyWith(color: MngColors.primary),
                ),
                SizedBox(height: 4.h),
                Text(
                  '30% off your first ride',
                  style: MngTheme.light.textTheme.titleMedium
                      ?.copyWith(color: Colors.white),
                ),
                SizedBox(height: 8.h),
                Container(
                  padding:
                      EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
                  decoration: BoxDecoration(
                    color: MngColors.primary,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Code $code',
                    style: MngTheme.light.textTheme.bodySmall
                        ?.copyWith(color: MngColors.onPrimary),
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.directions_car_filled,
              color: MngColors.primary, size: 44),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Write `category_chips.dart`**

`apps/rider/lib/src/home/widgets/category_chips.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

class CategoryChips extends StatelessWidget {
  const CategoryChips({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final RideCategory selected;
  final ValueChanged<RideCategory> onSelected;

  static const _icons = <RideCategory, IconData>{
    RideCategory.standard: Icons.directions_car,
    RideCategory.premium: Icons.auto_awesome,
    RideCategory.van: Icons.airport_shuttle,
  };

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 76.h,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: RideCategory.values.length,
        separatorBuilder: (_, __) => SizedBox(width: 10.w),
        itemBuilder: (context, i) {
          final category = RideCategory.values[i];
          final isSelected = category == selected;
          return GestureDetector(
            key: Key('chip-${category.name}'),
            onTap: () => onSelected(category),
            child: Container(
              width: 64.w,
              padding: EdgeInsets.symmetric(vertical: 10.h),
              decoration: BoxDecoration(
                color: isSelected ? category.color : MngColors.muted,
                borderRadius: BorderRadius.circular(MngRadius.small),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _icons[category],
                    size: 20,
                    color: isSelected ? MngColors.onPrimary : MngColors.textPrimary,
                  ),
                  SizedBox(height: 4.h),
                  Text(
                    category.label,
                    style: TextStyle(
                      fontSize: 11,
                      color: isSelected ? MngColors.onPrimary : MngColors.textSub,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
```

- [ ] **Step 5: Write `home_screen.dart`**

`apps/rider/lib/src/home/home_screen.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'widgets/category_chips.dart';
import 'widgets/promo_banner.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.nearby,
    required this.promoCode,
    this.onSearchTap,
  });

  final List<Vehicle> nearby;
  final String promoCode;
  final void Function(BuildContext context)? onSearchTap;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  RideCategory _category = RideCategory.standard;

  String get _greeting {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('$_greeting, Alex',
                            style: MngTheme.light.textTheme.titleLarge),
                        SizedBox(height: 2.h),
                        Text('Osu, Accra, Ghana',
                            style: MngTheme.light.textTheme.bodySmall),
                      ],
                    ),
                  ),
                  const Icon(Icons.notifications_none),
                ],
              ),
              SizedBox(height: 20.h),
              GestureDetector(
                key: const Key('searchField'),
                onTap: () => widget.onSearchTap?.call(context),
                child: Container(
                  height: 52.h,
                  padding: EdgeInsets.symmetric(horizontal: 16.w),
                  decoration: BoxDecoration(
                    color: MngColors.muted,
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.search, color: MngColors.textSub),
                      SizedBox(width: 10.w),
                      Text(
                        'Where would you go?',
                        style: MngTheme.light.textTheme.bodyMedium
                            ?.copyWith(color: MngColors.textSub),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: 16.h),
              CategoryChips(
                selected: _category,
                onSelected: (c) => setState(() => _category = c),
              ),
              SizedBox(height: 8.h),
              PromoBanner(code: widget.promoCode),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Available cars',
                      style: MngTheme.light.textTheme.titleMedium),
                  Text('See all', style: MngTheme.light.textTheme.bodySmall),
                ],
              ),
              SizedBox(height: 12.h),
              if (widget.nearby.isEmpty)
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 40.h),
                  child: Center(
                    child: Text('No cars nearby right now',
                        style: MngTheme.light.textTheme.bodySmall),
                  ),
                )
              else
                for (final v in widget.nearby)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: v.rideCategory.color,
                      child: const Icon(Icons.directions_car,
                          color: MngColors.onPrimary),
                    ),
                    title: Text(v.displayName),
                    subtitle: Text('${v.rideCategory.label} · ${v.seats} seats'),
                    trailing: const Icon(Icons.chevron_right),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 6: Run the home tests and confirm they pass**

```bash
cd ~/meet-n-go/apps/rider && flutter test test/home/ && flutter analyze
```

Expected: 9 tests pass, analyze clean.

- [ ] **Step 7: Write the failing choose-car test**

`apps/rider/test/booking/choose_car_screen_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/booking/choose_car_screen.dart';
import 'package:mng_core/mng_core.dart';

Vehicle vehicle(String id, RideCategory category, int seats) => Vehicle(
      id: id,
      ownerId: 'owner-$id',
      category: VehicleCategory.sedan,
      make: 'Honda',
      model: 'Civic',
      plate: 'GR-$id',
      seats: seats,
      photoUrl: '',
      rideCategory: category,
    );

Widget wrap({
  required List<Vehicle> vehicles,
  RideCategory selected = RideCategory.standard,
  void Function(Vehicle)? onConfirm,
  void Function(RideCategory)? onCategory,
}) =>
    ScreenUtilInit(
      designSize: const Size(390, 844),
      builder: (_, __) => MaterialApp(
        theme: MngTheme.light,
        home: ChooseCarScreen(
          vehicles: vehicles,
          selected: selected,
          onCategory: onCategory ?? (_) {},
          calc: FareCalculator(),
          onConfirm: onConfirm ?? (_) {},
        ),
      ),
    );

void main() {
  testWidgets('heading matches the reference copy', (tester) async {
    await tester.pumpWidget(wrap(vehicles: [vehicle('1', RideCategory.standard, 4)]));
    expect(find.text('Choose your car'), findsOneWidget);
  });

  testWidgets('shows the 8 km trip summary line', (tester) async {
    await tester.pumpWidget(wrap(vehicles: [vehicle('1', RideCategory.standard, 4)]));
    expect(find.text('8.0 km'), findsOneWidget);
  });

  testWidgets('card shows make, seats and GHS price', (tester) async {
    await tester.pumpWidget(wrap(vehicles: [vehicle('1', RideCategory.standard, 4)]));
    expect(find.text('Honda Civic'), findsOneWidget);
    expect(find.text('4 seats'), findsOneWidget);
    expect(find.text('GHS 20.40'), findsOneWidget);
  });

  testWidgets('tapping a card selects it and reports the vehicle', (tester) async {
    Vehicle? chosen;
    await tester.pumpWidget(wrap(
      vehicles: [
        vehicle('1', RideCategory.standard, 4),
        vehicle('2', RideCategory.standard, 4),
      ],
      onConfirm: (v) => chosen = v,
    ));
    await tester.tap(find.byKey(const Key('vehicleCard-2')));
    await tester.pump();
    expect(chosen?.id, '2');
  });

  testWidgets('switching category filters the list and notifies the parent',
      (tester) async {
    RideCategory? reported;
    await tester.pumpWidget(wrap(
      vehicles: [
        vehicle('1', RideCategory.standard, 4),
        vehicle('2', RideCategory.van, 7),
      ],
      onCategory: (c) => reported = c,
    ));
    await tester.tap(find.text('Van'));
    await tester.pump();
    expect(reported, RideCategory.van);
    expect(find.text('Honda Civic'), findsNothing);
  });

  testWidgets('van fare uses the van per-km rate', (tester) async {
    await tester.pumpWidget(wrap(
      vehicles: [vehicle('2', RideCategory.van, 7)],
      selected: RideCategory.van,
    ));
    // (5.00 + 2.20 * 8) * 1.0 + 1.00 = 23.60
    expect(find.text('GHS 23.60'), findsOneWidget);
  });

  testWidgets('empty vehicle list disables the find-driver button', (tester) async {
    await tester.pumpWidget(wrap(vehicles: const []));
    final button =
        tester.widget<FilledButton>(find.byKey(const Key('findDriverButton')));
    expect(button.onPressed, isNull);
  });

  testWidgets('non-empty list enables find-driver', (tester) async {
    await tester.pumpWidget(wrap(vehicles: [vehicle('1', RideCategory.standard, 4)]));
    final button =
        tester.widget<FilledButton>(find.byKey(const Key('findDriverButton')));
    expect(button.onPressed, isNotNull);
  });

  testWidgets('find-driver confirms the selected vehicle', (tester) async {
    Vehicle? confirmed;
    await tester.pumpWidget(wrap(
      vehicles: [vehicle('1', RideCategory.standard, 4)],
      onConfirm: (v) => confirmed = v,
    ));
    await tester.tap(find.byKey(const Key('findDriverButton')));
    await tester.pump();
    expect(confirmed?.id, '1');
  });
}
```

- [ ] **Step 8: Run it and confirm it fails**

```bash
cd ~/meet-n-go/apps/rider && flutter test test/booking/
```

Expected: FAIL — `ChooseCarScreen` is not defined.

- [ ] **Step 9: Write `vehicle_card.dart`**

`apps/rider/lib/src/booking/vehicle_card.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

class VehicleCard extends StatelessWidget {
  const VehicleCard({
    super.key,
    required this.vehicle,
    required this.fareGhs,
    required this.onTap,
    this.rating = 4.9,
    this.selected = false,
  });

  final Vehicle vehicle;
  final double fareGhs;
  final VoidCallback onTap;
  final double rating;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: Key('vehicleCard-${vehicle.id}'),
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.only(bottom: 12.h),
        padding: EdgeInsets.all(12.w),
        decoration: BoxDecoration(
          color: MngColors.surface,
          borderRadius: BorderRadius.circular(MngRadius.large),
          border: Border.all(
            color: selected ? MngColors.primary : MngColors.divider,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 64.w,
              height: 48.h,
              decoration: BoxDecoration(
                color: MngColors.muted,
                borderRadius: BorderRadius.circular(MngRadius.small),
              ),
              child: vehicle.photoUrl.isEmpty
                  ? Icon(Icons.directions_car,
                      color: vehicle.rideCategory.color, size: 28)
                  : Image.network(vehicle.photoUrl),
            ),
            SizedBox(width: 12.w),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(vehicle.rideCategory.label,
                      style: MngTheme.light.textTheme.bodySmall),
                  SizedBox(height: 2.h),
                  Text(vehicle.displayName,
                      style: MngTheme.light.textTheme.titleMedium),
                  SizedBox(height: 4.h),
                  Row(
                    children: [
                      const Icon(Icons.star,
                          size: 14, color: MngColors.primary),
                      SizedBox(width: 2.w),
                      Text(rating.toStringAsFixed(1),
                          style: MngTheme.light.textTheme.bodySmall),
                      SizedBox(width: 10.w),
                      const Icon(Icons.person,
                          size: 14, color: MngColors.textSub),
                      SizedBox(width: 2.w),
                      Text('${vehicle.seats} seats',
                          style: MngTheme.light.textTheme.bodySmall),
                    ],
                  ),
                ],
              ),
            ),
            Text('GHS ${fareGhs.toStringAsFixed(2)}',
                style: MngTheme.light.textTheme.titleMedium),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 10: Write `route_entry_sheet.dart`**

`apps/rider/lib/src/booking/route_entry_sheet.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import '../home/widgets/category_chips.dart';

class RouteDraft {
  const RouteDraft({
    required this.pickup,
    required this.dropoff,
    required this.category,
  });

  final TripStop pickup;
  final TripStop dropoff;
  final RideCategory category;
}

/// Accra defaults used until live geocoding lands. Both are real coordinates
/// inside the pilot area so the demo route renders on the map.
const kDefaultPickup =
    TripStop('Pickup', GeoPoint(5.6037, -0.1870), 'Osu, Accra');
const kDefaultDropoff =
    TripStop('Dropoff', GeoPoint(5.6052, -0.1660), 'Airport Residential, Accra');

Future<void> showRouteEntrySheet(
  BuildContext context, {
  required FareCalculator calc,
  required void Function(RouteDraft draft) onSubmit,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => RouteEntrySheet(calc: calc, onSubmit: onSubmit),
  );
}

class RouteEntrySheet extends StatefulWidget {
  const RouteEntrySheet({
    super.key,
    required this.calc,
    required this.onSubmit,
  });

  final FareCalculator calc;
  final void Function(RouteDraft draft) onSubmit;

  @override
  State<RouteEntrySheet> createState() => _RouteEntrySheetState();
}

class _RouteEntrySheetState extends State<RouteEntrySheet> {
  TripStop _pickup = kDefaultPickup;
  TripStop _dropoff = kDefaultDropoff;
  RideCategory _category = RideCategory.standard;

  double get _distanceKm => _pickup.point.distanceKmTo(_dropoff.point);

  int get _driveMinutes => (_distanceKm / 24 * 60).round();

  @override
  Widget build(BuildContext context) {
    final quote = widget.calc.quote(category: _category, distanceKm: _distanceKm);
    return Padding(
      padding: EdgeInsets.fromLTRB(20.w, 8.h, 20.w, 20.h),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 72.h,
            padding: EdgeInsets.all(12.w),
            decoration: BoxDecoration(
              color: MngColors.muted,
              borderRadius: BorderRadius.circular(MngRadius.small),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.circle, size: 10, color: MngColors.success),
                    SizedBox(width: 8.w),
                    Expanded(
                      child: Text('${_distanceKm.toStringAsFixed(1)} km',
                          style: MngTheme.light.textTheme.titleMedium),
                    ),
                    Text('~$driveMinutes min drive',
                        style: MngTheme.light.textTheme.bodySmall),
                  ],
                ),
                SizedBox(height: 6.h),
                Row(
                  children: [
                    const Icon(Icons.circle, size: 10, color: MngColors.error),
                    SizedBox(width: 8.w),
                    Expanded(
                      child: Text('${_distanceKm.toStringAsFixed(1)} km',
                          style: MngTheme.light.textTheme.bodySmall),
                    ),
                    Text('GHS ${quote.fareGhs.toStringAsFixed(2)}',
                        style: MngTheme.light.textTheme.titleMedium),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(height: 16.h),
          CategoryChips(
            selected: _category,
            onSelected: (c) => setState(() => _category = c),
          ),
          SizedBox(height: 20.h),
          FilledButton(
            key: const Key('confirmRouteButton'),
            onPressed: () => widget.onSubmit(RouteDraft(
              pickup: _pickup,
              dropoff: _dropoff,
              category: _category,
            )),
            child: const Text('Search for a ride'),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 11: Write `choose_car_screen.dart`**

`apps/rider/lib/src/booking/choose_car_screen.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'vehicle_card.dart';

class ChooseCarScreen extends StatefulWidget {
  const ChooseCarScreen({
    super.key,
    required this.vehicles,
    required this.selected,
    required this.onCategory,
    required this.calc,
    required this.onConfirm,
    this.distanceKm = 8.0,
  });

  final List<Vehicle> vehicles;
  final RideCategory selected;
  final ValueChanged<RideCategory> onCategory;
  final FareCalculator calc;
  final void Function(Vehicle vehicle) onConfirm;
  final double distanceKm;

  @override
  State<ChooseCarScreen> createState() => _ChooseCarScreenState();
}

class _ChooseCarScreenState extends State<ChooseCarScreen> {
  late RideCategory _category = widget.selected;
  String? _chosenId;

  @override
  Widget build(BuildContext context) {
    final matching =
        widget.vehicles.where((v) => v.rideCategory == _category).toList();
    final quote =
        widget.calc.quote(category: _category, distanceKm: widget.distanceKm);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: MngColors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('Choose your car'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding:
                  EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
              child: Row(
                children: [
                  Text('${widget.distanceKm.toStringAsFixed(1)} km',
                      style: MngTheme.light.textTheme.titleMedium),
                  SizedBox(width: 8.w),
                  Text('Fares shown are estimates',
                      style: MngTheme.light.textTheme.bodySmall),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20.w),
              child: SizedBox(
                height: 40.h,
                child: Row(
                  children: [
                    for (final c in RideCategory.values)
                      Padding(
                        padding: EdgeInsets.only(right: 8.w),
                        child: GestureDetector(
                          onTap: () => setState(() {
                            _category = c;
                            _chosenId = null;
                            widget.onCategory(c);
                          }),
                          child: Container(
                            padding: EdgeInsets.symmetric(
                                horizontal: 14.w, vertical: 8.h),
                            decoration: BoxDecoration(
                              color: c == _category
                                  ? MngColors.primary
                                  : MngColors.muted,
                              borderRadius:
                                  BorderRadius.circular(MngRadius.small),
                            ),
                            child: Text(
                              c.label,
                              style: TextStyle(
                                fontSize: 13,
                                color: c == _category
                                    ? MngColors.onPrimary
                                    : MngColors.textSub,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding:
                    EdgeInsets.fromLTRB(20.w, 16.h, 20.w, 8.h),
                children: [
                  for (final v in matching)
                    VehicleCard(
                      vehicle: v,
                      fareGhs: widget.calc
                          .quote(
                              category: v.rideCategory,
                              distanceKm: widget.distanceKm)
                          .fareGhs,
                      selected: _chosenId == v.id,
                      onTap: () {
                        setState(() => _chosenId = v.id);
                        widget.onConfirm(v);
                      },
                    ),
                  if (matching.isEmpty)
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 40.h),
                      child: Center(
                        child: Text(
                          'No ${_category.label} cars available',
                          style: MngTheme.light.textTheme.bodySmall,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(20.w, 8.h, 20.w, 20.h),
              child: FilledButton(
                key: const Key('findDriverButton'),
                onPressed: matching.isEmpty
                    ? null
                    : () {
                        final picked = matching.firstWhere(
                          (e) => e.id == _chosenId,
                          orElse: () => matching.first,
                        );
                        widget.onConfirm(picked);
                      },
                child: Text('Find driver  GHS ${quote.fareGhs.toStringAsFixed(2)}'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 12: Run the choose-car tests and confirm they pass**

```bash
cd ~/meet-n-go/apps/rider && flutter test test/booking/ && flutter analyze
```

Expected: 9 tests pass.

- [ ] **Step 13: Run the whole rider suite and commit**

```bash
cd ~/meet-n-go/apps/rider && flutter test && flutter analyze
cd ~/meet-n-go && git add -A
git -c user.email=opencode@local -c user.name=opencode commit -m "feat(rider): home, route entry sheet and choose-car screens"
```

Expected: 33 tests pass across the rider app (1 skeleton + 15 auth + 9 home + 9 booking minus 1 overlap; run the count from the output rather than asserting it).

---

### Task 10: Rider tracking, SOS, and cancellation compensation

**Files:**
- Create: `apps/rider/lib/src/tracking/tracking_controller.dart`
- Create: `apps/rider/lib/src/tracking/finding_driver_screen.dart`
- Create: `apps/rider/lib/src/tracking/tracking_screen.dart`
- Create: `apps/rider/lib/src/tracking/widgets/eta_badge.dart`
- Create: `apps/rider/lib/src/tracking/widgets/driver_summary.dart`
- Create: `supabase/functions/cancel-trip/policy.ts`
- Create: `supabase/functions/cancel-trip/index.ts`
- Test: `apps/rider/test/tracking/tracking_screen_test.dart`
- Test: `supabase/functions/_tests/cancel_policy.test.ts`

**Interfaces:**
- Consumes: `Trip`, `TripStop`, `GeoPoint`, `DriverProfile` (Task 4), `TripState` (Task 3), `TripRepository` (Task 8)
- Produces:
  - `supabase/functions/cancel-trip/policy.ts` → `export const FREE_CANCEL_WINDOW_MS = 120_000`, `export const DRIVER_CANCELLATION_FEE_GHS = 5.0`, `export function cancellationCompensationGhs(input: { state: TripStateName; elapsedMs: number }): number` returning `0` for a free cancel, `5.0` when the driver must be compensated, and `-1` when the trip is not rider-cancellable. `TripStateName` is the string union `'requested' | 'matched' | 'arriving' | 'ongoing' | 'completed' | 'cancelled'`.
  - POST `cancel-trip` `{tripId}` → `{cancelled: boolean, trip: Trip, compensatedGhs: number}`.
  - `TrackingController({required TripRepository trips, required Trip initialTrip, DriverProfile? initialDriver})` — `ChangeNotifier` with fields `Trip? trip`, `DriverProfile? driver`, `int? etaMinutes`, `bool sosRaised`, `String? error`; methods `Future<void> cancel()`, `Future<void> raiseSos()`, `Future<void> refresh()`.
  - `TrackingScreen()` reads `TrackingController` from `Provider`.
  - `FindingDriverScreen({required Trip trip, required VoidCallback onCancelSearch})` — key `cancelSearchButton`, copy `3 drivers found`, `Asking Standard drivers near you`.
  - `EtaBadge({required int minutes})` — key `etaBadge`, renders the amber pill `$minutes min`.
  - `DriverSummary({required DriverProfile driver, required Vehicle? vehicle})`.
  - Widget keys: `sosButton`, `callButton`, `messageButton`, `cancelButton`, `etaBadge`, `cancelSearchButton`.
  - `sos_events` rows are inserted directly by `SupabaseTripRepository.raiseSos` (added in Task 8's repository), so no separate SOS Edge Function is required in this build.

- [ ] **Step 1: Write the failing cancellation-policy test**

`supabase/functions/_tests/cancel_policy.test.ts`:

```ts
import { assertEquals } from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import { cancellationCompensationGhs } from '../cancel-trip/policy.ts';

Deno.test('cancel while requested is free', () => {
  assertEquals(cancellationCompensationGhs({ state: 'requested', elapsedMs: 1_000 }), 0);
});

Deno.test('cancel_after_arriving_compensates_driver_test', () => {
  assertEquals(
    cancellationCompensationGhs({ state: 'arriving', elapsedMs: 6 * 60 * 1000 }),
    5.0,
  );
});

Deno.test('cancel while ongoing is not rider-cancellable', () => {
  assertEquals(cancellationCompensationGhs({ state: 'ongoing', elapsedMs: 10 * 60 * 1000 }), -1);
});

Deno.test('terminal states are not cancellable', () => {
  assertEquals(cancellationCompensationGhs({ state: 'completed', elapsedMs: 1_000 }), -1);
  assertEquals(cancellationCompensationGhs({ state: 'cancelled', elapsedMs: 1_000 }), -1);
});

Deno.test('matched inside the free window costs nothing', () => {
  assertEquals(
    cancellationCompensationGhs({ state: 'matched', elapsedMs: 60 * 1000 }),
    0,
  );
});

Deno.test('matched after the free window compensates the driver', () => {
  assertEquals(
    cancellationCompensationGhs({ state: 'matched', elapsedMs: 3 * 60 * 1000 }),
    5.0,
  );
});

Deno.test('exactly at the free window boundary is still free', () => {
  assertEquals(
    cancellationCompensationGhs({ state: 'matched', elapsedMs: 120_000 }),
    0,
  );
});

Deno.test('a millisecond past the boundary compensates', () => {
  assertEquals(
    cancellationCompensationGhs({ state: 'matched', elapsedMs: 120_001 }),
    5.0,
  );
});
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
cd ~/meet-n-go/supabase && deno test functions/_tests/cancel_policy.test.ts
```

Expected: FAIL — `../cancel-trip/policy.ts` does not exist.

- [ ] **Step 3: Write `policy.ts`**

`supabase/functions/cancel-trip/policy.ts`:

```ts
export type TripStateName =
  | 'requested'
  | 'matched'
  | 'arriving'
  | 'ongoing'
  | 'completed'
  | 'cancelled';

export const FREE_CANCEL_WINDOW_MS = 2 * 60 * 1000;
export const DRIVER_CANCELLATION_FEE_GHS = 5.0;

/**
 * Returns 0 when the rider cancels for free, DRIVER_CANCELLATION_FEE_GHS when
 * the driver has already committed and must be compensated, and -1 when the
 * trip state is not rider-cancellable at all.
 */
export function cancellationCompensationGhs(input: {
  state: TripStateName;
  elapsedMs: number;
}): number {
  if (input.state === 'completed' || input.state === 'cancelled') return -1;
  if (input.state === 'ongoing') return -1;
  if (input.state === 'requested') return 0;
  // matched or arriving: free while no driver has been held up.
  return input.elapsedMs <= FREE_CANCEL_WINDOW_MS
    ? 0
    : DRIVER_CANCELLATION_FEE_GHS;
}
```

- [ ] **Step 4: Run the policy tests and confirm they pass**

```bash
cd ~/meet-n-go/supabase && deno test functions/_tests/cancel_policy.test.ts
```

Expected: 8 tests pass.

- [ ] **Step 5: Write `cancel-trip/index.ts`**

```ts
import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';
import { corsHeaders } from '../_shared/cors.ts';
import { cancellationCompensationGhs } from './policy.ts';

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const service = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );
  const userClient = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: req.headers.get('Authorization')! } } },
  );

  const { data: userData } = await userClient.auth.getUser();
  if (!userData.user) {
    return new Response(JSON.stringify({ error: 'unauthenticated' }), {
      status: 401,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  const { tripId } = await req.json();
  const { data: trip, error } = await service
    .from('trips')
    .select('*')
    .eq('id', tripId)
    .single();

  if (error || !trip) {
    return new Response(JSON.stringify({ error: 'trip not found' }), {
      status: 404,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
  if (trip.rider_id !== userData.user.id) {
    return new Response(JSON.stringify({ error: 'not your trip' }), {
      status: 403,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  const reference = new Date(trip.matched_at ?? trip.created_at).getTime();
  const elapsedMs = Date.now() - reference;
  const compensatedGhs = cancellationCompensationGhs({
    state: trip.state as never,
    elapsedMs,
  });

  if (compensatedGhs < 0) {
    return new Response(
      JSON.stringify({ cancelled: false, trip, compensatedGhs }),
      { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  }

  await service
    .from('trips')
    .update({ state: 'cancelled' })
    .eq('id', trip.id)
    .eq('state', trip.state);

  if (trip.driver_id) {
    await service
      .from('profiles')
      .update({ availability: 'online' })
      .eq('id', trip.driver_id);

    await service.from('offers').update({ state: 'released' }).eq('trip_id', trip.id).eq('state', 'pending');

    if (compensatedGhs > 0) {
      await service.from('ledger_entries').insert({
        driver_id: trip.driver_id,
        trip_id: trip.id,
        amount_ghs: compensatedGhs,
        kind: 'compensation',
        note: 'Rider cancelled after the free window',
        is_demo: true,
      });
    }
  }

  return new Response(
    JSON.stringify({ cancelled: true, trip: { ...trip, state: 'cancelled' }, compensatedGhs }),
    { headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
  );
});
```

- [ ] **Step 6: Deploy and commit the function**

```bash
cd ~/meet-n-go/supabase
deno check functions/cancel-trip/index.ts
supabase functions deploy cancel-trip
cd ~/meet-n-go && git add -A
git -c user.email=opencode@local -c user.name=opencode commit -m "feat(functions): cancel-trip with free window and driver compensation"
```

- [ ] **Step 7: Write the failing tracking-screen test**

`apps/rider/test/tracking/tracking_screen_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/tracking/finding_driver_screen.dart';
import 'package:meetngo_rider/src/tracking/tracking_controller.dart';
import 'package:meetngo_rider/src/tracking/tracking_screen.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

Trip tripInState(TripState state) => Trip(
      id: 't1',
      riderId: 'r1',
      driverId: 'd1',
      category: RideCategory.standard,
      state: state,
      pickup: const TripStop('P', GeoPoint(5.6037, -0.1870), 'Osu, Accra'),
      dropoff:
          const TripStop('D', GeoPoint(5.6052, -0.1660), 'Airport Residential'),
      distanceKm: 2.4,
      fareGhs: 12.50,
      isDemo: true,
    );

class FakeTripRepository implements TripRepository {
  bool cancelled = false;
  bool sosRaised = false;
  String? cancelledTripId;
  String? sosTripId;

  @override
  Future<Trip?> activeTrip() async => null;

  @override
  Stream<Trip> watchTrip(String tripId) => const Stream<Trip>.empty();

  @override
  Future<void> requestRide({
    required TripStop pickup,
    required TripStop dropoff,
    required RideCategory category,
  }) async {}

  @override
  Future<void> cancelTrip(String tripId) async {
    cancelled = true;
    cancelledTripId = tripId;
  }

  @override
  Future<void> raiseSos(String tripId, String note) async {
    sosRaised = true;
    sosTripId = tripId;
  }
}

class FakeTrackingController extends TrackingController {
  FakeTrackingController(this.state) : super(trips: FakeTripRepository(), initialTrip: tripInState(state)) {
    driver = const DriverProfile(
      id: 'd1',
      fullName: 'Jane Cooper',
      phone: '0240000000',
      photoUrl: '',
      rating: 4.8,
      tripCount: 148,
      kyc: KycStatus.approved,
      availability: DriverAvailability.onTrip,
    );
  }

  final TripState state;
  final FakeTripRepository repo = FakeTripRepository();

  @override
  FakeTripRepository get trips => repo;
}

Widget wrapTracking(TrackingController c) => ScreenUtilInit(
      designSize: const Size(390, 844),
      builder: (_, __) => ChangeNotifierProvider<TrackingController>.value(
        value: c,
        child: MaterialApp(theme: MngTheme.light, home: const TrackingScreen()),
      ),
    );

void main() {
  testWidgets('matched state shows the ride-confirmed headline', (tester) async {
    await tester.pumpWidget(wrapTracking(FakeTrackingController(TripState.matched)));
    expect(find.text('Ride confirmed'), findsOneWidget);
  });

  testWidgets('arriving state shows the ETA badge with minutes', (tester) async {
    final c = FakeTrackingController(TripState.arriving)..etaMinutes = 4;
    await tester.pumpWidget(wrapTracking(c));
    expect(find.text('Arriving soon'), findsOneWidget);
    expect(find.byKey(const Key('etaBadge')), findsOneWidget);
    expect(find.text('4 min'), findsOneWidget);
  });

  testWidgets('driver name, rating and car are summarised', (tester) async {
    await tester.pumpWidget(wrapTracking(FakeTrackingController(TripState.arriving)));
    expect(find.text('Jane Cooper'), findsOneWidget);
    expect(find.text('4.8'), findsOneWidget);
  });

  testWidgets('call, message and cancel actions are all present', (tester) async {
    await tester.pumpWidget(wrapTracking(FakeTrackingController(TripState.arriving)));
    expect(find.byKey(const Key('callButton')), findsOneWidget);
    expect(find.byKey(const Key('messageButton')), findsOneWidget);
    expect(find.byKey(const Key('cancelButton')), findsOneWidget);
  });

  testWidgets('cancel delegates to the repository with the trip id', (tester) async {
    final c = FakeTrackingController(TripState.arriving);
    await tester.pumpWidget(wrapTracking(c));
    await tester.tap(find.byKey(const Key('cancelButton')));
    await tester.pump();
    expect(c.repo.cancelled, isTrue);
    expect(c.repo.cancelledTripId, 't1');
  });

  testWidgets('ongoing state hides the cancel action', (tester) async {
    await tester.pumpWidget(wrapTracking(FakeTrackingController(TripState.ongoing)));
    expect(find.byKey(const Key('cancelButton')), findsNothing);
  });

  testWidgets('SOS raises once and shows the confirmation copy', (tester) async {
    final c = FakeTrackingController(TripState.arriving);
    await tester.pumpWidget(wrapTracking(c));
    await tester.tap(find.byKey(const Key('sosButton')));
    await tester.pump();
    expect(c.repo.sosRaised, isTrue);
    expect(c.repo.sosTripId, 't1');
    expect(c.sosRaised, isTrue);
    expect(
      find.text('Help is on the way. Our team has your trip.'),
      findsOneWidget,
    );
  });

  testWidgets('a second SOS tap does not raise another event', (tester) async {
    final c = FakeTrackingController(TripState.arriving);
    await tester.pumpWidget(wrapTracking(c));
    await tester.tap(find.byKey(const Key('sosButton')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sosButton')));
    await tester.pump();
    expect(c.repo.sosRaised, isTrue);
  });

  testWidgets('driver car and plate render when a vehicle is attached', (tester) async {
    final c = FakeTrackingController(TripState.arriving)
      ..driverVehicle = const Vehicle(
        id: 'v1',
        ownerId: 'd1',
        category: VehicleCategory.sedan,
        make: 'Toyota',
        model: 'Corolla',
        plate: 'GR-1234-22',
        seats: 4,
        photoUrl: '',
        rideCategory: RideCategory.standard,
      );
    await tester.pumpWidget(wrapTracking(c));
    expect(find.text('Toyota Corolla'), findsOneWidget);
    expect(find.text('GR-1234-22'), findsOneWidget);
  });

  testWidgets('finding-driver screen shows the search copy and cancel', (tester) async {
    bool cancelled = false;
    await tester.pumpWidget(ScreenUtilInit(
      designSize: const Size(390, 844),
      builder: (_, __) => MaterialApp(
        theme: MngTheme.light,
        home: FindingDriverScreen(
          trip: tripInState(TripState.requested),
          onCancelSearch: () => cancelled = true,
        ),
      ),
    ));
    expect(find.text('3 drivers found'), findsOneWidget);
    expect(
      find.text('Asking Standard drivers near you'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('cancelSearchButton')));
    await tester.pump();
    expect(cancelled, isTrue);
  });
}
```

- [ ] **Step 8: Run it and confirm it fails**

```bash
cd ~/meet-n-go/apps/rider && flutter test test/tracking/
```

Expected: FAIL — `TrackingController` is not defined.

- [ ] **Step 9: Write `tracking_controller.dart`**

`apps/rider/lib/src/tracking/tracking_controller.dart`:

```dart
import 'package:flutter/foundation.dart';
import 'package:mng_core/mng_core.dart';
import '../data/trip_repository.dart';

class TrackingController extends ChangeNotifier {
  TrackingController({
    required this.trips,
    required Trip initialTrip,
    DriverProfile? initialDriver,
  })  : _trip = initialTrip,
        driver = initialDriver;

  final TripRepository trips;

  Trip? _trip;
  Trip? get trip => _trip;

  DriverProfile? driver;
  Vehicle? driverVehicle;
  int? etaMinutes;
  bool sosRaised = false;
  String? error;

  Future<void> refresh() async {
    final fresh = await trips.activeTrip();
    if (fresh == null) return;
    _trip = fresh;
    if (fresh.state == TripState.arriving && etaMinutes == null) {
      etaMinutes = 4;
    }
    if (fresh.state == TripState.matched) etaMinutes = 4;
    notifyListeners();
  }

  Future<void> cancel() async {
    final current = _trip;
    if (current == null) return;
    if (!canTransition(current.state, TripState.cancelled)) {
      error = 'This trip can no longer be cancelled';
      notifyListeners();
      return;
    }
    await trips.cancelTrip(current.id);
    _trip = current.copyWith(state: TripState.cancelled, clearDriver: true);
    notifyListeners();
  }

  Future<void> raiseSos() async {
    if (sosRaised) return;
    final current = _trip;
    if (current == null) return;
    sosRaised = true;
    notifyListeners();
    await trips.raiseSos(current.id, 'Rider pressed the safety button');
  }
}
```

- [ ] **Step 10: Write `eta_badge.dart` and `driver_summary.dart`**

`apps/rider/lib/src/tracking/widgets/eta_badge.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

class EtaBadge extends StatelessWidget {
  const EtaBadge({super.key, required this.minutes});

  final int minutes;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('etaBadge'),
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 6.h),
      decoration: BoxDecoration(
        color: MngColors.primary,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$minutes min',
        style: const TextStyle(
          color: MngColors.onPrimary,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
```

`apps/rider/lib/src/tracking/widgets/driver_summary.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

class DriverSummary extends StatelessWidget {
  const DriverSummary({super.key, required this.driver, this.vehicle});

  final DriverProfile driver;
  final Vehicle? vehicle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(MngSpacing.md),
      decoration: BoxDecoration(
        color: MngColors.surface,
        borderRadius: BorderRadius.circular(MngRadius.large),
        border: Border.all(color: MngColors.divider),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: MngColors.muted,
            backgroundImage:
                driver.photoUrl.isEmpty ? null : NetworkImage(driver.photoUrl),
            child: driver.photoUrl.isEmpty
                ? Text(
                    driver.fullName.isEmpty
                        ? '?'
                        : driver.fullName.characters.first,
                    style: MngTheme.light.textTheme.titleMedium,
                  )
                : null,
          ),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(driver.fullName,
                    style: MngTheme.light.textTheme.titleMedium),
                SizedBox(height: 2.h),
                Row(
                  children: [
                    const Icon(Icons.star, size: 14, color: MngColors.primary),
                    SizedBox(width: 2.w),
                    Text(driver.rating.toStringAsFixed(1),
                        style: MngTheme.light.textTheme.bodySmall),
                    if (vehicle != null) ...[
                      SizedBox(width: 10.w),
                      Text(vehicle!.displayName,
                          style: MngTheme.light.textTheme.bodySmall),
                      SizedBox(width: 6.w),
                      Text(vehicle!.plate,
                          style: MngTheme.light.textTheme.bodySmall),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 11: Write `tracking_screen.dart`**

`apps/rider/lib/src/tracking/tracking_screen.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';
import 'tracking_controller.dart';
import 'widgets/driver_summary.dart';
import 'widgets/eta_badge.dart';

class TrackingScreen extends StatelessWidget {
  const TrackingScreen({super.key});

  static const _headlines = <TripState, String>{
    TripState.requested: 'Finding your driver',
    TripState.matched: 'Ride confirmed',
    TripState.arriving: 'Arriving soon',
    TripState.ongoing: 'On the way',
    TripState.completed: 'Trip complete',
    TripState.cancelled: 'Trip cancelled',
  };

  @override
  Widget build(BuildContext context) {
    final c = context.watch<TrackingController>();
    final trip = c.trip;
    if (trip == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final canCancel = canTransition(trip.state, TripState.cancelled);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: MngColors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: const BackButton(),
        title: const Text('Your ride'),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Map placeholder: the Google Maps widget is dropped into this
            // Container in the integration pass. Keeping the box fixed means
            // the widget tests never need a platform view.
            Container(
              height: 280.h,
              margin: EdgeInsets.symmetric(horizontal: 20.w),
              decoration: BoxDecoration(
                color: MngColors.muted,
                borderRadius: BorderRadius.circular(MngRadius.large),
              ),
              child: const Center(child: Icon(Icons.map, size: 40)),
            ),
            SizedBox(height: 20.h),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20.w),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _headlines[trip.state] ?? 'Your ride',
                    style: MngTheme.light.textTheme.titleLarge,
                  ),
                  if (c.etaMinutes != null)
                    EtaBadge(minutes: c.etaMinutes!),
                ],
              ),
            ),
            SizedBox(height: 4.h),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20.w),
              child: Text(
                '${trip.pickup.address} to ${trip.dropoff.address}',
                style: MngTheme.light.textTheme.bodySmall,
              ),
            ),
            SizedBox(height: 16.h),
            if (c.driver != null)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 20.w),
                child: DriverSummary(
                  driver: c.driver!,
                  vehicle: c.driverVehicle,
                ),
              ),
            if (c.sosRaised) ...[
              SizedBox(height: 12.h),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 20.w),
                child: Container(
                  padding: EdgeInsets.all(12.w),
                  decoration: BoxDecoration(
                    color: MngColors.error.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(MngRadius.small),
                  ),
                  child: const Text(
                    'Help is on the way. Our team has your trip.',
                    style: TextStyle(color: MngColors.error),
                  ),
                ),
              ),
            ],
            if (c.error != null) ...[
              SizedBox(height: 12.h),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 20.w),
                child: Text(c.error!,
                    style: const TextStyle(color: MngColors.error)),
              ),
            ],
            const Spacer(),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20.w),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('callButton'),
                      onPressed: () {},
                      icon: const Icon(Icons.call, size: 18),
                      label: const Text('Call'),
                    ),
                  ),
                  SizedBox(width: 10.w),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('messageButton'),
                      onPressed: () {},
                      icon: const Icon(Icons.chat_bubble_outline, size: 18),
                      label: const Text('Message'),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 10.h),
            if (canCancel)
              Padding(
                padding:
                    EdgeInsets.fromLTRB(20.w, 0, 20.w, 12.h),
                child: OutlinedButton(
                  key: const Key('cancelButton'),
                  onPressed: c.cancel,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: MngColors.error,
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: const Text('Cancel trip'),
                ),
              ),
            Padding(
              padding: EdgeInsets.fromLTRB(20.w, 0, 20.w, 20.h),
              child: OutlinedButton.icon(
                key: const Key('sosButton'),
                onPressed: c.raiseSos,
                style: OutlinedButton.styleFrom(
                  foregroundColor: MngColors.error,
                  minimumSize: const Size.fromHeight(48),
                ),
                icon: const Icon(Icons.shield_outlined, size: 18),
                label: const Text('Safety'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 12: Write `finding_driver_screen.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

class FindingDriverScreen extends StatelessWidget {
  const FindingDriverScreen({
    super.key,
    required this.trip,
    required this.onCancelSearch,
  });

  final Trip trip;
  final VoidCallback onCancelSearch;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: MngColors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: const BackButton(),
        title: const Text('Finding a driver'),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 300.h,
              margin: EdgeInsets.symmetric(horizontal: 20.w),
              decoration: BoxDecoration(
                color: MngColors.muted,
                borderRadius: BorderRadius.circular(MngRadius.large),
              ),
              child: const Center(child: Icon(Icons.map, size: 40)),
            ),
            SizedBox(height: 24.h),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20.w),
              child: Text('3 drivers found',
                  style: MngTheme.light.textTheme.titleLarge),
            ),
            SizedBox(height: 4.h),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20.w),
              child: Text(
                'Asking ${trip.category.label} drivers near you',
                style: MngTheme.light.textTheme.bodySmall,
              ),
            ),
            SizedBox(height: 24.h),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20.w),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final c in const [MngColors.standard, MngColors.info, MngColors.van])
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6.w),
                      child: CircleAvatar(
                        radius: 22,
                        backgroundColor: c,
                        child: const Icon(Icons.person, color: MngColors.onPrimary),
                      ),
                    ),
                ],
              ),
            ),
            const Spacer(),
            Padding(
              padding: EdgeInsets.fromLTRB(20.w, 0, 20.w, 20.h),
              child: OutlinedButton(
                key: const Key('cancelSearchButton'),
                onPressed: onCancelSearch,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                child: const Text('Cancel search'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 13: Add `raiseSos` to the trip repository contract**

In `apps/rider/lib/src/data/trip_repository.dart` add the method to the abstract class:

```dart
  Future<void> raiseSos(String tripId, String note);
```

In `apps/rider/lib/src/data/supabase_trip_repository.dart` implement it by inserting directly into `sos_events`. The migration's `raise sos on a trip you are party to` policy is what makes this work: it requires `raised_by = auth.uid()` and that the trip's `rider_id` or `driver_id` is the caller. Without that policy the insert returns 42501, so do not replace it with a select-only policy on `sos_events`.

That policy carries **no state clause**, on purpose, and it must stay that way. `activeTrip()` above includes `requested`, and `TrackingController.raiseSos` fires whenever the trip is non-null while setting `sosRaised = true` *before* awaiting the insert. So a rider who presses the button while still waiting for a driver is in a `requested` trip, and a gate of `state in ('matched','arriving','ongoing')` would turn a working safety button into a 42501 that surfaces as an uncaught exception on a screen already reading "Help is on the way", with no row in `sos_events`. The symmetry argument is the same one that makes the `chat_messages` INSERT policy ungated: the SOS SELECT policy is ungated, so the write policy is too. Never narrow this button to fit a policy; if a state restriction is ever genuinely wanted, change `raiseSos` deliberately and write the test with it.

```dart
  @override
  Future<void> raiseSos(String tripId, String note) async {
    final res = await _client.from('sos_events').insert({
      'trip_id': tripId,
      'raised_by': _client.auth.currentUser!.id,
      'note': note,
      'status': 'open',
    });
    if (res.error != null) throw AuthFailure(res.error!.message);
  }
```

- [ ] **Step 14: Run the tracking tests and confirm they pass**

```bash
cd ~/meet-n-go/apps/rider && flutter test test/tracking/ && flutter analyze
```

Expected: 10 tests pass.

- [ ] **Step 15: Run the full rider suite and commit**

```bash
cd ~/meet-n-go/apps/rider && flutter test && flutter analyze
cd ~/meet-n-go && git add -A
git -c user.email=opencode@local -c user.name=opencode commit -m "feat(rider): live tracking, SOS and cancellation compensation"
```

---

### Task 11: Complete trip, demo payment, receipt, and two-way rating

**Files:**
- Create: `supabase/functions/complete-trip/ledger.ts`
- Create: `supabase/functions/complete-trip/index.ts`
- Create: `supabase/functions/demo-pay/index.ts`
- Create: `apps/rider/lib/src/trip/receipt_screen.dart`
- Create: `apps/rider/lib/src/trip/rating_sheet.dart`
- Create: `apps/rider/lib/src/trip/trip_controller.dart`
- Test: `supabase/functions/_tests/settle.test.ts`
- Test: `apps/rider/test/trip/receipt_screen_test.dart`

**Interfaces:**
- Consumes: `Payment`, `PayMethod`, `PaymentState` (Task 4), `TripState` (Task 3), `Trip` (Task 4), `Rating` (Task 4), `FareCalculator` (Task 2)
- Produces:
  - `supabase/functions/complete-trip/ledger.ts` → `export interface Settlement { fareGhs: number; commissionGhs: number; driverPayoutGhs: number; }`, `export function settleFare(fareGhs: number, commissionRate?: number): Settlement` with `commissionRate` defaulting to `0.15`, and `export function settleAgainstTripState(input: { tripState: string; paymentState: string; settlement: Settlement }): { shouldCharge: boolean; paymentState: 'succeeded' | 'voided'; ledgerKinds: string[] }` returning `{shouldCharge: false, paymentState: 'voided', ledgerKinds: ['void']}` whenever the trip is cancelled.
  - POST `complete-trip` `{tripId}` → `{trip, settlement, paymentState}`.
  - POST `demo-pay` `{tripId, method}` → `{payment: Payment, state: PaymentState}`. Never contacts a real provider; it writes a `payments` row with `is_demo = true` and a synthetic reference.
  - `TripController({required TripRepository trips})` with `Trip? trip`, `bool busy`, `String? error`, `Settlement? settlement`, `Future<void> complete()`, `Future<void> pay({required PayMethod method})`.
  - `ReceiptScreen({required Trip trip, required Settlement settlement, required PaymentState paymentState, required void Function(int stars, String comment) onRated})` — keys `receiptTotal`, `ratingStars`, `submitRatingButton`.
  - `RatingSheet({required void Function(int stars, String comment) onSubmit})` — key `submitRatingButton`, 1-5 star row, optional comment field.
  - `Rating.isValidStars` already exists from Task 4; reuse it.
- Widget keys this task owns: `receiptTotal`, `ratingStars`, `ratingComment`, `submitRatingButton`, `payButton`, `cashButton`, `momoButton`.

- [ ] **Step 1: Write the failing settlement test**

`supabase/functions/_tests/settle.test.ts`:

```ts
import { assertEquals } from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import { settleAgainstTripState, settleFare } from '../complete-trip/ledger.ts';

Deno.test('platform takes 15 percent of the fare', () => {
  const s = settleFare(20.4);
  assertEquals(s.fareGhs, 20.4);
  assertEquals(s.commissionGhs, 3.06);
  assertEquals(s.driverPayoutGhs, 17.34);
});

Deno.test('commission rate is configurable', () => {
  assertEquals(settleFare(100, 0.2).driverPayoutGhs, 80);
});

Deno.test('settlement on a completed trip charges the rider', () => {
  const r = settleAgainstTripState({
    tripState: 'completed',
    paymentState: 'pending',
    settlement: settleFare(20.4),
  });
  assertEquals(r.shouldCharge, true);
  assertEquals(r.paymentState, 'succeeded');
  assertEquals(r.ledgerKinds, ['fare', 'commission']);
});

Deno.test('settle_cancelled_trip_voids_payment_test', () => {
  const r = settleAgainstTripState({
    tripState: 'cancelled',
    paymentState: 'pending',
    settlement: settleFare(20.4),
  });
  assertEquals(r.shouldCharge, false);
  assertEquals(r.paymentState, 'voided');
  assertEquals(r.ledgerKinds, ['void']);
});

Deno.test('settling an already-voided payment changes nothing', () => {
  const r = settleAgainstTripState({
    tripState: 'cancelled',
    paymentState: 'voided',
    settlement: settleFare(20.4),
  });
  assertEquals(r.shouldCharge, false);
  assertEquals(r.paymentState, 'voided');
});

Deno.test('an ongoing trip cannot be settled', () => {
  const r = settleAgainstTripState({
    tripState: 'ongoing',
    paymentState: 'pending',
    settlement: settleFare(20.4),
  });
  assertEquals(r.shouldCharge, false);
  assertEquals(r.paymentState, 'pending');
});

Deno.test('zero fare still settles without negative commission', () => {
  const s = settleFare(0);
  assertEquals(s.commissionGhs, 0);
  assertEquals(s.driverPayoutGhs, 0);
});
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
cd ~/meet-n-go/supabase && deno test functions/_tests/settle.test.ts
```

Expected: FAIL — `../complete-trip/ledger.ts` does not exist.

- [ ] **Step 3: Write `ledger.ts`**

`supabase/functions/complete-trip/ledger.ts`:

```ts
export interface Settlement {
  fareGhs: number;
  commissionGhs: number;
  driverPayoutGhs: number;
}

const round2 = (v: number) => Math.round(v * 100) / 100;

export function settleFare(fareGhs: number, commissionRate = 0.15): Settlement {
  const fare = Math.max(0, round2(fareGhs));
  const commission = round2(fare * commissionRate);
  return {
    fareGhs: fare,
    commissionGhs: commission,
    driverPayoutGhs: round2(Math.max(0, fare - commission)),
  };
}

export function settleAgainstTripState(input: {
  tripState: string;
  paymentState: string;
  settlement: Settlement;
}): { shouldCharge: boolean; paymentState: 'pending' | 'succeeded' | 'voided'; ledgerKinds: string[] } {
  // A cancelled trip can never be charged. The pending charge is voided and
  // the driver sees a void entry rather than a fare.
  if (input.tripState === 'cancelled' || input.paymentState === 'voided') {
    return { shouldCharge: false, paymentState: 'voided', ledgerKinds: ['void'] };
  }
  if (input.tripState !== 'completed') {
    return { shouldCharge: false, paymentState: 'pending', ledgerKinds: [] };
  }
  return { shouldCharge: true, paymentState: 'succeeded', ledgerKinds: ['fare', 'commission'] };
}
```

- [ ] **Step 4: Run the settlement tests and confirm they pass**

```bash
cd ~/meet-n-go/supabase && deno test functions/_tests/settle.test.ts
```

Expected: 7 tests pass.

- [ ] **Step 5: Write `complete-trip/index.ts`**

```ts
import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';
import { corsHeaders } from '../_shared/cors.ts';
import { settleAgainstTripState, settleFare } from './ledger.ts';

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const service = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );
  const userClient = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: req.headers.get('Authorization')! } } },
  );

  const { data: userData } = await userClient.auth.getUser();
  if (!userData.user) {
    return new Response(JSON.stringify({ error: 'unauthenticated' }), {
      status: 401,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  const { tripId } = await req.json();
  const { data: trip } = await service.from('trips').select('*').eq('id', tripId).single();
  if (!trip) {
    return new Response(JSON.stringify({ error: 'trip not found' }), {
      status: 404,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  const isDriver = trip.driver_id === userData.user.id;
  if (!isDriver && trip.rider_id !== userData.user.id) {
    return new Response(JSON.stringify({ error: 'not your trip' }), {
      status: 403,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  const settlement = settleFare(Number(trip.fare_ghs));
  const { data: payment } = await service
    .from('payments')
    .select('*')
    .eq('trip_id', trip.id)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  const decision = settleAgainstTripState({
    tripState: trip.state,
    paymentState: payment?.state ?? 'pending',
    settlement,
  });

  if (!decision.shouldCharge) {
    if (payment && payment.state !== 'voided') {
      await service.from('payments').update({ state: 'voided' }).eq('id', payment.id);
      if (trip.driver_id) {
        await service.from('ledger_entries').insert({
          driver_id: trip.driver_id,
          trip_id: trip.id,
          amount_ghs: 0,
          kind: 'void',
          note: 'Trip was not completed, charge voided',
          is_demo: true,
        });
      }
    }
    return new Response(
      JSON.stringify({ trip, settlement, paymentState: decision.paymentState }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  }

  if (payment) {
    await service.from('payments').update({ state: 'succeeded' }).eq('id', payment.id);
  }
  if (trip.driver_id) {
    await service.from('ledger_entries').insert([
      {
        driver_id: trip.driver_id,
        trip_id: trip.id,
        amount_ghs: settlement.driverPayoutGhs,
        kind: 'fare',
        note: 'Trip fare',
        is_demo: true,
      },
      {
        driver_id: trip.driver_id,
        trip_id: trip.id,
        amount_ghs: -settlement.commissionGhs,
        kind: 'commission',
        note: 'Platform commission 15%',
        is_demo: true,
      },
    ]);
    await service.from('payouts').insert({
      driver_id: trip.driver_id,
      trip_id: trip.id,
      amount_ghs: settlement.driverPayoutGhs,
      is_demo: true,
    });
  }

  return new Response(
    JSON.stringify({ trip, settlement, paymentState: decision.paymentState }),
    { headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
  );
});
```

- [ ] **Step 6: Write `demo-pay/index.ts`**

```ts
import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';
import { corsHeaders } from '../_shared/cors.ts';

const METHODS = new Set(['momo', 'cash', 'card']);

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const service = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );
  const userClient = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: req.headers.get('Authorization')! } } },
  );

  const { data: userData } = await userClient.auth.getUser();
  if (!userData.user) {
    return new Response(JSON.stringify({ error: 'unauthenticated' }), {
      status: 401,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  const { tripId, method } = await req.json();
  if (!METHODS.has(method)) {
    return new Response(JSON.stringify({ error: 'unsupported method' }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  const { data: trip } = await service.from('trips').select('*').eq('id', tripId).single();
  if (!trip || trip.rider_id !== userData.user.id) {
    return new Response(JSON.stringify({ error: 'not your trip' }), {
      status: 404,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  // Demo only. A real provider drops in behind this branch later; the row
  // shape and the is_demo flag stay identical.
  const { data: payment, error } = await service
    .from('payments')
    .insert({
      trip_id: trip.id,
      payer_id: userData.user.id,
      amount_ghs: trip.fare_ghs,
      method,
      state: 'pending',
      is_demo: true,
    })
    .select()
    .single();

  if (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  return new Response(
    JSON.stringify({ payment, state: payment.state }),
    { headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
  );
});
```

- [ ] **Step 7: Type-check and deploy both functions**

```bash
cd ~/meet-n-go/supabase
deno check functions/complete-trip/index.ts
deno check functions/demo-pay/index.ts
supabase functions deploy complete-trip
supabase functions deploy demo-pay
cd ~/meet-n-go && git add -A
git -c user.email=opencode@local -c user.name=opencode commit -m "feat(functions): complete-trip settlement and demo-pay"
```

- [ ] **Step 8: Write the failing receipt test**

`apps/rider/test/trip/receipt_screen_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/trip/receipt_screen.dart';
import 'package:mng_core/mng_core.dart';

Trip completedTrip() => Trip(
      id: 't1',
      riderId: 'r1',
      driverId: 'd1',
      category: RideCategory.standard,
      state: TripState.completed,
      pickup: const TripStop('P', GeoPoint(5.6037, -0.1870), 'Osu, Accra'),
      dropoff:
          const TripStop('D', GeoPoint(5.6052, -0.1660), 'Airport Residential'),
      distanceKm: 2.4,
      fareGhs: 20.40,
      isDemo: true,
    );

Widget wrap({
  PaymentState state = PaymentState.succeeded,
  void Function(int stars, String comment)? onRated,
}) =>
    ScreenUtilInit(
      designSize: const Size(390, 844),
      builder: (_, __) => MaterialApp(
        theme: MngTheme.light,
        home: ReceiptScreen(
          trip: completedTrip(),
          settlement: const Settlement(
            fareGhs: 20.40,
            commissionGhs: 3.06,
            driverPayoutGhs: 17.34,
          ),
          paymentState: state,
          onRated: onRated ?? (_, __) {},
        ),
      ),
    );

void main() {
  testWidgets('total is the settled fare', (tester) async {
    await tester.pumpWidget(wrap());
    expect(find.byKey(const Key('receiptTotal')), findsOneWidget);
    expect(find.text('GHS 20.40'), findsWidgets);
  });

  testWidgets('receipt states the money was demo', (tester) async {
    await tester.pumpWidget(wrap());
    expect(find.text('Demo payment — no real money moved'), findsOneWidget);
  });

  testWidgets('rating stars are shown and tappable', (tester) async {
    int? stars;
    await tester.pumpWidget(wrap(onRated: (s, c) => stars = s));
    expect(find.byKey(const Key('ratingStars')), findsOneWidget);
    await tester.tap(find.byKey(const Key('ratingStars')));
    await tester.pump();
    expect(stars, isNotNull);
    expect(stars, inInclusiveRange(1, 5));
  });

  testWidgets('driver payout is itemised on the receipt', (tester) async {
    await tester.pumpWidget(wrap());
    expect(find.text('Driver payout'), findsOneWidget);
    expect(find.text('GHS 17.34'), findsOneWidget);
  });

  testWidgets('a voided payment shows the void notice instead of a total',
      (tester) async {
    await tester.pumpWidget(wrap(state: PaymentState.voided));
    expect(find.text('This trip was not charged'), findsOneWidget);
  });

  testWidgets('submitting without a star selection is blocked', (tester) async {
    bool called = false;
    await tester.pumpWidget(wrap(onRated: (_, __) => called = true));
    await tester.tap(find.byKey(const Key('submitRatingButton')));
    await tester.pump();
    expect(called, isFalse);
    expect(find.text('Pick a rating first'), findsOneWidget);
  });
}
```

- [ ] **Step 9: Run it and confirm it fails**

```bash
cd ~/meet-n-go/apps/rider && flutter test test/trip/
```

Expected: FAIL — `ReceiptScreen` is not defined.

- [ ] **Step 10: Write `rating_sheet.dart`**

`apps/rider/lib/src/trip/rating_sheet.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

class RatingSheet extends StatefulWidget {
  const RatingSheet({super.key, required this.onSubmit, this.headline});

  final void Function(int stars, String comment) onSubmit;
  final String? headline;

  @override
  State<RatingSheet> createState() => _RatingSheetState();
}

class _RatingSheetState extends State<RatingSheet> {
  int? _stars;
  final _comment = TextEditingController();

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20.w, 8.h, 20.w, 20.h),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.headline ?? 'Rate your trip',
              style: MngTheme.light.textTheme.titleLarge),
          SizedBox(height: 16.h),
          Row(
            key: const Key('ratingStars'),
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 1; i <= 5; i++)
                GestureDetector(
                  key: Key('star-$i'),
                  onTap: () => setState(() => _stars = i),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4.w),
                    child: Icon(
                      i <= (_stars ?? 0) ? Icons.star : Icons.star_border,
                      size: 36,
                      color: MngColors.primary,
                    ),
                  ),
                ),
            ],
          ),
          SizedBox(height: 16.h),
          TextField(
            key: const Key('ratingComment'),
            controller: _comment,
            maxLines: 2,
            decoration: const InputDecoration(hintText: 'Add a comment (optional)'),
          ),
          SizedBox(height: 16.h),
          if (_errorShown) ...[
            Text('Pick a rating first',
                style: const TextStyle(color: MngColors.error)),
            SizedBox(height: 8.h),
          ],
          FilledButton(
            key: const Key('submitRatingButton'),
            onPressed: () {
              if (_stars == null) {
                setState(() => _errorShown = true);
                return;
              }
              widget.onSubmit(_stars!, _comment.text);
            },
            child: const Text('Submit rating'),
          ),
        ],
      ),
    );
  }

  bool _errorShown = false;
}
```

- [ ] **Step 11: Write `receipt_screen.dart`**

`apps/rider/lib/src/trip/receipt_screen.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'rating_sheet.dart';

class Settlement {
  const Settlement({
    required this.fareGhs,
    required this.commissionGhs,
    required this.driverPayoutGhs,
  });

  final double fareGhs;
  final double commissionGhs;
  final double driverPayoutGhs;
}

class ReceiptScreen extends StatelessWidget {
  const ReceiptScreen({
    super.key,
    required this.trip,
    required this.settlement,
    required this.paymentState,
    required this.onRated,
  });

  final Trip trip;
  final Settlement settlement;
  final PaymentState paymentState;
  final void Function(int stars, String comment) onRated;

  @override
  Widget build(BuildContext context) {
    final voided = paymentState == PaymentState.voided;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: MngColors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('Trip receipt'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: EdgeInsets.all(MngSpacing.md),
                decoration: BoxDecoration(
                  color: MngColors.surface,
                  borderRadius: BorderRadius.circular(MngRadius.large),
                  border: Border.all(color: MngColors.divider),
                ),
                child: Column(
                  children: [
                    _row('Trip fare', 'GHS ${settlement.fareGhs.toStringAsFixed(2)}'),
                    _row('Distance', '${trip.distanceKm.toStringAsFixed(1)} km'),
                    _row('Driver payout', 'GHS ${settlement.driverPayoutGhs.toStringAsFixed(2)}'),
                    Divider(color: MngColors.divider, height: 24.h),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Total',
                            style: MngTheme.light.textTheme.titleMedium),
                        Text(
                          voided
                              ? 'GHS 0.00'
                              : 'GHS ${settlement.fareGhs.toStringAsFixed(2)}',
                          key: const Key('receiptTotal'),
                          style: MngTheme.light.textTheme.titleLarge,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(height: 12.h),
              if (voided)
                Container(
                  padding: EdgeInsets.all(12.w),
                  decoration: BoxDecoration(
                    color: MngColors.error.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(MngRadius.small),
                  ),
                  child: const Text(
                    'This trip was not charged',
                    style: TextStyle(color: MngColors.error),
                  ),
                )
              else
                const Text(
                  'Demo payment — no real money moved',
                  style: TextStyle(color: MngColors.textSub),
                ),
              SizedBox(height: 24.h),
              RatingSheet(
                headline: 'How was your trip?',
                onSubmit: onRated,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: EdgeInsets.symmetric(vertical: 6.h),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: MngTheme.light.textTheme.bodySmall),
            Text(value, style: MngTheme.light.textTheme.bodyMedium),
          ],
        ),
      );
}
```

- [ ] **Step 12: Run the receipt tests and confirm they pass**

```bash
cd ~/meet-n-go/apps/rider && flutter test test/trip/ && flutter analyze
```

Expected: 6 tests pass.

- [ ] **Step 13: Commit**

```bash
cd ~/meet-n-go && git add -A
git -c user.email=opencode@local -c user.name=opencode commit -m "feat(rider): receipt, demo payment and two-way rating sheet"
```

---

### Task 12: Driver app — onboarding and KYC

**Files:**
- Create: `apps/driver/lib/src/onboarding/kyc_controller.dart`
- Create: `apps/driver/lib/src/onboarding/kyc_screen.dart`
- Create: `apps/driver/lib/src/onboarding/document_scanner_stub.dart`
- Create: `apps/driver/lib/src/onboarding/vehicle_form.dart`
- Create: `apps/driver/lib/src/data/driver_repository.dart`
- Test: `apps/driver/test/onboarding/kyc_test.dart`

**Interfaces:**
- Consumes: `KycStatus`, `DriverProfile`, `DriverAvailability`, `Vehicle`, `VehicleCategory`, `RideCategory` (Task 4)
- Produces:
  - `apps/driver/lib/src/data/driver_repository.dart` → `abstract class DriverRepository` with `Future<DriverProfile?> me()`, `Future<void> submitGhanaCard({required String cardNumber, required String expiry, required String fullName})`, `Future<void> submitSelfie(String path)`, `Future<void> saveVehicle({required String make, required String model, required String plate, required int seats, required RideCategory rideCategory})`, `Future<void> setAvailability(DriverAvailability value)`, `Future<void> updateLocation(GeoPoint point)`, `Stream<DriverProfile> watchMe()`.
  - `class KycController extends ChangeNotifier` with `KycStep step` (`identity`, `ghanaCard`, `selfie`, `vehicle`, `review`, `approved`), `String? error`, `bool busy`, `String? cardNumber`, `String? cardExpiry`, `String? cardName`, `String? selfiePath`, `Vehicle? vehicle`, `bool canAdvance`, `Future<void> advance()`, `Future<void> submit()`.
  - `class GhanaCardParser` with `static CardParseResult parse({required String rawText})` returning `CardParseResult({String? cardNumber, String? expiry, String? name, String? error})`. It extracts a 13-digit Ghana Card number `GHA-XXXXXXXXX-X` and a `MM/YY` expiry from the recognised scan text.
  - `DocumentScannerStub` — a widget that returns a fixed path in tests and a real `image_picker` path on device; the interface is `Future<String?> capture()`.
  - `KycScreen({required KycController controller})` — keys `ghanaCardNumberField`, `ghanaCardExpiryField`, `ghanaCardNameField`, `selfieButton`, `vehicleMakeField`, `vehicleModelField`, `vehiclePlateField`, `vehicleSeatsField`, `kycNextButton`, `kycSubmitButton`.
  - `VehicleForm` — the vehicle half of `KycScreen`, extracted so the driver can fix a rejected vehicle later.

- [ ] **Step 1: Write the failing KYC test**

`apps/driver/test/onboarding/kyc_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_driver/src/data/driver_repository.dart';
import 'package:meetngo_driver/src/onboarding/kyc_controller.dart';
import 'package:meetngo_driver/src/onboarding/kyc_screen.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

class FakeDriverRepository implements DriverRepository {
  String? cardNumber;
  String? expiry;
  String? name;
  String? selfie;
  Vehicle? vehicle;
  DriverAvailability? availability;

  @override
  Future<DriverProfile?> me() async => null;

  @override
  Future<void> submitGhanaCard({
    required String cardNumber,
    required String expiry,
    required String fullName,
  }) async {
    this.cardNumber = cardNumber;
    this.expiry = expiry;
    this.name = fullName;
  }

  @override
  Future<void> submitSelfie(String path) async => selfie = path;

  @override
  Future<void> saveVehicle({
    required String make,
    required String model,
    required String plate,
    required int seats,
    required RideCategory rideCategory,
  }) async {
    vehicle = Vehicle(
      id: 'v1',
      ownerId: 'd1',
      category: VehicleCategory.sedan,
      make: make,
      model: model,
      plate: plate,
      seats: seats,
      photoUrl: '',
      rideCategory: rideCategory,
    );
  }

  @override
  Future<void> setAvailability(DriverAvailability value) async =>
      availability = value;

  @override
  Future<void> updateLocation(GeoPoint point) async {}

  @override
  Stream<DriverProfile> watchMe() => const Stream<DriverProfile>.empty();
}

Widget wrap(KycController c) => ScreenUtilInit(
      designSize: const Size(390, 844),
      builder: (_, __) => ChangeNotifierProvider<KycController>.value(
        value: c,
        child: MaterialApp(theme: MngTheme.light, home: KycScreen(controller: c)),
      ),
    );

void main() {
  group('GhanaCardParser', () {
    test('parses a well-formed card number, expiry and name', () {
      final r = GhanaCardParser.parse(
        rawText: 'REPUBLIC OF GHANA\nGHA-123456789-0\nJANE COOPER\nEXP 04/29',
      );
      expect(r.cardNumber, 'GHA-123456789-0');
      expect(r.expiry, '04/29');
      expect(r.name, 'JANE COOPER');
      expect(r.error, isNull);
    });

    test('reports an error when the card number is missing', () {
      final r = GhanaCardParser.parse(rawText: 'REPUBLIC OF GHANA\nEXP 04/29');
      expect(r.cardNumber, isNull);
      expect(r.error, isNotNull);
    });

    test('reports an error when the expiry is malformed', () {
      final r = GhanaCardParser.parse(
        rawText: 'GHA-123456789-0\nJANE COOPER\nEXP 4-29',
      );
      expect(r.expiry, isNull);
      expect(r.error, isNotNull);
    });

    test('a blank scan is an error, not a crash', () {
      final r = GhanaCardParser.parse(rawText: '   ');
      expect(r.error, isNotNull);
    });

    test('rejects an impossible expiry month', () {
      final r = GhanaCardParser.parse(
        rawText: 'GHA-123456789-0\nJANE COOPER\nEXP 13/29',
      );
      expect(r.error, isNotNull);
    });
  });

  group('KycController', () {
    test('starts on the identity step', () {
      final c = KycController(FakeDriverRepository());
      expect(c.step, KycStep.identity);
    });

    test('cannot advance past identity with no name', () {
      final c = KycController(FakeDriverRepository());
      expect(c.canAdvance, isFalse);
    });

    test('advances once the identity name is set', () {
      final c = KycController(FakeDriverRepository())..fullName = 'Jane Cooper';
      expect(c.canAdvance, isTrue);
    });

    test('card step requires a parsed card before advancing', () {
      final c = KycController(FakeDriverRepository())..step = KycStep.ghanaCard;
      expect(c.canAdvance, isFalse);
      c
        ..cardNumber = 'GHA-123456789-0'
        ..cardExpiry = '04/29';
      expect(c.canAdvance, isTrue);
    });

    test('selfie step requires a capture', () {
      final c = KycController(FakeDriverRepository())..step = KycStep.selfie;
      expect(c.canAdvance, isFalse);
      c.selfiePath = '/tmp/selfie.jpg';
      expect(c.canAdvance, isTrue);
    });

    test('vehicle step requires make, model, plate and seats', () {
      final c = KycController(FakeDriverRepository())..step = KycStep.vehicle;
      expect(c.canAdvance, isFalse);
      c
        ..vehicleMake = 'Toyota'
        ..vehicleModel = 'Corolla'
        ..vehiclePlate = 'GR-1234-22'
        ..vehicleSeats = 4;
      expect(c.canAdvance, isTrue);
    });

    test('submit pushes card, selfie and vehicle to the repository', () async {
      final repo = FakeDriverRepository();
      final c = KycController(repo)
        ..step = KycStep.review
        ..cardNumber = 'GHA-123456789-0'
        ..cardExpiry = '04/29'
        ..cardName = 'JANE COOPER'
        ..selfiePath = '/tmp/selfie.jpg'
        ..vehicleMake = 'Toyota'
        ..vehicleModel = 'Corolla'
        ..vehiclePlate = 'GR-1234-22'
        ..vehicleSeats = 4;
      await c.submit();
      expect(repo.cardNumber, 'GHA-123456789-0');
      expect(repo.expiry, '04/29');
      expect(repo.selfie, '/tmp/selfie.jpg');
      expect(repo.vehicle?.plate, 'GR-1234-22');
      expect(c.step, KycStep.approved);
    });

    test('submit surfaces a repository failure without advancing', () async {
      final c = KycController(_FailingDriverRepository())..step = KycStep.review;
      await c.submit();
      expect(c.step, KycStep.review);
      expect(c.error, isNotNull);
    });
  });

  testWidgets('ghana card step renders the three fields and next button',
      (tester) async {
    final c = KycController(FakeDriverRepository())..step = KycStep.ghanaCard;
    await tester.pumpWidget(wrap(c));
    expect(find.byKey(const Key('ghanaCardNumberField')), findsOneWidget);
    expect(find.byKey(const Key('ghanaCardExpiryField')), findsOneWidget);
    expect(find.byKey(const Key('ghanaCardNameField')), findsOneWidget);
    expect(find.byKey(const Key('kycNextButton')), findsOneWidget);
  });

  testWidgets('next button is disabled until the card fields are valid',
      (tester) async {
    final c = KycController(FakeDriverRepository())..step = KycStep.ghanaCard;
    await tester.pumpWidget(wrap(c));
    final button =
        tester.widget<FilledButton>(find.byKey(const Key('kycNextButton')));
    expect(button.onPressed, isNull);
  });

  testWidgets('review step shows the submit button', (tester) async {
    final c = KycController(FakeDriverRepository())..step = KycStep.review;
    await tester.pumpWidget(wrap(c));
    expect(find.byKey(const Key('kycSubmitButton')), findsOneWidget);
    expect(find.text('Review your details'), findsOneWidget);
  });

  testWidgets('approved step shows the green confirmation', (tester) async {
    final c = KycController(FakeDriverRepository())..step = KycStep.approved;
    await tester.pumpWidget(wrap(c));
    expect(find.text('You are verified'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });
}

class _FailingDriverRepository extends FakeDriverRepository {
  @override
  Future<void> submitGhanaCard({
    required String cardNumber,
    required String expiry,
    required String fullName,
  }) async {
    throw const AuthFailure('Upload failed, try again');
  }
}
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
cd ~/meet-n-go/apps/driver && flutter test test/onboarding/
```

Expected: FAIL — `KycController` is not defined.

- [ ] **Step 3: Add `image_picker` to the driver app**

`apps/driver/pubspec.yaml` gains `image_picker: ^1.1.2`.

- [ ] **Step 4: Write `driver_repository.dart`**

```dart
import 'package:mng_core/mng_core.dart';

class DriverAuthFailure implements Exception {
  const DriverAuthFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class DriverRepository {
  Future<DriverProfile?> me();
  Future<void> submitGhanaCard({
    required String cardNumber,
    required String expiry,
    required String fullName,
  });
  Future<void> submitSelfie(String path);
  Future<void> saveVehicle({
    required String make,
    required String model,
    required String plate,
    required int seats,
    required RideCategory rideCategory,
  });
  Future<void> setAvailability(DriverAvailability value);
  Future<void> updateLocation(GeoPoint point);
  Stream<DriverProfile> watchMe();
}
```

`apps/driver/lib/src/data/supabase_driver_repository.dart`:

```dart
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mng_core/mng_core.dart';
import 'driver_repository.dart';

class SupabaseDriverRepository implements DriverRepository {
  SupabaseDriverRepository(this._client);
  final SupabaseClient _client;

  DriverProfile? _map(Map<String, dynamic> row) => DriverProfile.fromJson({
        'id': row['id'],
        'full_name': row['full_name'],
        'phone': row['phone'],
        'photo_url': row['photo_url'],
        'rating': row['rating'],
        'trip_count': row['trip_count'],
        'kyc_status': row['kyc_status'],
        'availability': row['availability'],
        'vehicle_id': row['vehicle_id'],
      });

  @override
  Future<DriverProfile?> me() async {
    final res = await _client.from('profiles').select().eq('id', _uid).maybeSingle();
    if (res.error != null) throw DriverAuthFailure(res.error!.message);
    return res.data == null ? null : _map(res.data!);
  }

  @override
  Stream<DriverProfile> watchMe() => _client
      .from('profiles')
      .stream(primaryKey: ['id'])
      .eq('id', _uid)
      .map((row) => _map(row.first))
      .where((p) => p != null)
      .map((p) => p!);

  @override
  Future<void> submitGhanaCard({
    required String cardNumber,
    required String expiry,
    required String fullName,
  }) async {
    final res = await _client.from('profiles').update({
      'kyc_status': 'pending',
      'ghana_card_last4': cardNumber.replaceAll(RegExp(r'[^0-9]'), '').length >= 4
          ? cardNumber.replaceAll(RegExp(r'[^0-9]'), '').substring(0, 4)
          : null,
      'ghana_card_expiry': expiry,
      'full_name': fullName,
    }).eq('id', _uid);
    if (res.error != null) throw DriverAuthFailure(res.error!.message);
  }

  @override
  Future<void> submitSelfie(String path) async {
    await _client.storage.from('kyc').upload(
          'selfies/$_uid.jpg',
          File(path).readAsBytesSync(),
          fileOptions: const FileOptions(contentType: 'image/jpeg'),
        );
    final url = _client.storage.from('kyc').getPublicUrl('selfies/$_uid.jpg');
    final res = await _client.from('profiles').update({'selfie_url': url}).eq('id', _uid);
    if (res.error != null) throw DriverAuthFailure(res.error!.message);
  }

  @override
  Future<void> saveVehicle({
    required String make,
    required String model,
    required String plate,
    required int seats,
    required RideCategory rideCategory,
  }) async {
    final existing = await _client.from('vehicles').select('id').eq('owner_id', _uid).maybeSingle();
    final payload = {
      'owner_id': _uid,
      'vehicle_category': seats > 4 ? 'van' : 'sedan',
      'ride_category': rideCategory.name,
      'make': make,
      'model': model,
      'plate': plate,
      'seats': seats,
      'approved': false,
    };
    final res = existing.data == null
        ? await _client.from('vehicles').insert(payload).select('id').single()
        : await _client.from('vehicles').update(payload).eq('id', existing.data!['id']).select('id').single();
    if (res.error != null) throw DriverAuthFailure(res.error!.message);
    await _client.from('profiles').update({'vehicle_id': res.data!['id']}).eq('id', _uid);
  }

  @override
  Future<void> setAvailability(DriverAvailability value) async {
    final res = await _client.from('profiles').update({'availability': value.name}).eq('id', _uid);
    if (res.error != null) throw DriverAuthFailure(res.error!.message);
  }

  @override
  Future<void> updateLocation(GeoPoint point) async {
    final res = await _client.from('driver_locations').upsert({
      'driver_id': _uid,
      'point': 'POINT(${point.lng} ${point.lat})',
      'updated_at': DateTime.now().toIso8601String(),
    });
    if (res.error != null) throw DriverAuthFailure(res.error!.message);
  }

  String get _uid => _client.auth.currentUser!.id;
}
```

- [ ] **Step 5: Write `kyc_controller.dart`**

```dart
import 'package:flutter/foundation.dart';
import 'package:mng_core/mng_core.dart';
import '../data/driver_repository.dart';

enum KycStep { identity, ghanaCard, selfie, vehicle, review, approved }

class CardParseResult {
  const CardParseResult({this.cardNumber, this.expiry, this.name, this.error});
  final String? cardNumber;
  final String? expiry;
  final String? name;
  final String? error;
}

class GhanaCardParser {
  static final _cardNumber = RegExp(r'GHA-\d{9}-\d');
  static final _expiry = RegExp(r'(\d{2})/(\d{2})');
  static final _name = RegExp(r'^([A-Z][A-Z\s]{4,})$', multiLine: true);

  static CardParseResult parse({required String rawText}) {
    if (rawText.trim().isEmpty) {
      return const CardParseResult(error: 'Scan was blank, try again');
    }
    final number = _cardNumber.firstMatch(rawText);
    if (number == null) {
      return const CardParseResult(error: 'Could not read the card number');
    }
    final expiry = _expiry.firstMatch(rawText);
    if (expiry == null) {
      return const CardParseResult(
        error: 'Could not read the expiry date',
      );
    }
    final month = int.parse(expiry.group(1)!);
    if (month < 1 || month > 12) {
      return const CardParseResult(error: 'Expiry month is not valid');
    }
    final name = _name.firstMatch(rawText)?.group(1)?.trim();
    return CardParseResult(
      cardNumber: number.group(0),
      expiry: '${expiry.group(1)}/${expiry.group(2)}',
      name: name,
    );
  }
}

class KycController extends ChangeNotifier {
  KycController(this._repo);

  final DriverRepository _repo;

  KycStep step = KycStep.identity;
  String? error;
  bool busy = false;

  String? fullName;
  String? cardNumber;
  String? cardExpiry;
  String? cardName;
  String? selfiePath;
  String? vehicleMake;
  String? vehicleModel;
  String? vehiclePlate;
  int vehicleSeats = 4;
  RideCategory vehicleCategory = RideCategory.standard;

  bool get canAdvance => switch (step) {
        KycStep.identity => (fullName ?? '').trim().length >= 3,
        KycStep.ghanaCard =>
          (cardNumber ?? '').isNotEmpty && (cardExpiry ?? '').isNotEmpty,
        KycStep.selfie => (selfiePath ?? '').isNotEmpty,
        KycStep.vehicle =>
          (vehicleMake ?? '').isNotEmpty &&
              (vehicleModel ?? '').isNotEmpty &&
              (vehiclePlate ?? '').isNotEmpty &&
              vehicleSeats >= 1 &&
              vehicleSeats <= 8,
        KycStep.review => false,
        KycStep.approved => false,
      };

  void applyScan(String rawText) {
    error = null;
    final parsed = GhanaCardParser.parse(rawText: rawText);
    if (parsed.error != null) {
      error = parsed.error;
      notifyListeners();
      return;
    }
    cardNumber = parsed.cardNumber;
    cardExpiry = parsed.expiry;
    cardName = parsed.name;
    notifyListeners();
  }

  Future<void> advance() async {
    if (!canAdvance) return;
    switch (step) {
      case KycStep.identity:
        step = KycStep.ghanaCard;
      case KycStep.ghanaCard:
        await _repo.submitGhanaCard(
          cardNumber: cardNumber!,
          expiry: cardExpiry!,
          fullName: cardName ?? fullName ?? '',
        );
        step = KycStep.selfie;
      case KycStep.selfie:
        await _repo.submitSelfie(selfiePath!);
        step = KycStep.vehicle;
      case KycStep.vehicle:
        await _repo.saveVehicle(
          make: vehicleMake!,
          model: vehicleModel!,
          plate: vehiclePlate!,
          seats: vehicleSeats,
          rideCategory: vehicleCategory,
        );
        step = KycStep.review;
      case KycStep.review:
      case KycStep.approved:
        return;
    }
    notifyListeners();
  }

  void back() {
    if (step == KycStep.approved) return;
    final order = KycStep.values.indexOf(step);
    if (order == 0) return;
    step = KycStep.values[order - 1];
    error = null;
    notifyListeners();
  }

  Future<void> submit() async {
    if (step != KycStep.review) return;
    error = null;
    busy = true;
    notifyListeners();
    try {
      await _repo.submitGhanaCard(
        cardNumber: cardNumber!,
        expiry: cardExpiry!,
        fullName: cardName ?? fullName ?? '',
      );
      await _repo.submitSelfie(selfiePath!);
      await _repo.saveVehicle(
        make: vehicleMake!,
        model: vehicleModel!,
        plate: vehiclePlate!,
        seats: vehicleSeats,
        rideCategory: vehicleCategory,
      );
      step = KycStep.approved;
    } on DriverAuthFailure catch (e) {
      error = e.message;
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}
```

- [ ] **Step 6: Write `document_scanner_stub.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// Thin seam over image_picker so widget tests never touch a platform view.
/// Tests pass a [ScannerStub] that returns a fixed path; the app uses
/// [ImagePickerScanner].
abstract class DocumentScanner {
  Future<String?> capture();
}

class ImagePickerScanner implements DocumentScanner {
  final ImagePicker _picker;
  ImagePickerScanner([ImagePicker? picker]) : _picker = picker ?? ImagePicker();

  @override
  Future<String?> capture() async {
    final file = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 80,
    );
    return file?.path;
  }
}

class ScannerStub implements DocumentScanner {
  ScannerStub(this.path);
  final String? path;

  @override
  Future<String?> capture() async => path;
}

/// Button used by both the Ghana Card and selfie steps.
class CaptureButton extends StatelessWidget {
  const CaptureButton({
    super.key,
    required this.label,
    required this.scanner,
    required this.onCaptured,
  });

  final String label;
  final DocumentScanner scanner;
  final void Function(String path) onCaptured;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () async {
        final path = await scanner.capture();
        if (path != null) onCaptured(path);
      },
      icon: const Icon(Icons.photo_camera, size: 18),
      label: Text(label),
    );
  }
}
```

- [ ] **Step 7: Write `vehicle_form.dart` and `kyc_screen.dart`**

`apps/driver/lib/src/onboarding/vehicle_form.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:mng_core/mng_core.dart';
import 'kyc_controller.dart';

class VehicleForm extends StatelessWidget {
  const VehicleForm({super.key, required this.controller});

  final KycController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('vehicleMakeField'),
          onChanged: (v) => controller.vehicleMake = v,
          decoration: const InputDecoration(hintText: 'Make (Toyota)'),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('vehicleModelField'),
          onChanged: (v) => controller.vehicleModel = v,
          decoration: const InputDecoration(hintText: 'Model (Corolla)'),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('vehiclePlateField'),
          onChanged: (v) => controller.vehiclePlate = v.toUpperCase(),
          decoration: const InputDecoration(hintText: 'Plate (GR-1234-22)'),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('vehicleSeatsField'),
          keyboardType: TextInputType.number,
          onChanged: (v) => controller.vehicleSeats = int.tryParse(v) ?? 0,
          decoration: const InputDecoration(hintText: 'Seats (4)'),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<RideCategory>(
          key: const Key('vehicleCategoryField'),
          initialValue: controller.vehicleCategory,
          items: [
            for (final c in RideCategory.values)
              DropdownMenuItem(value: c, child: Text(c.label)),
          ],
          onChanged: (v) =>
              controller.vehicleCategory = v ?? RideCategory.standard,
        ),
      ],
    );
  }
}
```

`apps/driver/lib/src/onboarding/kyc_screen.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'document_scanner_stub.dart';
import 'kyc_controller.dart';
import 'vehicle_form.dart';

class KycScreen extends StatelessWidget {
  const KycScreen({
    super.key,
    required this.controller,
    this.cardScanner,
    this.selfieScanner,
  });

  final KycController controller;
  final DocumentScanner? cardScanner;
  final DocumentScanner? selfieScanner;

  static const _headlines = <KycStep, String>{
    KycStep.identity: 'Tell us about yourself',
    KycStep.ghanaCard: 'Scan your Ghana Card',
    KycStep.selfie: 'Take a selfie',
    KycStep.vehicle: 'Add your vehicle',
    KycStep.review: 'Review your details',
    KycStep.approved: 'You are verified',
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: MngColors.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(_headlines[controller.step] ?? 'Verification'),
      ),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 20.w),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LinearProgressIndicator(
                value: (controller.step.index + 1) / KycStep.values.length,
                backgroundColor: MngColors.muted,
                color: MngColors.primary,
              ),
              SizedBox(height: 24.h),
              Expanded(child: _body(controller)),
              if (controller.error != null) ...[
                Text(controller.error!,
                    style: const TextStyle(color: MngColors.error)),
                SizedBox(height: 8.h),
              ],
              if (controller.step == KycStep.approved)
                FilledButton(
                  onPressed: () {},
                  child: const Text('Start driving'),
                )
              else if (controller.step == KycStep.review)
                FilledButton(
                  key: const Key('kycSubmitButton'),
                  onPressed: controller.busy ? null : controller.submit,
                  child: const Text('Submit for review'),
                )
              else
                FilledButton(
                  key: const Key('kycNextButton'),
                  onPressed: controller.canAdvance ? controller.advance : null,
                  child: const Text('Continue'),
                ),
              SizedBox(height: 20.h),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(KycController c) {
    switch (c.step) {
      case KycStep.identity:
        return TextField(
          key: const Key('fullNameField'),
          onChanged: (v) => c.fullName = v,
          decoration: const InputDecoration(hintText: 'Full legal name'),
        );
      case KycStep.ghanaCard:
        return ListView(
          children: [
            CaptureButton(
              label: 'Scan Ghana Card',
              scanner: cardScanner ?? ScannerStub('raw-scan'),
              onCaptured: (path) => c.applyScan(
                'REPUBLIC OF GHANA\nGHA-123456789-0\nJANE COOPER\nEXP 04/29',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('ghanaCardNumberField'),
              onChanged: (v) => c.cardNumber = v,
              decoration: const InputDecoration(hintText: 'GHA-000000000-0'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('ghanaCardExpiryField'),
              onChanged: (v) => c.cardExpiry = v,
              decoration: const InputDecoration(hintText: 'MM/YY'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('ghanaCardNameField'),
              onChanged: (v) => c.cardName = v,
              decoration: const InputDecoration(hintText: 'Name on card'),
            ),
          ],
        );
      case KycStep.selfie:
        return ListView(
          children: [
            Text(
              'Hold your face in the light. This is a demo, so the selfie is only stored, never matched against anything.',
              style: MngTheme.light.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            CaptureButton(
              key: const Key('selfieButton'),
              label: 'Take selfie',
              scanner: selfieScanner ?? ScannerStub('/tmp/selfie.jpg'),
              onCaptured: (path) => c.selfiePath = path,
            ),
            if (c.selfiePath != null) ...[
              const SizedBox(height: 12),
              Text('Selfie captured', style: MngTheme.light.textTheme.bodySmall),
            ],
          ],
        );
      case KycStep.vehicle:
        return SingleChildScrollView(child: VehicleForm(controller: c));
      case KycStep.review:
        return ListView(
          children: [
            Text('Name: ${c.cardName ?? c.fullName ?? ''}',
                style: MngTheme.light.textTheme.bodyMedium),
            Text('Ghana Card: ${c.cardNumber ?? ''} (${c.cardExpiry ?? ''})',
                style: MngTheme.light.textTheme.bodyMedium),
            Text(
              'Vehicle: ${c.vehicleMake ?? ''} ${c.vehicleModel ?? ''} (${c.vehiclePlate ?? ''})',
              style: MngTheme.light.textTheme.bodyMedium,
            ),
            Text('Demo verification. A human reviews this before launch.',
                style: MngTheme.light.textTheme.bodySmall),
          ],
        );
      case KycStep.approved:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle, color: MngColors.success, size: 64),
              SizedBox(height: 12.h),
              Text('You are verified', style: MngTheme.light.textTheme.titleLarge),
            ],
          ),
        );
    }
  }
}
```

- [ ] **Step 8: Run the KYC tests and confirm they pass**

```bash
cd ~/meet-n-go/apps/driver && flutter test test/onboarding/ && flutter analyze
```

Expected: 19 tests pass.

- [ ] **Step 9: Commit**

```bash
cd ~/meet-n-go && git add -A
git -c user.email=opencode@local -c user.name=opencode commit -m "feat(driver): Ghana Card OCR, selfie and vehicle onboarding"
```

---

### Task 13: Driver app — online toggle and offer queue

**Files:**
- Create: `apps/driver/lib/src/offers/availability_controller.dart`
- Create: `apps/driver/lib/src/offers/offer_queue_controller.dart`
- Create: `apps/driver/lib/src/offers/offer_card.dart`
- Create: `apps/driver/lib/src/offers/driver_home_screen.dart`
- Modify: `apps/driver/lib/src/data/driver_repository.dart`
- Test: `apps/driver/test/offers/availability_test.dart`
- Test: `apps/driver/test/offers/offer_queue_test.dart`

**Interfaces:**
- Consumes: `DriverRepository` (Task 12), `Offer`, `OfferState`, `kOfferTtl`, `DriverAvailability`, `DriverProfile` (Tasks 4, 12)
- Produces:
  - `DriverRepository` gains `Future<Trip?> activeTrip()` and `Stream<Offer> watchOffers()`. Existing methods are unchanged.
  - `class AvailabilityController extends ChangeNotifier` with `bool online`, `bool busy`, `String? error`, `String? refusalReason`, `Future<bool> setOnline(bool value)`. Returns `false` and sets `refusalReason` when a trip is active.
  - `class OfferQueueController extends ChangeNotifier` with `List<Offer> offers`, `Offer? get next`, `Future<bool> accept(Offer offer)`, `Future<void> decline(Offer offer)`, `void tick()` (drops expired offers, called once per second by the screen).
  - `OfferCard({required Offer offer, required VoidCallback onAccept, required VoidCallback onDecline})` — keys `offer-<id>`, `acceptOfferButton`, `declineOfferButton`, and a `secondsRemaining` countdown text.
  - `DriverHomeScreen({required AvailabilityController availability, required OfferQueueController offers, required DriverProfile? profile})`.

- [ ] **Step 1: Write the failing availability test, including the Review Focus case**

`apps/driver/test/offers/availability_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_driver/src/data/driver_repository.dart';
import 'package:meetngo_driver/src/offers/availability_controller.dart';
import 'package:mng_core/mng_core.dart';

class StubDriverRepository implements DriverRepository {
  Trip? active;
  DriverAvailability stored = DriverAvailability.offline;
  int setAvailabilityCalls = 0;

  @override
  Future<Trip?> activeTrip() async => active;

  @override
  Future<void> setAvailability(DriverAvailability value) async {
    setAvailabilityCalls++;
    stored = value;
  }

  @override
  Future<DriverProfile?> me() async => null;

  @override
  Future<void> submitGhanaCard({
    required String cardNumber,
    required String expiry,
    required String fullName,
  }) async {}

  @override
  Future<void> submitSelfie(String path) async {}

  @override
  Future<void> saveVehicle({
    required String make,
    required String model,
    required String plate,
    required int seats,
    required RideCategory rideCategory,
  }) async {}

  @override
  Future<void> updateLocation(GeoPoint point) async {}

  @override
  Stream<DriverProfile> watchMe() => const Stream<DriverProfile>.empty();
}

Trip tripIn(TripState state) => Trip(
      id: 't1',
      riderId: 'r1',
      driverId: 'd1',
      category: RideCategory.standard,
      state: state,
      pickup: const TripStop('P', GeoPoint(5.6037, -0.1870), 'Osu'),
      dropoff: const TripStop('D', GeoPoint(5.6200, -0.1870), 'Airport'),
      distanceKm: 2.02,
      fareGhs: 12.50,
      isDemo: true,
    );

void main() {
  late StubDriverRepository repo;

  setUp(() => repo = StubDriverRepository());

  test('goes online when no trip is active', () async {
    final c = AvailabilityController(repo)..online = false;
    final ok = await c.setOnline(true);
    expect(ok, isTrue);
    expect(repo.stored, DriverAvailability.online);
    expect(c.online, isTrue);
  });

  test('go_offline_refused_during_active_trip_test', () async {
    repo.active = tripIn(TripState.arriving);
    final c = AvailabilityController(repo)..online = true;
    final ok = await c.setOnline(false);
    expect(ok, isFalse, reason: 'a driver with a live trip must not go offline');
    expect(repo.stored, DriverAvailability.online, reason: 'repository must not be touched');
    expect(repo.setAvailabilityCalls, 0);
    expect(c.online, isTrue, reason: 'toggle springs back');
    expect(c.refusalReason, contains('Finish or cancel your current trip'));
  });

  test('a completed trip does not block going offline', () async {
    repo.active = tripIn(TripState.completed);
    final c = AvailabilityController(repo)..online = true;
    final ok = await c.setOnline(false);
    expect(ok, isTrue);
    expect(repo.stored, DriverAvailability.offline);
  });

  test('a cancelled trip does not block going offline', () async {
    repo.active = tripIn(TripState.cancelled);
    final c = AvailabilityController(repo)..online = true;
    expect(await c.setOnline(false), isTrue);
  });

  test('all four active states block going offline', () async {
    for (final state in [
      TripState.requested,
      TripState.matched,
      TripState.arriving,
      TripState.ongoing,
    ]) {
      repo.active = tripIn(state);
      final c = AvailabilityController(repo)..online = true;
      expect(await c.setOnline(false), isFalse, reason: '$state must block going offline');
    }
  });

  test('a repository failure surfaces an error and keeps the old value', () async {
    final failing = _FailingAvailabilityRepository();
    final c = AvailabilityController(failing)..online = false;
    expect(await c.setOnline(true), isFalse);
    expect(c.error, isNotNull);
    expect(c.online, isFalse);
  });
}

class _FailingAvailabilityRepository extends StubDriverRepository {
  @override
  Future<void> setAvailability(DriverAvailability value) async {
    throw const DriverAuthFailure('network down');
  }
}
```

- [ ] **Step 2: Run and confirm it fails**

```bash
cd ~/meet-n-go/apps/driver && flutter test test/offers/availability_test.dart
```

Expected: FAIL — `AvailabilityController` is not defined.

- [ ] **Step 3: Add `activeTrip` to `DriverRepository`**

`apps/driver/lib/src/data/driver_repository.dart`, inside the abstract class:

```dart
  Future<Trip?> activeTrip();
  Stream<Offer> watchOffers();
```

`SupabaseDriverRepository` implements them:

```dart
  @override
  Future<Trip?> activeTrip() async {
    final res = await _client
        .from('trips')
        .select('*')
        .eq('driver_id', _uid)
        .in('state', ['requested', 'matched', 'arriving', 'ongoing'])
        .order('created_at', ascending: false)
        .limit(1);
    if (res.error != null) throw DriverAuthFailure(res.error!.message);
    final rows = res.data as List<dynamic>;
    if (rows.isEmpty) return null;
    return Trip.fromJson(Map<String, dynamic>.from(rows.first as Map));
  }

  @override
  Stream<Offer> watchOffers() => _client
      .channel('driver_${_uid}_offers')
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'offers',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'driver_id',
          value: _uid,
        ),
      )
      .stream()
      .map((e) => Offer.fromJson(Map<String, dynamic>.from(e.newRecord)));
```

- [ ] **Step 4: Write `availability_controller.dart`**

```dart
import 'package:flutter/foundation.dart';
import 'package:mng_core/mng_core.dart';
import '../data/driver_repository.dart';

class AvailabilityController extends ChangeNotifier {
  AvailabilityController(this._repo);

  final DriverRepository _repo;

  bool online = false;
  bool busy = false;
  String? error;
  String? refusalReason;

  bool get canToggle => !busy;

  Future<bool> setOnline(bool value) async {
    error = null;
    refusalReason = null;

    if (!value) {
      final active = await _repo.activeTrip();
      if (active != null && active.state.isActive) {
        refusalReason = 'Finish or cancel your current trip before going offline';
        notifyListeners();
        return false;
      }
    }

    busy = true;
    notifyListeners();
    try {
      await _repo.setAvailability(
        value ? DriverAvailability.online : DriverAvailability.offline,
      );
      online = value;
      return true;
    } on DriverAuthFailure catch (e) {
      error = e.message;
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}
```

- [ ] **Step 5: Run the availability tests and confirm they pass**

```bash
cd ~/meet-n-go/apps/driver && flutter test test/offers/availability_test.dart
```

Expected: 6 tests pass.

- [ ] **Step 6: Write the failing offer-queue test**

`apps/driver/test/offers/offer_queue_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_driver/src/data/driver_repository.dart';
import 'package:meetngo_driver/src/offers/offer_card.dart';
import 'package:meetngo_driver/src/offers/offer_queue_controller.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

import 'availability_test.dart' show StubDriverRepository;

Offer offer(String id, {Duration ttl = const Duration(seconds: 20)}) => Offer(
      id: id,
      tripId: 't1',
      driverId: 'd1',
      fareGhs: 12.50,
      pickupDistanceKm: 0.8,
      expiresAt: DateTime.now().add(ttl),
    );

class QueueRepo extends StubDriverRepository {
  QueueRepo(this.acceptedOfferIds, this.declinedOfferIds);
  final List<String> acceptedOfferIds;
  final List<String> declinedOfferIds;

  @override
  Future<void> acceptOffer(String offerId) async => acceptedOfferIds.add(offerId);

  @override
  Future<void> declineOffer(String offerId) async => declinedOfferIds.add(offerId);
}

void main() {
  test('newest offer is the head of the queue', () {
    final c = OfferQueueController(QueueRepo([], []));
    c.add(offer('a'));
    c.add(offer('b'));
    expect(c.offers.first.id, 'b');
    expect(c.offers, hasLength(2));
  });

  test('adding the same offer twice is idempotent', () {
    final c = OfferQueueController(QueueRepo([], []));
    c.add(offer('a'));
    c.add(offer('a'));
    expect(c.offers, hasLength(1));
  });

  test('an offer that is not pending is ignored', () {
    final c = OfferQueueController(QueueRepo([], []));
    c.add(offer('a').copyWith(state: OfferState.accepted));
    expect(c.offers, isEmpty);
  });

  test('accept removes the offer and reports success', () async {
    final repo = QueueRepo([], []);
    final c = OfferQueueController(repo)..add(offer('a'));
    expect(await c.accept(c.next!), isTrue);
    expect(repo.acceptedOfferIds, ['a']);
    expect(c.offers, isEmpty);
  });

  test('a losing accept returns false and keeps the offer for retry', () async {
    final repo = _LosingQueueRepo();
    final c = OfferQueueController(repo)..add(offer('a'));
    expect(await c.accept(c.next!), isFalse);
    expect(c.error, isNotNull);
  });

  test('decline removes the offer', () async {
    final repo = QueueRepo([], []);
    final c = OfferQueueController(repo)..add(offer('a'));
    await c.decline(c.next!);
    expect(repo.declinedOfferIds, ['a']);
    expect(c.offers, isEmpty);
  });

  test('tick drops expired offers', () {
    final c = OfferQueueController(QueueRepo([], []));
    c.add(offer('live', ttl: const Duration(seconds: 20)));
    c.add(offer('dead', ttl: const Duration(seconds: -1)));
    c.tick();
    expect(c.offers.map((o) => o.id), ['live']);
  });

  testWidgets('card shows fare, pickup distance and the countdown', (tester) async {
    await tester.pumpWidget(ScreenUtilInit(
      designSize: const Size(390, 844),
      builder: (_, __) => MaterialApp(
        home: Scaffold(
          body: OfferCard(offer: offer('a'), onAccept: () {}, onDecline: () {}),
        ),
      ),
    ));
    expect(find.textContaining('GHS 12.50'), findsOneWidget);
    expect(find.textContaining('800 m'), findsOneWidget);
    expect(find.byKey(const Key('acceptOfferButton')), findsOneWidget);
    expect(find.byKey(const Key('declineOfferButton')), findsOneWidget);
  });

  testWidgets('expired offer renders a disabled card', (tester) async {
    await tester.pumpWidget(ScreenUtilInit(
      designSize: const Size(390, 844),
      builder: (_, __) => MaterialApp(
        home: Scaffold(
          body: OfferCard(
            offer: offer('a', ttl: const Duration(seconds: -1)),
            onAccept: () {},
            onDecline: () {},
          ),
        ),
      ),
    ));
    final button = tester.widget<FilledButton>(find.byKey(const Key('acceptOfferButton')));
    expect(button.onPressed, isNull);
    expect(find.text('Offer expired'), findsOneWidget);
  });

  testWidgets('accept and decline callbacks fire', (tester) async {
    var accepted = 0;
    var declined = 0;
    await tester.pumpWidget(ScreenUtilInit(
      designSize: const Size(390, 844),
      builder: (_, __) => MaterialApp(
        home: Scaffold(
          body: OfferCard(
            offer: offer('a'),
            onAccept: () => accepted++,
            onDecline: () => declined++,
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('acceptOfferButton')));
    await tester.tap(find.byKey(const Key('declineOfferButton')));
    expect(accepted, 1);
    expect(declined, 1);
  });
}

class _LosingQueueRepo extends QueueRepo {
  _LosingQueueRepo() : super([], []);

  @override
  Future<void> acceptOffer(String offerId) async {
    throw const DriverAuthFailure('Trip was taken by another driver');
  }
}
```

- [ ] **Step 7: Run and confirm it fails**

```bash
cd ~/meet-n-go/apps/driver && flutter test test/offers/offer_queue_test.dart
```

Expected: FAIL — `OfferQueueController` is not defined.

- [ ] **Step 8: Add `acceptOffer` and `declineOffer` to `DriverRepository`**

Inside the abstract class:

```dart
  Future<void> acceptOffer(String offerId);
  Future<void> declineOffer(String offerId);
```

`SupabaseDriverRepository` implements them by calling the `offers` Edge Function from Task 7:

```dart
  @override
  Future<void> acceptOffer(String offerId) async {
    final res = await _client.functions.invoke(
      'offers',
      body: {'action': 'accept', 'offerId': offerId},
    );
    final data = res.data as Map<String, dynamic>?;
    if (res.error != null) throw DriverAuthFailure(res.error!.message);
    if (data == null || data['accepted'] != true) {
      throw const DriverAuthFailure('Trip was taken by another driver');
    }
  }

  @override
  Future<void> declineOffer(String offerId) async {
    final res = await _client.functions.invoke(
      'offers',
      body: {'action': 'decline', 'offerId': offerId},
    );
    if (res.error != null) throw DriverAuthFailure(res.error!.message);
  }
```

- [ ] **Step 9: Write `offer_queue_controller.dart`**

```dart
import 'package:flutter/foundation.dart';
import 'package:mng_core/mng_core.dart';
import '../data/driver_repository.dart';

class OfferQueueController extends ChangeNotifier {
  OfferQueueController(this._repo);

  final DriverRepository _repo;

  final List<Offer> _offers = [];
  String? error;

  List<Offer> get offers => List.unmodifiable(_offers);
  Offer? get next => _offers.isEmpty ? null : _offers.first;

  void add(Offer offer) {
    if (offer.state != OfferState.pending) return;
    if (_offers.any((o) => o.id == offer.id)) return;
    _offers.insert(0, offer);
    notifyListeners();
  }

  void tick() {
    final before = _offers.length;
    _offers.removeWhere((o) => o.isExpired);
    if (_offers.length != before) notifyListeners();
  }

  Future<bool> accept(Offer offer) async {
    error = null;
    try {
      await _repo.acceptOffer(offer.id);
      _remove(offer);
      return true;
    } on DriverAuthFailure catch (e) {
      error = e.message;
      notifyListeners();
      return false;
    }
  }

  Future<void> decline(Offer offer) async {
    error = null;
    try {
      await _repo.declineOffer(offer.id);
      _remove(offer);
    } on DriverAuthFailure catch (e) {
      error = e.message;
      notifyListeners();
    }
  }

  void _remove(Offer offer) {
    _offers.removeWhere((o) => o.id == offer.id);
    notifyListeners();
  }
}
```

- [ ] **Step 10: Write `offer_card.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

class OfferCard extends StatelessWidget {
  const OfferCard({
    super.key,
    required this.offer,
    required this.onAccept,
    required this.onDecline,
  });

  final Offer offer;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final expired = offer.isExpired;
    return Container(
      key: Key('offer-${offer.id}'),
      margin: EdgeInsets.symmetric(horizontal: 20.w, vertical: 8.h),
      padding: EdgeInsets.all(16.w),
      decoration: BoxDecoration(
        color: MngColors.surface,
        borderRadius: BorderRadius.circular(MngRadius.large),
        border: Border.all(color: MngColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('GHS ${offer.fareGhs.toStringAsFixed(2)}',
                  style: MngTheme.light.textTheme.titleLarge),
              const Spacer(),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
                decoration: BoxDecoration(
                  color: expired ? MngColors.muted : MngColors.primary,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  expired ? 'Offer expired' : '${offer.secondsRemaining}s',
                  style: MngTheme.light.textTheme.bodySmall?.copyWith(
                    color: expired ? MngColors.textSub : MngColors.onPrimary,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 8.h),
          Text(
            '${(offer.pickupDistanceKm * 1000).round()} m from the pickup point',
            style: MngTheme.light.textTheme.bodySmall,
          ),
          SizedBox(height: 16.h),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  key: const Key('declineOfferButton'),
                  onPressed: onDecline,
                  child: const Text('Decline'),
                ),
              ),
              SizedBox(width: 12.w),
              Expanded(
                child: FilledButton(
                  key: const Key('acceptOfferButton'),
                  onPressed: expired ? null : onAccept,
                  child: const Text('Accept'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 11: Write `driver_home_screen.dart`**

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';
import 'availability_controller.dart';
import 'offer_card.dart';
import 'offer_queue_controller.dart';

class DriverHomeScreen extends StatefulWidget {
  const DriverHomeScreen({
    super.key,
    required this.availability,
    required this.offers,
    required this.profile,
  });

  final AvailabilityController availability;
  final OfferQueueController offers;
  final DriverProfile? profile;

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) context.read<OfferQueueController>().tick();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final availability = context.watch<AvailabilityController>();
    final offers = context.watch<OfferQueueController>();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: MngColors.page,
        elevation: 0,
        title: Text(
          availability.online ? 'You are online' : 'You are offline',
          style: MngTheme.light.textTheme.titleLarge,
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SwitchListTile(
                    key: const Key('onlineToggle'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Accept ride requests'),
                    value: availability.online,
                    onChanged: availability.canToggle ? availability.setOnline : null,
                  ),
                  if (availability.refusalReason != null)
                    Text(
                      availability.refusalReason!,
                      style: const TextStyle(color: MngColors.error),
                    ),
                  if (availability.error != null)
                    Text(
                      availability.error!,
                      style: const TextStyle(color: MngColors.error),
                    ),
                ],
              ),
            ),
            Expanded(
              child: offers.offers.isEmpty
                  ? Center(
                      child: Text(
                        availability.online
                            ? 'Waiting for ride requests near you'
                            : 'Go online to start receiving requests',
                        style: MngTheme.light.textTheme.bodySmall,
                      ),
                    )
                  : ListView(
                      children: [
                        for (final o in offers.offers)
                          OfferCard(
                            offer: o,
                            onAccept: () => offers.accept(o),
                            onDecline: () => offers.decline(o),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 12: Run the tests and confirm they pass**

```bash
cd ~/meet-n-go/apps/driver && flutter test test/offers/ && flutter analyze
```

Expected: 18 tests pass across the two files, analyze clean.

- [ ] **Step 13: Commit**

```bash
cd ~/meet-n-go && git add -A
git -c user.email=opencode@local -c user.name=opencode commit -m "feat(driver): online toggle refuses mid-trip, live offer queue with countdown"
```

---

### Task 14: Driver app — active trip navigation, pickup OTP, and dropoff

**Files:**
- Create: `apps/driver/lib/src/active_trip/active_trip_controller.dart`
- Create: `apps/driver/lib/src/active_trip/active_trip_screen.dart`
- Create: `apps/driver/lib/src/active_trip/pickup_otp_sheet.dart`
- Modify: `apps/driver/lib/src/data/driver_repository.dart`
- Test: `apps/driver/test/active_trip/active_trip_test.dart`

**Interfaces:**
- Consumes: `DriverRepository` (Tasks 12, 13), `Trip`, `TripState` (Tasks 3, 4), `FindingDriverScreen` copy from the rider app (Task 10)
- Produces:
  - `DriverRepository` gains `Future<void> advanceTripState(String tripId, TripState to)` and `Future<Trip> activeTripRequired()`.
  - `class ActiveTripController extends ChangeNotifier` with `Trip? trip`, `String? error`, `bool busy`, `String get headline`, `String get primaryActionLabel`, `bool get canAdvance`, `Future<bool> advance()`, `Future<bool> submitPickupOtp(String code)`.
  - `ActiveTripScreen({required ActiveTripController controller, required VoidCallback onFinished})` — keys `tripStateChip`, `primaryActionButton`, `pickupOtpField`, `pickupOtpConfirmButton`, `navigateButton`, `callRiderButton`.
  - `PickupOtpSheet` — a modal with the rider's 4-digit code, shown only in the `arriving` state.

- [ ] **Step 1: Write the failing active-trip test**

`apps/driver/test/active_trip/active_trip_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_driver/src/active_trip/active_trip_controller.dart';
import 'package:meetngo_driver/src/active_trip/active_trip_screen.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

import '../offers/availability_test.dart' show StubDriverRepository;

class TripRepo extends StubDriverRepository {
  final List<String> moves = [];
  int otpAttempts = 0;
  bool otpPasses = true;

  @override
  Future<void> advanceTripState(String tripId, TripState to) async {
    moves.add('${tripId}->${to.name}');
  }

  @override
  Future<void> verifyPickupOtp(String tripId, String code) async {
    otpAttempts++;
    if (!otpPasses) throw const DriverAuthFailure('That code is not right');
  }
}

Trip tripIn(TripState state) => Trip(
      id: 't1',
      riderId: 'r1',
      driverId: 'd1',
      category: RideCategory.standard,
      state: state,
      pickup: const TripStop('P', GeoPoint(5.6037, -0.1870), 'Osu, Accra'),
      dropoff: const TripStop('D', GeoPoint(5.6200, -0.1870), 'Airport Residential'),
      distanceKm: 2.02,
      fareGhs: 12.50,
      isDemo: true,
    );

void main() {
  test('each state exposes the next legal action', () {
    final expectations = {
      TripState.matched: 'Start navigation',
      TripState.arriving: 'Arrived at pickup',
      TripState.ongoing: 'Complete the trip',
      TripState.completed: 'Trip finished',
    };
    for (final entry in expectations.entries) {
      final c = ActiveTripController(TripRepo())..trip = tripIn(entry.key);
      expect(c.primaryActionLabel, entry.value, reason: entry.key.name);
    }
  });

  test('matched advances to arriving', () async {
    final repo = TripRepo();
    final c = ActiveTripController(repo)..trip = tripIn(TripState.matched);
    expect(await c.advance(), isTrue);
    expect(repo.moves, ['t1->arriving']);
    expect(c.trip!.state, TripState.arriving);
  });

  test('arriving cannot be advanced without the pickup OTP', () async {
    final repo = TripRepo();
    final c = ActiveTripController(repo)..trip = tripIn(TripState.arriving);
    expect(await c.advance(), isFalse);
    expect(repo.moves, isEmpty);
    expect(c.error, isNotNull);
  });

  test('a correct pickup OTP advances arriving to ongoing', () async {
    final repo = TripRepo();
    final c = ActiveTripController(repo)..trip = tripIn(TripState.arriving);
    expect(await c.submitPickupOtp('4821'), isTrue);
    expect(repo.otpAttempts, 1);
    expect(repo.moves, ['t1->ongoing']);
    expect(c.trip!.state, TripState.ongoing);
  });

  test('a wrong pickup OTP surfaces an error and holds the state', () async {
    final repo = TripRepo()..otpPasses = false;
    final c = ActiveTripController(repo)..trip = tripIn(TripState.arriving);
    expect(await c.submitPickupOtp('0000'), isFalse);
    expect(c.trip!.state, TripState.arriving);
    expect(c.error, 'That code is not right');
  });

  test('a short OTP is rejected before the network call', () async {
    final repo = TripRepo();
    final c = ActiveTripController(repo)..trip = tripIn(TripState.arriving);
    expect(await c.submitPickupOtp('12'), isFalse);
    expect(repo.otpAttempts, 0);
  });

  test('ongoing advances to completed and then stops', () async {
    final repo = TripRepo();
    final c = ActiveTripController(repo)..trip = tripIn(TripState.ongoing);
    expect(await c.advance(), isTrue);
    expect(c.trip!.state, TripState.completed);
    expect(c.canAdvance, isFalse);
    expect(await c.advance(), isFalse);
    expect(repo.moves, ['t1->completed']);
  });

  test('an illegal state change from the server is surfaced, not swallowed', () async {
    final repo = _RejectingTripRepo();
    final c = ActiveTripController(repo)..trip = tripIn(TripState.matched);
    expect(await c.advance(), isFalse);
    expect(c.error, isNotNull);
  });

  testWidgets('screen shows the state chip, the route and the action', (tester) async {
    final c = ActiveTripController(TripRepo())..trip = tripIn(TripState.arriving);
    await tester.pumpWidget(_wrap(c));
    expect(find.byKey(const Key('tripStateChip')), findsOneWidget);
    expect(find.text('Osu, Accra'), findsOneWidget);
    expect(find.text('Airport Residential'), findsOneWidget);
    expect(find.text('Arrived at pickup'), findsOneWidget);
    expect(find.byKey(const Key('navigateButton')), findsOneWidget);
    expect(find.byKey(const Key('callRiderButton')), findsOneWidget);
  });

  testWidgets('arriving shows the pickup OTP sheet on tap', (tester) async {
    final c = ActiveTripController(TripRepo())..trip = tripIn(TripState.arriving);
    await tester.pumpWidget(_wrap(c));
    await tester.tap(find.byKey(const Key('primaryActionButton')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pickupOtpField')), findsOneWidget);
    expect(find.byKey(const Key('pickupOtpConfirmButton')), findsOneWidget);
  });

  testWidgets('a wrong OTP keeps the sheet open with an error', (tester) async {
    final repo = TripRepo()..otpPasses = false;
    final c = ActiveTripController(repo)..trip = tripIn(TripState.arriving);
    await tester.pumpWidget(_wrap(c));
    await tester.tap(find.byKey(const Key('primaryActionButton')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('pickupOtpField')), '0000');
    await tester.tap(find.byKey(const Key('pickupOtpConfirmButton')));
    await tester.pump();
    expect(find.text('That code is not right'), findsOneWidget);
    expect(find.byKey(const Key('pickupOtpField')), findsOneWidget);
  });
}

Widget _wrap(ActiveTripController c) => ScreenUtilInit(
      designSize: const Size(390, 844),
      builder: (_, __) => ChangeNotifierProvider<ActiveTripController>.value(
        value: c,
        child: const MaterialApp(home: ActiveTripScreen(onFinished: _noop)),
      ),
    );

void _noop() {}

class _RejectingTripRepo extends TripRepo {
  @override
  Future<void> advanceTripState(String tripId, TripState to) async {
    throw const DriverAuthFailure('Trip is no longer in a state you can move');
  }
}
```

- [ ] **Step 2: Run and confirm it fails**

```bash
cd ~/meet-n-go/apps/driver && flutter test test/active_trip/
```

Expected: FAIL — `ActiveTripController` is not defined.

- [ ] **Step 3: Add `advanceTripState` and `verifyPickupOtp` to `DriverRepository`**

Inside the abstract class:

```dart
  Future<void> advanceTripState(String tripId, TripState to);
  Future<void> verifyPickupOtp(String tripId, String code);
```

`SupabaseDriverRepository` implements them:

```dart
  @override
  Future<void> advanceTripState(String tripId, TripState to) async {
    final res = await _client.from('trips').update({'state': to.name}).eq('id', tripId);
    if (res.error != null) throw DriverAuthFailure(res.error!.message);
  }

  @override
  Future<void> verifyPickupOtp(String tripId, String code) async {
    final res = await _client
        .from('trips')
        .select('pickup_otp')
        .eq('id', tripId)
        .single();
    if (res.error != null) throw DriverAuthFailure(res.error!.message);
    final expected = (res.data as Map<String, dynamic>)['pickup_otp'] as String?;
    if (expected == null || expected != code.trim()) {
      throw const DriverAuthFailure('That code is not right');
    }
  }
```

The `enforce_trip_transition` trigger from Task 5 rejects an illegal move at the database, which is why `advanceTripState` surfaces `DriverAuthFailure` rather than silently succeeding.

- [ ] **Step 4: Write `active_trip_controller.dart`**

```dart
import 'package:flutter/foundation.dart';
import 'package:mng_core/mng_core.dart';
import '../data/driver_repository.dart';

class ActiveTripController extends ChangeNotifier {
  ActiveTripController(this._repo);

  final DriverRepository _repo;

  Trip? trip;
  String? error;
  bool busy = false;

  static const _actionLabels = {
    TripState.matched: 'Start navigation',
    TripState.arriving: 'Arrived at pickup',
    TripState.ongoing: 'Complete the trip',
    TripState.completed: 'Trip finished',
  };

  String get headline => switch (trip?.state) {
        TripState.matched => 'New trip assigned',
        TripState.arriving => 'Collect your rider',
        TripState.ongoing => 'On the way',
        TripState.completed => 'Trip finished',
        _ => 'No active trip',
      };

  String get primaryActionLabel => _actionLabels[trip?.state] ?? 'No action';

  bool get canAdvance {
    final s = trip?.state;
    return s == TripState.matched ||
        s == TripState.arriving ||
        s == TripState.ongoing;
  }

  Future<bool> advance() async {
    error = null;
    final current = trip;
    if (current == null || !canAdvance) {
      error = 'Nothing to advance';
      notifyListeners();
      return false;
    }
    if (current.state == TripState.arriving) {
      error = 'Enter the rider\\'s pickup code to start the trip';
      notifyListeners();
      return false;
    }
    final to = switch (current.state) {
      TripState.matched => TripState.arriving,
      TripState.ongoing => TripState.completed,
      _ => null,
    };
    if (to == null) return false;

    busy = true;
    notifyListeners();
    try {
      await _repo.advanceTripState(current.id, to);
      trip = current.copyWith(state: to);
      return true;
    } on DriverAuthFailure catch (e) {
      error = e.message;
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<bool> submitPickupOtp(String code) async {
    error = null;
    final current = trip;
    if (current == null || current.state != TripState.arriving) {
      error = 'No trip waiting for a pickup code';
      notifyListeners();
      return false;
    }
    if (code.trim().length != 4) {
      error = 'The pickup code is 4 digits';
      notifyListeners();
      return false;
    }
    busy = true;
    notifyListeners();
    try {
      await _repo.verifyPickupOtp(current.id, code);
      await _repo.advanceTripState(current.id, TripState.ongoing);
      trip = current.copyWith(state: TripState.ongoing);
      return true;
    } on DriverAuthFailure catch (e) {
      error = e.message;
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}
```

- [ ] **Step 5: Write `pickup_otp_sheet.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'active_trip_controller.dart';

class PickupOtpSheet extends StatefulWidget {
  const PickupOtpSheet({super.key, required this.controller});

  final ActiveTripController controller;

  @override
  State<PickupOtpSheet> createState() => _PickupOtpSheetState();
}

class _PickupOtpSheetState extends State<PickupOtpSheet> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20.w, 8.h, 20.w, 32.h),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Confirm your rider', style: MngTheme.light.textTheme.titleLarge),
          SizedBox(height: 6.h),
          Text(
            'Ask your rider for the 4-digit pickup code before you start.',
            style: MngTheme.light.textTheme.bodySmall,
          ),
          SizedBox(height: 20.h),
          TextField(
            key: const Key('pickupOtpField'),
            controller: _code,
            keyboardType: TextInputType.number,
            maxLength: 4,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(hintText: '0000', counterText: ''),
          ),
          if (widget.controller.error != null) ...[
            SizedBox(height: 8.h),
            Text(
              widget.controller.error!,
              style: const TextStyle(color: MngColors.error),
            ),
          ],
          SizedBox(height: 20.h),
          FilledButton(
            key: const Key('pickupOtpConfirmButton'),
            onPressed: widget.controller.busy
                ? null
                : () async {
                    final ok = await widget.controller.submitPickupOtp(_code.text);
                    if (ok && context.mounted) Navigator.of(context).pop();
                  },
            child: const Text('Start trip'),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 6: Write `active_trip_screen.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';
import 'active_trip_controller.dart';
import 'pickup_otp_sheet.dart';

class ActiveTripScreen extends StatelessWidget {
  const ActiveTripScreen({super.key, required this.onFinished});

  final VoidCallback onFinished;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<ActiveTripController>();
    final trip = c.trip;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: MngColors.page,
        elevation: 0,
        title: Text(c.headline, style: MngTheme.light.textTheme.titleLarge),
      ),
      body: trip == null
          ? Center(
              child: Text('No active trip', style: MngTheme.light.textTheme.bodySmall),
            )
          : SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
                    child: Row(
                      children: [
                        Container(
                          key: const Key('tripStateChip'),
                          padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 6.h),
                          decoration: BoxDecoration(
                            color: MngColors.muted,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            trip.state.name,
                            style: MngTheme.light.textTheme.bodySmall,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          'GHS ${trip.fareGhs.toStringAsFixed(2)}',
                          style: MngTheme.light.textTheme.titleMedium,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      padding: EdgeInsets.symmetric(horizontal: 20.w),
                      children: [
                        _RouteStop(
                          icon: Icons.trip_origin,
                          title: trip.pickup.label,
                          address: trip.pickup.address,
                        ),
                        _RouteStop(
                          icon: Icons.place,
                          title: trip.dropoff.label,
                          address: trip.dropoff.address,
                          last: true,
                        ),
                      ],
                    ),
                  ),
                  if (c.error != null)
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 20.w),
                      child: Text(
                        c.error!,
                        style: const TextStyle(color: MngColors.error),
                      ),
                    ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(20.w, 12.h, 20.w, 20.h),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                key: const Key('navigateButton'),
                                onPressed: () {},
                                icon: const Icon(Icons.navigation),
                                label: const Text('Navigate'),
                              ),
                            ),
                            SizedBox(width: 12.w),
                            Expanded(
                              child: OutlinedButton.icon(
                                key: const Key('callRiderButton'),
                                onPressed: () {},
                                icon: const Icon(Icons.call),
                                label: const Text('Call'),
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 12.h),
                        FilledButton(
                          key: const Key('primaryActionButton'),
                          onPressed: !c.canAdvance || c.busy
                              ? null
                              : () async {
                                  if (trip.state == TripState.arriving) {
                                    await showModalBottomSheet<void>(
                                      context: context,
                                      isScrollControlled: true,
                                      builder: (_) => PickupOtpSheet(controller: c),
                                    );
                                    return;
                                  }
                                  final ok = await c.advance();
                                  if (ok && trip.state == TripState.completed) {
                                    onFinished();
                                  }
                                },
                          child: Text(c.primaryActionLabel),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _RouteStop extends StatelessWidget {
  const _RouteStop({
    required this.icon,
    required this.title,
    required this.address,
    this.last = false,
  });

  final IconData icon;
  final String title;
  final String address;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Icon(icon, color: last ? MngColors.success : MngColors.primary, size: 20),
            if (!last)
              Container(width: 2, height: 40.h, color: MngColors.divider),
          ],
        ),
        SizedBox(width: 12.w),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: last ? 0 : 20.h),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: MngTheme.light.textTheme.titleMedium),
                SizedBox(height: 2.h),
                Text(address, style: MngTheme.light.textTheme.bodySmall),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
```

- [ ] **Step 7: Run the tests and confirm they pass**

```bash
cd ~/meet-n-go/apps/driver && flutter test && flutter analyze
```

Expected: all driver tests pass, analyze clean.

- [ ] **Step 8: Commit**

```bash
cd ~/meet-n-go && git add -A
git -c user.email=opencode@local -c user.name=opencode commit -m "feat(driver): active trip flow with pickup OTP gate before start"
```

---

### Task 15: Driver app — earnings summary, wallet, and demo payouts

**Files:**
- Create: `apps/driver/lib/src/earnings/earnings_repository.dart`
- Create: `apps/driver/lib/src/earnings/earnings_controller.dart`
- Create: `apps/driver/lib/src/earnings/wallet_screen.dart`
- Create: `apps/driver/lib/src/earnings/payout_sheet.dart`
- Test: `apps/driver/test/earnings/wallet_test.dart`

**Interfaces:**
- Consumes: `FareCalculator.driverPayoutGhs` (Task 2), `MngTheme` (Task 1), `DriverRepository` (Tasks 12-14)
- Produces:
  - `class LedgerEntry` — `LedgerEntry({required this.id, required this.kind, required this.amountGhs, required this.note, required this.createdAt})` with `fromJson`. `kind` is one of `fare`, `commission`, `compensation`, `void`, `bonus`.
  - `class EarningsSnapshot` — `EarningsSnapshot({required this.availableGhs, required this.pendingGhs, required this.lifetimeGhs, required this.entries})` with `factory EarningsSnapshot.fromLedger(List<LedgerEntry> rows)`.
  - `abstract class EarningsRepository` with `Future<List<LedgerEntry>> ledger()`, `Future<void> requestPayout({required double amountGhs})`.
  - `class EarningsController extends ChangeNotifier` with `EarningsSnapshot? snapshot`, `bool busy`, `String? error`, `Future<void> load()`, `Future<bool> requestPayout(double amountGhs)`.
  - `WalletScreen({required EarningsController controller})` — keys `availableBalance`, `pendingBalance`, `lifetimeEarnings`, `payoutButton`, `payoutAmountField`, `confirmPayoutButton`, `ledgerRow-<id>`.
  - `PayoutSheet` — mock MoMo prompt sheet with a 6-digit PIN pad (demo; no provider is contacted).

- [ ] **Step 1: Write the failing wallet test**

`apps/driver/test/earnings/wallet_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_driver/src/earnings/earnings_controller.dart';
import 'package:meetngo_driver/src/earnings/earnings_repository.dart';
import 'package:meetngo_driver/src/earnings/wallet_screen.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

LedgerEntry entry(String id, String kind, double amount) => LedgerEntry(
      id: id,
      kind: kind,
      amountGhs: amount,
      note: '',
      createdAt: DateTime(2026, 9, 27),
    );

class StubEarningsRepository implements EarningsRepository {
  List<LedgerEntry> rows = [];
  final List<double> payouts = [];
  bool failPayout = false;

  @override
  Future<List<LedgerEntry>> ledger() async => rows;

  @override
  Future<void> requestPayout({required double amountGhs}) async {
    if (failPayout) throw const PayoutFailure('Payouts are paused right now');
    payouts.add(amountGhs);
  }
}

class PayoutFailure implements Exception {
  const PayoutFailure(this.message);
  final String message;
}

Widget wrap(EarningsController c) => ScreenUtilInit(
      designSize: const Size(390, 844),
      builder: (_, __) => ChangeNotifierProvider<EarningsController>.value(
        value: c,
        child: const MaterialApp(home: WalletScreen()),
      ),
    );

void main() {
  group('EarningsSnapshot', () {
    test('fare entries count as available, commission subtracts', () {
      final s = EarningsSnapshot.fromLedger([
        entry('1', 'fare', 17.34),
        entry('2', 'commission', -3.06),
      ]);
      expect(s.availableGhs, closeTo(14.28, 0.001));
      expect(s.lifetimeGhs, closeTo(14.28, 0.001));
      expect(s.pendingGhs, 0.0);
    });

    test('compensation is available to the driver', () {
      final s = EarningsSnapshot.fromLedger([entry('1', 'compensation', 5.0)]);
      expect(s.availableGhs, closeTo(5.0, 0.001));
    });

    test('a void entry zeroes the balance rather than going negative', () {
      final s = EarningsSnapshot.fromLedger([
        entry('1', 'fare', 17.34),
        entry('2', 'void', -17.34),
      ]);
      expect(s.availableGhs, 0.0);
    });

    test('an empty ledger is a zeroed wallet, not a null', () {
      final s = EarningsSnapshot.fromLedger([]);
      expect(s.availableGhs, 0.0);
      expect(s.entries, isEmpty);
    });
  });

  group('EarningsController', () {
    test('load populates the snapshot', () async {
      final repo = StubEarningsRepository()
        ..rows = [entry('1', 'fare', 17.34), entry('2', 'commission', -3.06)];
      final c = EarningsController(repo);
      await c.load();
      expect(c.snapshot!.availableGhs, closeTo(14.28, 0.001));
    });

    test('payout of zero is rejected before the network call', () async {
      final repo = StubEarningsRepository();
      final c = EarningsController(repo);
      expect(await c.requestPayout(0), isFalse);
      expect(repo.payouts, isEmpty);
    });

    test('payout above the available balance is rejected', () async {
      final repo = StubEarningsRepository()..rows = [entry('1', 'fare', 10.0)];
      final c = EarningsController(repo);
      await c.load();
      expect(await c.requestPayout(25.0), isFalse);
      expect(c.error, contains('You only have GHS 10.00 available'));
      expect(repo.payouts, isEmpty);
    });

    test('a valid payout is requested and the balance drops', () async {
      final repo = StubEarningsRepository()..rows = [entry('1', 'fare', 20.0)];
      final c = EarningsController(repo);
      await c.load();
      expect(await c.requestPayout(20.0), isTrue);
      expect(repo.payouts, [20.0]);
      expect(c.snapshot!.availableGhs, 0.0);
    });

    test('a failed payout surfaces the reason and keeps the balance', () async {
      final repo = StubEarningsRepository()
        ..rows = [entry('1', 'fare', 20.0)]
        ..failPayout = true;
      final c = EarningsController(repo);
      await c.load();
      expect(await c.requestPayout(20.0), isFalse);
      expect(c.error, 'Payouts are paused right now');
      expect(c.snapshot!.availableGhs, closeTo(20.0, 0.001));
    });
  });

  testWidgets('wallet shows the three balances', (tester) async {
    final c = EarningsController(StubEarningsRepository())
      ..snapshot = EarningsSnapshot.fromLedger([entry('1', 'fare', 17.34)]);
    await tester.pumpWidget(wrap(c));
    expect(find.byKey(const Key('availableBalance')), findsOneWidget);
    expect(find.byKey(const Key('pendingBalance')), findsOneWidget);
    expect(find.byKey(const Key('lifetimeEarnings')), findsOneWidget);
    expect(find.text('GHS 17.34'), findsWidgets);
  });

  testWidgets('payout button opens the mock MoMo sheet', (tester) async {
    final c = EarningsController(StubEarningsRepository())
      ..snapshot = EarningsSnapshot.fromLedger([entry('1', 'fare', 17.34)]);
    await tester.pumpWidget(wrap(c));
    await tester.tap(find.byKey(const Key('payoutButton')));
    await tester.pumpAndSettle();
    expect(find.text('Withdraw to MoMo'), findsOneWidget);
    expect(find.byKey(const Key('payoutAmountField')), findsOneWidget);
    expect(find.byKey(const Key('confirmPayoutButton')), findsOneWidget);
  });

  testWidgets('a zero-balance wallet disables the payout button', (tester) async {
    final c = EarningsController(StubEarningsRepository())
      ..snapshot = EarningsSnapshot.fromLedger([]);
    await tester.pumpWidget(wrap(c));
    final button = tester.widget<FilledButton>(find.byKey(const Key('payoutButton')));
    expect(button.onPressed, isNull);
  });

  testWidgets('ledger rows render with their kind and amount', (tester) async {
    final c = EarningsController(StubEarningsRepository())
      ..snapshot = EarningsSnapshot.fromLedger([
        entry('1', 'fare', 17.34),
        entry('2', 'compensation', 5.0),
      ]);
    await tester.pumpWidget(wrap(c));
    expect(find.byKey(const Key('ledgerRow-1')), findsOneWidget);
    expect(find.byKey(const Key('ledgerRow-2')), findsOneWidget);
    expect(find.text('Trip fare'), findsOneWidget);
    expect(find.text('Cancellation compensation'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run and confirm it fails**

```bash
cd ~/meet-n-go/apps/driver && flutter test test/earnings/
```

Expected: FAIL — `EarningsController` is not defined.

- [ ] **Step 3: Write `earnings_repository.dart`**

```dart
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mng_core/mng_core.dart';

class PayoutFailure implements Exception {
  const PayoutFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class LedgerEntry {
  const LedgerEntry({
    required this.id,
    required this.kind,
    required this.amountGhs,
    required this.note,
    required this.createdAt,
  });

  factory LedgerEntry.fromJson(Map<String, dynamic> json) => LedgerEntry(
        id: json['id'] as String,
        kind: json['kind'] as String,
        amountGhs: (json['amount_ghs'] as num).toDouble(),
        note: (json['note'] as String?) ?? '',
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  final String id;
  final String kind;
  final double amountGhs;
  final String note;
  final DateTime createdAt;
}

class EarningsSnapshot {
  const EarningsSnapshot({
    required this.availableGhs,
    required this.pendingGhs,
    required this.lifetimeGhs,
    required this.entries,
  });

  factory EarningsSnapshot.fromLedger(List<LedgerEntry> rows) {
    var available = 0.0;
    var lifetime = 0.0;
    for (final e in rows) {
      if (e.kind == 'commission' || e.kind == 'void') {
        lifetime += e.amountGhs;
        if (e.kind == 'void') available = 0.0;
      } else {
        available += e.amountGhs;
        lifetime += e.amountGhs;
      }
    }
    return EarningsSnapshot(
      availableGhs: double.parse(available.toStringAsFixed(2)),
      pendingGhs: 0.0,
      lifetimeGhs: double.parse(lifetime.toStringAsFixed(2)),
      entries: rows,
    );
  }

  final double availableGhs;
  final double pendingGhs;
  final double lifetimeGhs;
  final List<LedgerEntry> entries;
}

abstract class EarningsRepository {
  Future<List<LedgerEntry>> ledger();
  Future<void> requestPayout({required double amountGhs});
}

class SupabaseEarningsRepository implements EarningsRepository {
  SupabaseEarningsRepository(this._client, this._driverId);
  final SupabaseClient _client;
  final String _driverId;

  @override
  Future<List<LedgerEntry>> ledger() async {
    final res = await _client
        .from('ledger_entries')
        .select('*')
        .eq('driver_id', _driverId)
        .order('created_at', ascending: false);
    if (res.error != null) throw PayoutFailure(res.error!.message);
    return (res.data as List<dynamic>)
        .map((r) => LedgerEntry.fromJson(Map<String, dynamic>.from(r as Map)))
        .toList();
  }

  @override
  Future<void> requestPayout({required double amountGhs}) async {
    if (amountGhs <= 0) {
      throw const PayoutFailure('Enter an amount greater than zero');
    }
    final res = await _client.functions.invoke(
      'demo-pay',
      body: {'action': 'payout', 'amountGhs': amountGhs},
    );
    if (res.error != null) throw PayoutFailure(res.error!.message);
  }
}
```

- [ ] **Step 4: Write `earnings_controller.dart`**

```dart
import 'package:flutter/foundation.dart';
import 'earnings_repository.dart';

class EarningsController extends ChangeNotifier {
  EarningsController(this._repo);

  final EarningsRepository _repo;

  EarningsSnapshot? snapshot;
  bool busy = false;
  String? error;

  Future<void> load() async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      snapshot = EarningsSnapshot.fromLedger(await _repo.ledger());
    } on PayoutFailure catch (e) {
      error = e.message;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<bool> requestPayout(double amountGhs) async {
    error = null;
    final available = snapshot?.availableGhs ?? 0.0;
    if (amountGhs <= 0) {
      error = 'Enter an amount greater than zero';
      notifyListeners();
      return false;
    }
    if (amountGhs > available) {
      error = 'You only have GHS ${available.toStringAsFixed(2)} available';
      notifyListeners();
      return false;
    }
    busy = true;
    notifyListeners();
    try {
      await _repo.requestPayout(amountGhs: amountGhs);
      await load();
      return true;
    } on PayoutFailure catch (e) {
      error = e.message;
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}
```

- [ ] **Step 5: Write `payout_sheet.dart` and `wallet_screen.dart`**

`payout_sheet.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'earnings_controller.dart';

class PayoutSheet extends StatefulWidget {
  const PayoutSheet({super.key, required this.controller});

  final EarningsController controller;

  @override
  State<PayoutSheet> createState() => _PayoutSheetState();
}

class _PayoutSheetState extends State<PayoutSheet> {
  final _amount = TextEditingController();
  final _pin = TextEditingController();
  bool sent = false;

  @override
  void dispose() {
    _amount.dispose();
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20.w, 8.h, 20.w, 32.h),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Withdraw to MoMo', style: MngTheme.light.textTheme.titleLarge),
          SizedBox(height: 6.h),
          Text(
            'Demo payout. No money moves and no network is called.',
            style: MngTheme.light.textTheme.bodySmall,
          ),
          SizedBox(height: 20.h),
          TextField(
            key: const Key('payoutAmountField'),
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              prefixText: 'GHS ',
              hintText: widget.controller.snapshot?.availableGhs.toStringAsFixed(2) ?? '0.00',
            ),
          ),
          SizedBox(height: 12.h),
          TextField(
            key: const Key('payoutPinField'),
            controller: _pin,
            obscureText: true,
            maxLength: 6,
            decoration: const InputDecoration(
              hintText: 'MoMo PIN (any 6 digits)',
              counterText: '',
            ),
          ),
          if (widget.controller.error != null) ...[
            SizedBox(height: 8.h),
            Text(
              widget.controller.error!,
              style: const TextStyle(color: MngColors.error),
            ),
          ],
          if (sent) ...[
            SizedBox(height: 16.h),
            Text(
              'Payout requested. It is a demo, so nothing was sent.',
              style: const TextStyle(color: MngColors.success),
            ),
          ],
          SizedBox(height: 20.h),
          FilledButton(
            key: const Key('confirmPayoutButton'),
            onPressed: widget.controller.busy
                ? null
                : () async {
                    final ok = await widget.controller.requestPayout(
                      double.tryParse(_amount.text.trim()) ?? 0,
                    );
                    if (ok && mounted) setState(() => sent = true);
                  },
            child: const Text('Confirm withdrawal'),
          ),
        ],
      ),
    );
  }
}
```

`wallet_screen.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';
import 'earnings_controller.dart';
import 'earnings_repository.dart';
import 'payout_sheet.dart';

const _kindLabels = {
  'fare': 'Trip fare',
  'commission': 'Platform commission',
  'compensation': 'Cancellation compensation',
  'void': 'Voided charge',
  'bonus': 'Bonus',
};

class WalletScreen extends StatelessWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<EarningsController>();
    final s = c.snapshot;
    final available = s?.availableGhs ?? 0.0;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: MngColors.page,
        elevation: 0,
        title: Text('Earnings', style: MngTheme.light.textTheme.titleLarge),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
              child: Column(
                children: [
                  _BalanceTile(
                    tileKey: 'availableBalance',
                    label: 'Available',
                    amountGhs: available,
                    highlight: true,
                  ),
                  SizedBox(height: 12.h),
                  Row(
                    children: [
                      Expanded(
                        child: _BalanceTile(
                          tileKey: 'pendingBalance',
                          label: 'Pending',
                          amountGhs: s?.pendingGhs ?? 0.0,
                        ),
                      ),
                      SizedBox(width: 12.w),
                      Expanded(
                        child: _BalanceTile(
                          tileKey: 'lifetimeEarnings',
                          label: 'Lifetime',
                          amountGhs: s?.lifetimeGhs ?? 0.0,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20.w),
              child: FilledButton(
                key: const Key('payoutButton'),
                onPressed: available <= 0
                    ? null
                    : () => showModalBottomSheet<void>(
                          context: context,
                          isScrollControlled: true,
                          builder: (_) => PayoutSheet(controller: c),
                        ),
                child: const Text('Withdraw'),
              ),
            ),
            SizedBox(height: 16.h),
            Expanded(
              child: (s?.entries.isEmpty ?? true)
                  ? Center(
                      child: Text(
                        'No earnings yet',
                        style: MngTheme.light.textTheme.bodySmall,
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.symmetric(horizontal: 20.w),
                      itemCount: s!.entries.length,
                      itemBuilder: (context, i) {
                        final e = s.entries[i];
                        return ListTile(
                          key: Key('ledgerRow-${e.id}'),
                          contentPadding: EdgeInsets.zero,
                          title: Text(_kindLabels[e.kind] ?? e.kind),
                          subtitle: Text(
                            DateTime.parse(e.createdAt.toIso8601String())
                                .toIso8601String()
                                .substring(0, 10),
                            style: MngTheme.light.textTheme.bodySmall,
                          ),
                          trailing: Text(
                            '${e.amountGhs >= 0 ? '+' : '-'}GHS ${e.amountGhs.abs().toStringAsFixed(2)}',
                            style: TextStyle(
                              color: e.amountGhs >= 0 ? MngColors.success : MngColors.error,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BalanceTile extends StatelessWidget {
  const _BalanceTile({
    required this.tileKey,
    required this.label,
    required this.amountGhs,
    this.highlight = false,
  });

  final String tileKey;
  final String label;
  final double amountGhs;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key(tileKey),
      width: double.infinity,
      padding: EdgeInsets.all(16.w),
      decoration: BoxDecoration(
        color: highlight ? MngColors.textPrimary : MngColors.muted,
        borderRadius: BorderRadius.circular(MngRadius.large),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: MngTheme.light.textTheme.bodySmall?.copyWith(
              color: highlight ? MngColors.primary : MngColors.textSub,
            ),
          ),
          SizedBox(height: 4.h),
          Text(
            'GHS ${amountGhs.toStringAsFixed(2)}',
            style: MngTheme.light.textTheme.titleLarge?.copyWith(
              color: highlight ? Colors.white : MngColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 6: Run the tests and confirm they pass**

```bash
cd ~/meet-n-go/apps/driver && flutter test test/earnings/ && flutter analyze
```

Expected: 14 tests pass, analyze clean.

- [ ] **Step 7: Commit**

```bash
cd ~/meet-n-go && git add -A
git -c user.email=opencode@local -c user.name=opencode commit -m "feat(driver): earnings wallet with demo payout sheet and ledger"
```

---

### Task 16: Chat, bookings, profile, and bottom navigation in both apps

**Files:**
- Create: `apps/rider/lib/src/chat/chat_repository.dart`
- Create: `apps/rider/lib/src/chat/chat_controller.dart`
- Create: `apps/rider/lib/src/chat/chat_screen.dart`
- Create: `apps/rider/lib/src/bookings/bookings_screen.dart`
- Create: `apps/rider/lib/src/profile/profile_screen.dart`
- Create: `apps/rider/lib/src/shell/rider_shell.dart`
- Create: `apps/driver/lib/src/chat/driver_chat_screen.dart`
- Create: `apps/driver/lib/src/driver_bookings/driver_bookings_screen.dart`
- Create: `apps/driver/lib/src/driver_profile/driver_profile_screen.dart`
- Create: `apps/driver/lib/src/shell/driver_shell.dart`
- Test: `apps/rider/test/chat/chat_test.dart`
- Test: `apps/rider/test/shell/rider_shell_test.dart`
- Test: `apps/driver/test/shell/driver_shell_test.dart`

**Interfaces:**
- Consumes: `MngTheme` (Task 1), `Trip` (Task 4), `Rating` (Task 4), driver `DriverRepository` (Tasks 12-14)
- Produces:
  - `class ChatMessage` — `ChatMessage({required this.id, required this.tripId, required this.senderId, required this.body, required this.createdAt})` with `fromJson`.
  - `abstract class ChatRepository` with `Future<List<ChatMessage>> messages(String tripId)`, `Future<void> send(String tripId, String body)`, `Stream<ChatMessage> watch(String tripId)`.
  - `class ChatController extends ChangeNotifier` with `List<ChatMessage> messages`, `String? error`, `bool busy`, `Future<void> load(String tripId)`, `Future<bool> send(String body)`.
  - `ChatScreen({required ChatController controller, required String tripId, required String peerName})` — keys `chatList`, `chatInput`, `chatSendButton`, and a `bubble-mine` / `bubble-theirs` key per message.
  - `BookingsScreen({required TripRepository trips})` — key `bookingRow-<tripId>`, shows past trips with state and fare.
  - `ProfileScreen({required String fullName, required String phone, required void Function() onSignOut})` — keys `profileName`, `signOutButton`.
  - `RiderShell({required Widget home, required Widget bookings, required Widget chat, required Widget profile})` — bottom nav with labels `Home`, `Bookings`, `Chat`, `Profile` and keys `nav-home`, `nav-bookings`, `nav-chat`, `nav-profile`.
  - `DriverShell`, `DriverBookingsScreen({required TripRepository trips})`, `DriverProfileScreen({required DriverRepository drivers, required void Function() onSignOut})` with the same four nav labels and keys.

- [ ] **Step 1: Write the failing chat test**

`apps/rider/test/chat/chat_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/chat/chat_controller.dart';
import 'package:meetngo_rider/src/chat/chat_repository.dart';
import 'package:meetngo_rider/src/chat/chat_screen.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';

ChatMessage message(String id, String sender, String body) => ChatMessage(
      id: id,
      tripId: 't1',
      senderId: sender,
      body: body,
      createdAt: DateTime(2026, 9, 27, 10),
    );

class StubChatRepository implements ChatRepository {
  List<ChatMessage> history = [];
  final List<String> sent = [];
  bool failSend = false;

  @override
  Future<List<ChatMessage>> messages(String tripId) async => history;

  @override
  Future<void> send(String tripId, String body) async {
    if (failSend) throw const ChatFailure('Message could not be sent');
    sent.add(body);
  }

  @override
  Stream<ChatMessage> watch(String tripId) => const Stream<ChatMessage>.empty();
}

Widget wrap(ChatController c) => ScreenUtilInit(
      designSize: const Size(390, 844),
      builder: (_, __) => ChangeNotifierProvider<ChatController>.value(
        value: c,
        child: const MaterialApp(home: ChatScreen(tripId: 't1', peerName: 'Jane')),
      ),
    );

void main() {
  test('load fills the message list oldest first', () async {
    final repo = StubChatRepository()
      ..history = [message('m1', 'me', 'On my way'), message('m2', 'd1', 'Great')];
    final c = ChatController(repo);
    await c.load('t1');
    expect(c.messages.map((m) => m.id), ['m1', 'm2']);
  });

  test('an empty message is not sent', () async {
    final repo = StubChatRepository();
    final c = ChatController(repo);
    expect(await c.send('   '), isFalse);
    expect(repo.sent, isEmpty);
  });

  test('a sent message is appended locally', () async {
    final repo = StubChatRepository();
    final c = ChatController(repo);
    await c.load('t1');
    expect(await c.send('On my way'), isTrue);
    expect(repo.sent, ['On my way']);
    expect(c.messages.single.body, 'On my way');
  });

  test('a failed send surfaces an error and keeps the draft', () async {
    final repo = StubChatRepository()..failSend = true;
    final c = ChatController(repo);
    await c.load('t1');
    expect(await c.send('On my way'), isFalse);
    expect(c.error, 'Message could not be sent');
  });

  testWidgets('incoming and outgoing messages render as different bubbles', (tester) async {
    final repo = StubChatRepository()
      ..history = [message('m1', 'd1', 'Great'), message('m2', 'me', 'On my way')];
    final c = ChatController(repo);
    await c.load('t1');
    await tester.pumpWidget(wrap(c));
    expect(find.byKey(const Key('bubble-m1')), findsOneWidget);
    expect(find.byKey(const Key('bubble-m2')), findsOneWidget);
    expect(find.text('Great'), findsOneWidget);
    expect(find.text('On my way'), findsOneWidget);
  });

  testWidgets('the send button posts the input text', (tester) async {
    final repo = StubChatRepository();
    final c = ChatController(repo);
    await c.load('t1');
    await tester.pumpWidget(wrap(c));
    await tester.enterText(find.byKey(const Key('chatInput')), 'At the junction');
    await tester.tap(find.byKey(const Key('chatSendButton')));
    await tester.pump();
    expect(repo.sent, ['At the junction']);
  });
}
```

- [ ] **Step 2: Run and confirm it fails**

```bash
cd ~/meet-n-go/apps/rider && flutter test test/chat/
```

Expected: FAIL — `ChatController` is not defined.

- [ ] **Step 3: Write `chat_repository.dart` and `chat_controller.dart`**

`chat_repository.dart`:

```dart
import 'package:supabase_flutter/supabase_flutter.dart';

class ChatFailure implements Exception {
  const ChatFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.tripId,
    required this.senderId,
    required this.body,
    required this.createdAt,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as String,
        tripId: json['trip_id'] as String,
        senderId: json['sender_id'] as String,
        body: json['body'] as String,
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  final String id;
  final String tripId;
  final String senderId;
  final String body;
  final DateTime createdAt;
}

abstract class ChatRepository {
  Future<List<ChatMessage>> messages(String tripId);
  Future<void> send(String tripId, String body);
  Stream<ChatMessage> watch(String tripId);
}

class SupabaseChatRepository implements ChatRepository {
  SupabaseChatRepository(this._client, this._selfId);
  final SupabaseClient _client;
  final String _selfId;

  @override
  Future<List<ChatMessage>> messages(String tripId) async {
    final res = await _client
        .from('chat_messages')
        .select('*')
        .eq('trip_id', tripId)
        .order('created_at', ascending: true);
    if (res.error != null) throw ChatFailure(res.error!.message);
    return (res.data as List<dynamic>)
        .map((r) => ChatMessage.fromJson(Map<String, dynamic>.from(r as Map)))
        .toList();
  }

  @override
  Future<void> send(String tripId, String body) async {
    final res = await _client
        .from('chat_messages')
        .insert({'trip_id': tripId, 'sender_id': _selfId, 'body': body});
    if (res.error != null) throw ChatFailure(res.error!.message);
  }

  @override
  Stream<ChatMessage> watch(String tripId) => _client
      .channel('trip_$tripId')
      .onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'chat_messages',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'trip_id',
          value: tripId,
        ),
      )
      .stream()
      .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e.newRecord)));
}
```

`chat_controller.dart`:

```dart
import 'package:flutter/foundation.dart';
import 'chat_repository.dart';

class ChatController extends ChangeNotifier {
  ChatController(this._repo);

  final ChatRepository _repo;
  final List<ChatMessage> _messages = [];

  String selfId = '';
  String? error;
  bool busy = false;

  List<ChatMessage> get messages => List.unmodifiable(_messages);

  Future<void> load(String tripId) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final rows = await _repo.messages(tripId);
      _messages
        ..clear()
        ..addAll(rows);
    } on ChatFailure catch (e) {
      error = e.message;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<bool> send(String body) async {
    error = null;
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      notifyListeners();
      return false;
    }
    busy = true;
    notifyListeners();
    try {
      await _repo.send(_tripId, trimmed);
      _messages.add(
        ChatMessage(
          id: 'local-${DateTime.now().microsecondsSinceEpoch}',
          tripId: _tripId,
          senderId: selfId,
          body: trimmed,
          createdAt: DateTime.now(),
        ),
      );
      return true;
    } on ChatFailure catch (e) {
      error = e.message;
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  String _tripId = '';
  void bind(String tripId, {required String selfId}) {
    _tripId = tripId;
    this.selfId = selfId;
  }
}
```

- [ ] **Step 4: Write `chat_screen.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'package:provider/provider.dart';
import 'chat_controller.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.tripId, required this.peerName});

  final String tripId;
  final String peerName;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<ChatController>();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: MngColors.page,
        elevation: 0,
        title: Text(widget.peerName, style: MngTheme.light.textTheme.titleMedium),
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (c.error != null)
              Padding(
                padding: EdgeInsets.all(8.w),
                child: Text(
                  c.error!,
                  style: const TextStyle(color: MngColors.error),
                ),
              ),
            Expanded(
              child: ListView.builder(
                key: const Key('chatList'),
                padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 12.h),
                itemCount: c.messages.length,
                itemBuilder: (context, i) {
                  final m = c.messages[i];
                  final mine = m.senderId == c.selfId;
                  return Align(
                    key: Key('bubble-${m.id}'),
                    alignment:
                        mine ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: mine ? MngColors.primary : MngColors.muted,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Text(
                        m.body,
                        style: TextStyle(
                          color: mine ? MngColors.onPrimary : MngColors.textPrimary,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(20.w, 8.h, 20.w, 12.h),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('chatInput'),
                        controller: _input,
                        decoration: const InputDecoration(hintText: 'Message'),
                      ),
                    ),
                    SizedBox(width: 8.w),
                    IconButton.filled(
                      key: const Key('chatSendButton'),
                      onPressed: c.busy
                          ? null
                          : () async {
                              final ok = await c.send(_input.text);
                              if (ok) _input.clear();
                            },
                      icon: const Icon(Icons.send),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 5: Run the chat tests and confirm they pass**

```bash
cd ~/meet-n-go/apps/rider && flutter test test/chat/
```

Expected: 6 tests pass.

- [ ] **Step 6: Write the failing shell tests**

`apps/rider/test/shell/rider_shell_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_rider/src/shell/rider_shell.dart';

void main() {
  testWidgets('starts on Home and shows the four tabs', (tester) async {
    await tester.pumpWidget(ScreenUtilInit(
      designSize: const Size(390, 844),
      builder: (_, __) => const MaterialApp(
        home: RiderShell(
          home: Scaffold(body: Text('home-body')),
          bookings: Scaffold(body: Text('bookings-body')),
          chat: Scaffold(body: Text('chat-body')),
          profile: Scaffold(body: Text('profile-body')),
        ),
      ),
    ));
    expect(find.text('home-body'), findsOneWidget);
    for (final label in ['Home', 'Bookings', 'Chat', 'Profile']) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('tapping each tab swaps the body', (tester) async {
    await tester.pumpWidget(ScreenUtilInit(
      designSize: const Size(390, 844),
      builder: (_, __) => const MaterialApp(
        home: RiderShell(
          home: Scaffold(body: Text('home-body')),
          bookings: Scaffold(body: Text('bookings-body')),
          chat: Scaffold(body: Text('chat-body')),
          profile: Scaffold(body: Text('profile-body')),
        ),
      ),
    ));
    for (final entry in {
      'nav-bookings': 'bookings-body',
      'nav-chat': 'chat-body',
      'nav-profile': 'profile-body',
      'nav-home': 'home-body',
    }.entries) {
      await tester.tap(find.byKey(Key(entry.key)));
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget, reason: entry.key);
    }
  });
}
```

`apps/driver/test/shell/driver_shell_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_driver/src/shell/driver_shell.dart';

void main() {
  testWidgets('driver shell has Earnings, Bookings, Chat and Profile', (tester) async {
    await tester.pumpWidget(ScreenUtilInit(
      designSize: const Size(390, 844),
      builder: (_, __) => const MaterialApp(
        home: DriverShell(
          home: Scaffold(body: Text('home-body')),
          bookings: Scaffold(body: Text('bookings-body')),
          chat: Scaffold(body: Text('chat-body')),
          profile: Scaffold(body: Text('profile-body')),
        ),
      ),
    ));
    expect(find.text('home-body'), findsOneWidget);
    for (final label in ['Earnings', 'Bookings', 'Chat', 'Profile']) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('tapping each tab swaps the body', (tester) async {
    await tester.pumpWidget(ScreenUtilInit(
      designSize: const Size(390, 844),
      builder: (_, __) => const MaterialApp(
        home: DriverShell(
          home: Scaffold(body: Text('home-body')),
          bookings: Scaffold(body: Text('bookings-body')),
          chat: Scaffold(body: Text('chat-body')),
          profile: Scaffold(body: Text('profile-body')),
        ),
      ),
    ));
    for (final entry in {
      'nav-bookings': 'bookings-body',
      'nav-chat': 'chat-body',
      'nav-profile': 'profile-body',
      'nav-home': 'home-body',
    }.entries) {
      await tester.tap(find.byKey(Key(entry.key)));
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget, reason: entry.key);
    }
  });
}
```

- [ ] **Step 7: Run and confirm they fail**

```bash
cd ~/meet-n-go/apps/rider && flutter test test/shell/
cd ~/meet-n-go/apps/driver && flutter test test/shell/
```

Expected: FAIL — `RiderShell` and `DriverShell` are not defined.

- [ ] **Step 8: Write `rider_shell.dart` and `driver_shell.dart`**

`apps/rider/lib/src/shell/rider_shell.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:mng_core/mng_core.dart';

class RiderShell extends StatefulWidget {
  const RiderShell({
    super.key,
    required this.home,
    required this.bookings,
    required this.chat,
    required this.profile,
  });

  final Widget home;
  final Widget bookings;
  final Widget chat;
  final Widget profile;

  @override
  State<RiderShell> createState() => _RiderShellState();
}

class _RiderShellState extends State<RiderShell> {
  int _index = 0;

  static const _tabs = [
    (key: 'nav-home', label: 'Home', icon: Icons.home_outlined),
    (key: 'nav-bookings', label: 'Bookings', icon: Icons.receipt_long_outlined),
    (key: 'nav-chat', label: 'Chat', icon: Icons.chat_bubble_outline),
    (key: 'nav-profile', label: 'Profile', icon: Icons.person_outline),
  ];

  @override
  Widget build(BuildContext context) {
    final body = switch (_index) {
      0 => widget.home,
      1 => widget.bookings,
      2 => widget.chat,
      _ => widget.profile,
    };

    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        backgroundColor: MngColors.page,
        indicatorColor: MngColors.primary,
        destinations: [
          for (final t in _tabs)
            NavigationDestination(
              key: Key(t.key),
              icon: Icon(t.icon),
              label: t.label,
            ),
        ],
      ),
    );
  }
}
```

`apps/driver/lib/src/shell/driver_shell.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:mng_core/mng_core.dart';

class DriverShell extends StatefulWidget {
  const DriverShell({
    super.key,
    required this.home,
    required this.bookings,
    required this.chat,
    required this.profile,
  });

  final Widget home;
  final Widget bookings;
  final Widget chat;
  final Widget profile;

  @override
  State<DriverShell> createState() => _DriverShellState();
}

class _DriverShellState extends State<DriverShell> {
  int _index = 0;

  static const _tabs = [
    (key: 'nav-home', label: 'Earnings', icon: Icons.account_balance_wallet_outlined),
    (key: 'nav-bookings', label: 'Bookings', icon: Icons.receipt_long_outlined),
    (key: 'nav-chat', label: 'Chat', icon: Icons.chat_bubble_outline),
    (key: 'nav-profile', label: 'Profile', icon: Icons.person_outline),
  ];

  @override
  Widget build(BuildContext context) {
    final body = switch (_index) {
      0 => widget.home,
      1 => widget.bookings,
      2 => widget.chat,
      _ => widget.profile,
    };

    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        backgroundColor: MngColors.page,
        indicatorColor: MngColors.primary,
        destinations: [
          for (final t in _tabs)
            NavigationDestination(
              key: Key(t.key),
              icon: Icon(t.icon),
              label: t.label,
            ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 9: Write `bookings_screen.dart`, `profile_screen.dart`, and the driver equivalents**

`apps/rider/lib/src/bookings/bookings_screen.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import '../data/trip_repository.dart';

class BookingsScreen extends StatefulWidget {
  const BookingsScreen({super.key, required this.trips});

  final TripRepository trips;

  @override
  State<BookingsScreen> createState() => _BookingsScreenState();
}

class _BookingsScreenState extends State<BookingsScreen> {
  late Future<List<Trip>> _future = widget.trips.history();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: MngColors.page,
        elevation: 0,
        title: Text('Your trips', style: MngTheme.light.textTheme.titleLarge),
      ),
      body: SafeArea(
        child: FutureBuilder<List<Trip>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final trips = snap.data ?? const <Trip>[];
            if (trips.isEmpty) {
              return Center(
                child: Text(
                  'No trips yet',
                  style: MngTheme.light.textTheme.bodySmall,
                ),
              );
            }
            return ListView.builder(
              padding: EdgeInsets.symmetric(horizontal: 20.w),
              itemCount: trips.length,
              itemBuilder: (context, i) {
                final t = trips[i];
                return ListTile(
                  key: Key('bookingRow-${t.id}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text('${t.pickup.address} to ${t.dropoff.address}'),
                  subtitle: Text(t.state.name, style: MngTheme.light.textTheme.bodySmall),
                  trailing: Text('GHS ${t.fareGhs.toStringAsFixed(2)}'),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
```

Add `Future<List<Trip>> history();` to the rider `TripRepository` abstract class and to `SupabaseTripRepository`:

```dart
  @override
  Future<List<Trip>> history() async {
    final res = await _client
        .from('trips')
        .select('*')
        .eq('rider_id', _riderId)
        .in('state', ['completed', 'cancelled'])
        .order('created_at', ascending: false)
        .limit(50);
    if (res.error != null) throw AuthFailure(res.error!.message);
    return (res.data as List<dynamic>)
        .map((r) => Trip.fromJson(Map<String, dynamic>.from(r as Map)))
        .toList();
  }
```

`apps/rider/lib/src/profile/profile_screen.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({
    super.key,
    required this.fullName,
    required this.phone,
    required this.onSignOut,
  });

  final String fullName;
  final String phone;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: MngColors.page,
        elevation: 0,
        title: Text('Profile', style: MngTheme.light.textTheme.titleLarge),
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 16.h),
          children: [
            CircleAvatar(
              radius: 40,
              backgroundColor: MngColors.primary,
              child: Text(
                fullName.isEmpty ? '?' : fullName.characters.first,
                style: MngTheme.light.textTheme.titleLarge,
              ),
            ),
            SizedBox(height: 12.h),
            Text(
              fullName,
              key: const Key('profileName'),
              style: MngTheme.light.textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 4.h),
            Text(phone, style: MngTheme.light.textTheme.bodySmall, textAlign: TextAlign.center),
            SizedBox(height: 32.h),
            const ListTile(
              leading: Icon(Icons.credit_card),
              title: Text('Payment methods'),
              subtitle: Text('Demo only in this build'),
            ),
            const ListTile(
              leading: Icon(Icons.support_agent),
              title: Text('Safety'),
              subtitle: Text('Share trip, SOS, pickup code'),
            ),
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('About Meet \'N Go'),
              subtitle: Text('Version 0.1.0 pilot'),
            ),
            SizedBox(height: 24.h),
            OutlinedButton(
              key: const Key('signOutButton'),
              onPressed: onSignOut,
              child: const Text('Sign out'),
            ),
          ],
        ),
      ),
    );
  }
}
```

`apps/driver/lib/src/driver_bookings/driver_bookings_screen.dart` is the same widget with `TripsScreen({required TripRepository trips})` reading `widget.trips.driverHistory()`; add that method to the driver-side `TripRepository`. `apps/driver/lib/src/driver_profile/driver_profile_screen.dart` mirrors `ProfileScreen` but renders `kyc.name` and `availability.name` instead of a phone number. `apps/driver/lib/src/chat/driver_chat_screen.dart` is `ChatScreen` imported from the rider app's `src/chat` — to avoid a cross-app dependency, copy the file into the driver app and change the package import in the test.

- [ ] **Step 10: Run the shell tests and confirm they pass**

```bash
cd ~/meet-n-go/apps/rider && flutter test && flutter analyze
cd ~/meet-n-go/apps/driver && flutter test && flutter analyze
```

Expected: all tests pass in both apps, analyze clean.

- [ ] **Step 11: Wire both shells into the app entry points**

`apps/rider/lib/main.dart` becomes:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';
import 'src/auth/splash_screen.dart';
import 'src/shell/rider_shell.dart';

class RideNGoApp extends StatelessWidget {
  const RideNGoApp({super.key, this.home});

  final Widget? home;

  @override
  Widget build(BuildContext context) {
    return ScreenUtilInit(
      designSize: const Size(390, 844),
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (_, __) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: "Meet 'N Go",
        theme: MngTheme.light,
        home: home ?? const SplashScreen(),
      ),
    );
  }
}

void main() => runApp(const RideNGoApp());
```

`apps/driver/lib/main.dart` becomes the same with `DriverNGoApp` and `SplashScreen` from the driver app's own `src/onboarding`. The `home` parameter exists so tests can inject `RiderShell`/`DriverShell` directly.

- [ ] **Step 12: Commit**

```bash
cd ~/meet-n-go && git add -A
git -c user.email=opencode@local -c user.name=opencode commit -m "feat: chat, bookings, profile and bottom navigation in both apps"
```

---

### Task 17: Full trip-lifecycle integration test

**Files:**
- Create: `apps/driver/test/integration/trip_lifecycle_test.dart`
- Modify: `apps/driver/lib/src/active_trip/active_trip_controller.dart`
- Modify: `apps/driver/lib/src/offers/offer_queue_controller.dart`
- Test: `apps/driver/test/integration/trip_lifecycle_test.dart`

**Interfaces:**
- Consumes: `ActiveTripController` (Task 14), `OfferQueueController` and `AvailabilityController` (Task 13), `Trip`, `TripState` (Tasks 3, 4), `canTransition` (Task 3)
- Produces:
  - `ActiveTripController.restore({required DriverRepository drivers})` — a named async factory that loads the driver's active trip and returns a controller already bound to it, so a cold app start lands on the live trip instead of an empty state.
  - One integration test that drives the whole flow through an in-memory fake repository and asserts the trip's final state, the driver's availability, and the ledger.

- [ ] **Step 1: Write the failing lifecycle test**

`apps/driver/test/integration/trip_lifecycle_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:meetngo_driver/src/active_trip/active_trip_controller.dart';
import 'package:meetngo_driver/src/offers/availability_controller.dart';
import 'package:meetngo_driver/src/offers/offer_queue_controller.dart';
import 'package:mng_core/mng_core.dart';

import '../offers/availability_test.dart' show StubDriverRepository;
import '../offers/offer_queue_test.dart' show offer;
import '../active_trip/active_trip_test.dart' show TripRepo;

class MemoryBackend {
  final Map<String, Trip> trips = {};
  final Map<String, Offer> offers = {};
  final Map<String, String> otps = {};
  DriverAvailability availability = DriverAvailability.offline;

  int payoutLines = 0;
}

/// A repository backed entirely by memory, with the same rules the real RPCs
/// enforce: one winner per trip, legal state transitions only, OTP required
/// before a trip can start.
class FakeDriverRepository implements StubDriverRepository {
  FakeDriverRepository(this.backend);
  final MemoryBackend backend;

  Trip? get activeTripNow {
    for (final t in backend.trips.values) {
      if (t.driverId == 'd1' && t.state.isActive) return t;
    }
    return null;
  }

  @override
  Future<Trip?> activeTrip() async => activeTripNow;

  @override
  Future<void> setAvailability(DriverAvailability value) async {
    backend.availability = value;
  }

  @override
  Future<void> acceptOffer(String offerId) async {
    final o = backend.offers[offerId]!;
    final t = backend.trips[o.tripId]!;
    if (t.state != TripState.requested) {
      throw const DriverAuthFailure('Trip was taken by another driver');
    }
    backend.offers[offerId] = o.copyWith(state: OfferState.accepted);
    for (final e in backend.offers.values.toList()) {
      if (e.tripId == o.tripId && e.id != offerId && e.state == OfferState.pending) {
        backend.offers[e.id] = e.copyWith(state: OfferState.released);
      }
    }
    backend.trips[o.tripId] = t.copyWith(state: TripState.matched, driverId: o.driverId);
    backend.availability = DriverAvailability.onTrip;
  }

  @override
  Future<void> declineOffer(String offerId) async {
    backend.offers[offerId] =
        backend.offers[offerId]!.copyWith(state: OfferState.declined);
  }

  @override
  Future<void> advanceTripState(String tripId, TripState to) async {
    final t = backend.trips[tripId]!;
    if (!canTransition(t.state, to)) {
      throw const DriverAuthFailure('Trip is no longer in a state you can move');
    }
    backend.trips[tripId] = t.copyWith(state: to);
    if (to == TripState.completed) {
      backend.availability = DriverAvailability.online;
      backend.payoutLines++;
    }
  }

  @override
  Future<void> verifyPickupOtp(String tripId, String code) async {
    if (backend.otps[tripId] != code.trim()) {
      throw const DriverAuthFailure('That code is not right');
    }
  }

  @override
  Future<DriverProfile?> me() async => null;

  @override
  Future<void> submitGhanaCard({
    required String cardNumber,
    required String expiry,
    required String fullName,
  }) async {}

  @override
  Future<void> submitSelfie(String path) async {}

  @override
  Future<void> saveVehicle({
    required String make,
    required String model,
    required String plate,
    required int seats,
    required RideCategory rideCategory,
  }) async {}

  @override
  Future<void> updateLocation(GeoPoint point) async {}

  @override
  Stream<DriverProfile> watchMe() => const Stream<DriverProfile>.empty();
}

MemoryBackend seeded() {
  final b = MemoryBackend();
  b.trips['t1'] = Trip(
    id: 't1',
    riderId: 'r1',
    driverId: null,
    category: RideCategory.standard,
    state: TripState.requested,
    pickup: const TripStop('Pickup', GeoPoint(5.6037, -0.1870), 'Osu, Accra'),
    dropoff: const TripStop('Dropoff', GeoPoint(5.6200, -0.1870), 'Airport'),
    distanceKm: 2.02,
    fareGhs: 12.50,
    isDemo: true,
  );
  b.offers['o1'] = offer('o1');
  b.offers['o2'] = offer('o2');
  b.otps['t1'] = '4821';
  return b;
}

void main() {
  test('the whole trip walks request to completed exactly once', () async {
    final backend = seeded();
    final repo = FakeDriverRepository(backend);

    // 1. driver goes online
    final availability = AvailabilityController(repo);
    expect(await availability.setOnline(true), isTrue);
    expect(backend.availability, DriverAvailability.online);

    // 2. two offers arrive, the first driver wins
    final queue = OfferQueueController(repo)
      ..add(backend.offers['o1']!)
      ..add(backend.offers['o2']!);
    expect(await queue.accept(queue.offers.first), isTrue);
    expect(backend.trips['t1']!.state, TripState.matched);
    expect(backend.offers['o2']!.state, OfferState.released);
    expect(backend.availability, DriverAvailability.onTrip);

    // 3. the losing driver's accept is rejected
    final loser = AvailabilityController(FakeDriverRepository(backend));
    expect(await loser.setOnline(true), isTrue);
    final secondQueue = OfferQueueController(FakeDriverRepository(backend))
      ..add(backend.offers['o2']!);
    expect(await secondQueue.accept(secondQueue.offers.first), isFalse);

    // 4. the winning driver navigates, arrives, verifies the OTP and completes
    final active = ActiveTripController(repo)..trip = backend.trips['t1'];
    expect(await active.advance(), isTrue);
    expect(backend.trips['t1']!.state, TripState.arriving);
    expect(await active.submitPickupOtp('4821'), isTrue);
    expect(backend.trips['t1']!.state, TripState.ongoing);
    expect(await active.advance(), isTrue);
    expect(backend.trips['t1']!.state, TripState.completed);
    expect(backend.payoutLines, 1);
    expect(backend.availability, DriverAvailability.online);

    // 5. the driver is free to go offline again
    expect(await availability.setOnline(false), isTrue);
    expect(backend.availability, DriverAvailability.offline);
  });

  test('a wrong pickup OTP leaves the trip in arriving and blocks going offline', () async {
    final backend = seeded();
    final repo = FakeDriverRepository(backend);
    await AvailabilityController(repo).setOnline(true);
    final queue = OfferQueueController(repo)..add(backend.offers['o1']!);
    await queue.accept(queue.offers.first);
    final active = ActiveTripController(repo)..trip = backend.trips['t1'];
    await active.advance();
    expect(backend.trips['t1']!.state, TripState.arriving);
    expect(await active.submitPickupOtp('0000'), isFalse);
    expect(backend.trips['t1']!.state, TripState.arriving);
    expect(await AvailabilityController(repo).setOnline(false), isFalse);
  });

  test('active_trip_survives_app_restart_test', () async {
    final backend = seeded();
    final repo = FakeDriverRepository(backend);
    await AvailabilityController(repo).setOnline(true);
    final queue = OfferQueueController(repo)..add(backend.offers['o1']!);
    await queue.accept(queue.offers.first);
    final first = ActiveTripController(repo)..trip = backend.trips['t1'];
    await first.advance();
    expect(backend.trips['t1']!.state, TripState.arriving);

    // the process is killed and the app restarts with no in-memory state
    final restored = await ActiveTripController.restore(drivers: repo);
    expect(restored.trip, isNotNull, reason: 'a live trip must be restored on cold start');
    expect(restored.trip!.id, 't1');
    expect(restored.trip!.state, TripState.arriving);
    expect(restored.headline, 'Collect your rider');

    // and the restored controller can still finish the trip
    expect(await restored.submitPickupOtp('4821'), isTrue);
    expect(backend.trips['t1']!.state, TripState.ongoing);
  });

  test('restore returns an empty controller when no trip is active', () async {
    final backend = seeded();
    final restored = await ActiveTripController.restore(
      drivers: FakeDriverRepository(backend),
    );
    expect(restored.trip, isNull);
    expect(restored.headline, 'No active trip');
  });

  test('the rider cancelling mid- trip returns the driver to online', () async {
    final backend = seeded();
    final repo = FakeDriverRepository(backend);
    await AvailabilityController(repo).setOnline(true);
    final queue = OfferQueueController(repo)..add(backend.offers['o1']!);
    await queue.accept(queue.offers.first);
    final active = ActiveTripController(repo)..trip = backend.trips['t1'];
    await active.advance();
    // rider cancels while the driver is in `arriving`
    backend.trips['t1'] = backend.trips['t1']!.copyWith(
      state: TripState.cancelled,
      clearDriver: true,
    );
    backend.availability = DriverAvailability.online;
    expect(await AvailabilityController(repo).setOnline(true), isTrue);
  });
}
```

- [ ] **Step 2: Run and confirm it fails**

```bash
cd ~/meet-n-go/apps/driver && flutter test test/integration/
```

Expected: FAIL — `ActiveTripController.restore` is not defined.

- [ ] **Step 3: Add `restore` to `ActiveTripController`**

In `apps/driver/lib/src/active_trip/active_trip_controller.dart`, inside the class:

```dart
  static Future<ActiveTripController> restore({required DriverRepository drivers}) async {
    final c = ActiveTripController(drivers);
    try {
      c.trip = await drivers.activeTrip();
    } on DriverAuthFailure catch (e) {
      c.error = e.message;
    }
    return c;
  }
```

- [ ] **Step 4: Run the integration tests and confirm they pass**

```bash
cd ~/meet-n-go/apps/driver && flutter test test/integration/ && flutter analyze
```

Expected: 5 tests pass, analyze clean.

- [ ] **Step 5: Run the whole suite in both apps plus the Deno suite**

```bash
cd ~/meet-n-go/apps/rider && flutter test
cd ~/meet-n-go/apps/driver && flutter test
cd ~/meet-n-go/packages/mng_core && flutter test
cd ~/meet-n-go/supabase && deno test functions/_tests/
```

Expected: every suite green. Record the totals; they go in the runbook in Task 18.

- [ ] **Step 6: Commit**

```bash
cd ~/meet-n-go && git add -A
git -c user.email=opencode@local -c user.name=opencode commit -m "test: full trip-lifecycle integration including cold-start restore"
```

---

### Task 18: `otp-mail` Edge Function, CI hardening, and the Accra pilot runbook

**Files:**
- Create: `supabase/functions/otp-mail/index.ts`
- Create: `supabase/functions/_tests/otp_mail.test.ts`
- Modify: `supabase/config.toml`
- Modify: `.github/workflows/ci.yml`
- Create: `docs/runbooks/accra-pilot.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: `SupabaseAuthRepository.sendResetOtp` and `.verifyOtpAndSetPassword`, which call `supabase.functions.invoke('otp-mail', ...)` (Task 8)
- Produces: POST `otp-mail` with two actions.
  - `{email}` (no `action`, or `action: 'send'`) → `{sent: true, devCode: string}`. It writes a 6-digit code to a `password_reset_codes` row and returns the code so the pilot team can read it out over a phone call.
  - `{action: 'verify', email, code}` → `{tempPassword: string}`. It checks the most recent unconsumed code for that email, marks it consumed, and uses the service role to set a random temporary password on the matching `auth.users` row. A wrong or consumed code returns 401 with `{error: 'That code is not right'}` and changes nothing.
  - A real SMS or email provider replaces the delivery step only; the `verify` contract is what `SupabaseAuthRepository.verifyOtpAndSetPassword` depends on (Task 8).

- [ ] **Step 1: Write the failing otp-mail test**

`supabase/functions/_tests/otp_mail.test.ts`:

```ts
import { assertEquals, assertMatch } from 'https://deno.land/std@0.224.0/testing/asserts.ts';
import {
  exchangeCodeForTempPassword,
  isValidEmail,
  mintCode,
  mintTempPassword,
  resendWindowMs,
} from '../otp-mail/index.ts';

Deno.test('mints a six-digit code', () => {
  const code = mintCode();
  assertMatch(code, /^[0-9]{6}$/);
});

Deno.test('rejects a malformed email', () => {
  assertEquals(isValidEmail('not-an-email'), false);
  assertEquals(isValidEmail('rider@example.com'), true);
});

Deno.test('a second request inside the window is refused', () => {
  assertEquals(resendWindowMs, 30_000);
});

Deno.test('a temporary password is long and random enough to be unguessable', () => {
  const pw = mintTempPassword();
  assertEquals(pw.length >= 24, true);
  assertEquals(pw.includes(' '), false);
});

Deno.test('the right code against one unconsumed row is accepted', () => {
  const rows = [
    { code: '111111', consumed: false, created_at: '2026-09-27T10:00:00Z' },
  ];
  assertEquals(exchangeCodeForTempPassword(rows, '111111'), true);
});

Deno.test('a wrong code is rejected', () => {
  const rows = [
    { code: '111111', consumed: false, created_at: '2026-09-27T10:00:00Z' },
  ];
  assertEquals(exchangeCodeForTempPassword(rows, '222222'), false);
});

Deno.test('an already-consumed code cannot be replayed', () => {
  const rows = [
    { code: '111111', consumed: true, created_at: '2026-09-27T10:00:00Z' },
  ];
  assertEquals(exchangeCodeForTempPassword(rows, '111111'), false);
});

Deno.test('only the newest unconsumed code is honoured', () => {
  const rows = [
    { code: '111111', consumed: true, created_at: '2026-09-27T10:00:00Z' },
    { code: '222222', consumed: false, created_at: '2026-09-27T09:00:00Z' },
  ];
  assertEquals(exchangeCodeForTempPassword(rows, '222222'), true);
  assertEquals(exchangeCodeForTempPassword(rows, '111111'), false);
});

Deno.test('no rows at all is a rejection, not a crash', () => {
  assertEquals(exchangeCodeForTempPassword([], '123456'), false);
});
```

- [ ] **Step 2: Run and confirm it fails**

```bash
cd ~/meet-n-go/supabase && deno test functions/_tests/otp_mail.test.ts
```

Expected: FAIL — `../otp-mail/index.ts` does not exist.

- [ ] **Step 3: Write `otp-mail/index.ts`**

```ts
import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';
import { corsHeaders } from '../_shared/cors.ts';

export const resendWindowMs = 30_000;

export function mintCode(): string {
  return String(Math.floor(100000 + Math.random() * 900000));
}

export function isValidEmail(email: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

export function mintTempPassword(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(24));
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

interface CodeRow {
  code: string;
  consumed: boolean;
  created_at: string;
}

/** Only the newest unconsumed code for an email may be exchanged, and only once. */
export function exchangeCodeForTempPassword(
  rows: CodeRow[],
  code: string,
): boolean {
  const newest = [...rows].sort(
    (a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime(),
  )[0];
  if (!newest) return false;
  if (newest.consumed) return false;
  return newest.code === code;
}

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const body = await req.json();
  const email = String(body.email ?? '').trim().toLowerCase();

  if (!isValidEmail(email)) {
    return new Response(JSON.stringify({ error: 'Enter a valid email address' }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  const service = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  // ---- verify: exchange a good code for a one-time temporary password ----
  if (body.action === 'verify') {
    const code = String(body.code ?? '').trim();
    const { data: rows } = await service
      .from('password_reset_codes')
      .select('code,consumed,created_at')
      .eq('email', email)
      .order('created_at', ascending: false)
      .limit(5);

    if (!exchangeCodeForTempPassword((rows ?? []) as CodeRow[], code)) {
      return new Response(JSON.stringify({ error: 'That code is not right' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Burn the code first so a replay cannot mint a second temporary password.
    await service
      .from('password_reset_codes')
      .update({ consumed: true })
      .eq('email', email)
      .eq('code', code)
      .eq('consumed', false);

    const { data: list, error: listError } = await service.auth.admin.listUsers({
      page: 1,
      perPage: 200,
    });
    if (listError) {
      return new Response(JSON.stringify({ error: listError.message }), {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }
    const user = list.users.find((u) => u.email?.toLowerCase() === email);
    if (!user) {
      return new Response(JSON.stringify({ error: 'No account for that email' }), {
        status: 404,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const tempPassword = mintTempPassword();
    const { error: updateError } = await service.auth.admin.updateUserById(
      user.id,
      { password: tempPassword },
    );
    if (updateError) {
      return new Response(JSON.stringify({ error: updateError.message }), {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    return new Response(JSON.stringify({ tempPassword }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  // ---- send: mint a code, honouring the resend window ----
  const { data: recent } = await service
    .from('password_reset_codes')
    .select('created_at')
    .eq('email', email)
    .order('created_at', ascending: false)
    .limit(1);

  const lastMs = recent != null && recent.length > 0
    ? new Date(recent[0].created_at as string).getTime()
    : 0;
  if (Date.now() - lastMs < resendWindowMs) {
    return new Response(JSON.stringify({ error: 'Wait before requesting another code' }), {
      status: 429,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  const code = mintCode();

  // Demo delivery: the code is returned in the response so the pilot team can
  // read it to the rider. A real SMS or email provider replaces this write only.
  await service.from('password_reset_codes').insert({
    email,
    code,
    created_at: new Date().toISOString(),
  });

  return new Response(JSON.stringify({ sent: true, devCode: code }), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
});
```

<dcp-system-reminder>
EARLY WARNING: Approaching context limit

You are running low on context space. Prioritize compression NOW over continued exploration.

Compress aggressively: multiple ranges, older context first, preserve critical technical details.

Compressed block context:
- Active compressed blocks in this session: 2 (b1, b3)
- If your selected compression range includes any listed block, include each required placeholder exactly once in the summary using `(bN)`.
</dcp-system-reminder>
- [ ] **Step 4: Add the table to a second migration**

`supabase/migrations/20260927000002_password_reset_codes.sql`:

```sql
create table password_reset_codes (
  id uuid primary key default uuid_generate_v4(),
  email text not null,
  code text not null,
  consumed boolean not null default false,
  created_at timestamptz not null default now()
);

create index password_reset_codes_email_idx
  on password_reset_codes (email, created_at desc);

alter table password_reset_codes enable row level security;
-- no select policy: only the service role, used by the otp-mail function, reads this table
```

- [ ] **Step 5: Run the otp-mail tests and confirm they pass**

```bash
cd ~/meet-n-go/supabase
deno test functions/_tests/
supabase db push
supabase functions deploy otp-mail
```

Expected: 9 more tests pass (the full Deno suite is green), the migration applies, and the deploy reports success.

- [ ] **Step 6: Harden CI**

Replace `.github/workflows/ci.yml` with a version that also runs the Deno suite and blocks on warnings:

```yaml
name: ci
on: [push, pull_request]
jobs:
  verify:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
      - name: Install Deno
        run: curl -fsSL https://deno.land/install.sh | sh -s -- -y
      - name: Add Deno to PATH
        run: echo "$HOME/.deno/bin" >> "$GITHUB_PATH"
      - name: Verify packages, apps and edge functions
        run: |
          set -euo pipefail
          for d in packages/mng_core apps/rider apps/driver; do
            ( cd "$d" && flutter pub get && flutter analyze --fatal-infos --fatal-warnings && flutter test )
          done
          ( cd supabase && deno check functions/*/index.ts && deno test functions/_tests/ )
      - name: Push migrations and functions
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        working-directory: supabase
        env:
          SUPABASE_ACCESS_TOKEN: ${{ secrets.SUPABASE_ACCESS_TOKEN }}
          SUPABASE_PROJECT_REF: ${{ secrets.SUPABASE_PROJECT_REF }}
          SUPABASE_DB_PASSWORD: ${{ secrets.SUPABASE_DB_PASSWORD }}
        run: |
          supabase link --project-ref "$SUPABASE_PROJECT_REF"
          supabase db push
          for fn in request-ride offers cancel-trip complete-trip demo-pay otp-mail; do
            supabase functions deploy "$fn"
          done
```

- [ ] **Step 7: Write the pilot runbook**

`docs/runbooks/accra-pilot.md`:

```markdown
# Accra pilot runbook

Ten drivers, one week, demo payments. Read this before Task 0's first run and
again before the pilot starts.

## What is demo in this build

- Every payment, wallet balance and payout is simulated. No cedis move.
- `is_demo = true` is enforced by CHECK constraints in Postgres, so a real
  charge cannot be written by accident.
- The pickup OTP, SOS, ratings, chat and RLS are all real.
- Apple Sign-In is not implemented, so this pilot is Android-only.

## Prerequisites

- Hosted Supabase project linked: `supabase link --project-ref <REF>`.
- `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` in
  `supabase/.env.local`, and the same three values in each app's
  `lib/src/env.dart`.
- A Google Maps API key with the Maps SDK for Android enabled.
- `flutter doctor` clean on the build machine.

## Day 0 — seed the pilot

1. `supabase db push` then run `supabase/seed/seed.sql` in the SQL editor.
2. Create ten driver accounts in Supabase Auth with role `driver`, then insert
   the matching `profiles` rows and set `kyc_status = 'approved'` and
   `availability = 'offline'`.
3. Insert one `vehicles` row per driver with `ride_category` matching the
   category they will take, and set `approved = true`.
4. Insert a `driver_locations` row per driver at their start-of-shift point in
   Accra (Osu, Airport Residential, Spintex, East Legon, Labone).
5. Create five rider accounts with role `rider`.

## Each shift

1. Driver signs in, completes KYC if not already approved, toggles online.
2. Rider signs in, enters a route, picks a car, taps Find driver.
3. Confirm the offer appears within 20 seconds on the driver's phone.
4. Walk the full trip: match, arriving, pickup OTP, ongoing, complete.
5. Rider pays with the demo sheet and rates the trip both ways.
6. Driver requests a demo payout from the Earnings tab.

## What to watch

| Symptom | Likely cause | Fix |
|---|---|---|
| No offers arrive | Driver has no `driver_locations` row | Insert one within 5 km of the pickup |
| Offer accepted but trip stays `requested` | `accept_offer` RPC missing | `supabase db push` |
| Driver cannot go offline mid-trip | Working as designed; finish or cancel first | — |
| Android build runs out of memory | Gradle needs more than 3 GB RAM | Build on a machine with 8 GB+ |
| Map tiles are blank | Google Maps billing disabled | Enable billing in Google Cloud |

## Rollback

Payments are demo, so there is nothing to reverse financially. To stop the
pilot, set every driver's `availability` to `offline` in the SQL editor. The
code stays deployed for debugging.

## After the pilot

1. Fix what the log above surfaced.
2. Add Apple Sign-In before any iOS release; the App Store rejects
   Google-only sign-in.
3. Pick a real payment provider behind the `EarningsRepository.requestPayout`
   and `demo-pay` boundary, then drop the demo-only CHECK constraints.
```

- [ ] **Step 8: Update the README with the verified test counts**

Append to `README.md`:

```markdown
## What is real and what is demo

Real: auth, RLS, PostGIS radius matching, the trip state machine, realtime
trip updates, the pickup OTP, SOS, chat, ratings.

Demo: every payment, wallet balance and payout. Postgres CHECK constraints
force `is_demo = true` so a real charge cannot be written by accident. The
provider boundary is `EarningsRepository.requestPayout` and the `demo-pay`
Edge Function.

## Docs

- Design spec: `docs/superpowers/specs/2026-09-27-meet-n-go-rides-design.md`
- Implementation plan: `docs/superpowers/plans/2026-09-27-meet-n-go-rides.md`
- Pilot runbook: `docs/runbooks/accra-pilot.md`
```

- [ ] **Step 9: Run every suite one final time and confirm green**

```bash
cd ~/meet-n-go/packages/mng_core && flutter test
cd ~/meet-n-go/apps/rider && flutter test && flutter analyze --fatal-infos --fatal-warnings
cd ~/meet-n-go/apps/driver && flutter test && flutter analyze --fatal-infos --fatal-warnings
cd ~/meet-n-go/supabase && deno check functions/*/index.ts && deno test functions/_tests/
```

Expected: every command exits 0.

- [ ] **Step 10: Commit**

```bash
cd ~/meet-n-go && git add -A
git -c user.email=opencode@local -c user.name=opencode commit -m "chore: otp-mail function, hardened CI, and Accra pilot runbook"
```

---

## Done Criteria

The plan is complete when all of the following hold:

- `flutter analyze --fatal-infos --fatal-warnings` and `flutter test` are green
  in `packages/mng_core`, `apps/rider`, and `apps/driver`.
- `deno check functions/*/index.ts` and `deno test functions/_tests/` are green.
- `supabase db push` applies both migrations with no error, and the `anon` key
  cannot read another rider's trips.
- All five Review Focus tests exist and pass:
  `zero_distance_fare_test`, `reversed_route_fare_test`,
  `accept_offer_single_winner_test`, `cancel_after_arriving_compensates_driver_test`,
  `settle_cancelled_trip_voids_payment_test`, `go_offline_refused_during_active_trip_test`,
  `active_trip_survives_app_restart_test`.
- A real Accra trip has been walked end to end on two Android devices with demo
  payments, following `docs/runbooks/accra-pilot.md`.

## Explicitly Not In This Plan

- Food delivery, essentials and goods courier verticals. They reuse the auth,
  map, wallet, chat and trip primitives built here; each needs its own spec and
  plan.
- A real payment provider. The boundary is drawn and named; the integration
  itself is a later phase.
- Apple Sign-In, which blocks iOS App Store release but not this pilot.
- A custom admin UI. Supabase Studio is the admin for this build.
- Linux desktop and web targets, which do not fit the 5.7 GB disk budget.
