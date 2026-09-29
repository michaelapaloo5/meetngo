# Handoff — pick up here on a bigger machine

Written at the end of a session on a **2.7 GB / 40 MB-free / no-swap** box. The
work is committed and pushed. Everything below is verified or explicitly
flagged as not.

**HEAD is `ea81783`. Clone the repo and start there.** Do not try to move the
old chat — it is 1000+ messages and mostly compressed.

---

## 1. Start here — the user works on **Windows**

```powershell
git config --system core.longpaths true     # required, Flutter paths exceed 260 chars
git clone https://github.com/michaelapaloo5/meetngo.git
cd meetngo
git checkout feature/rides-marketplace
```

Then read this file and `RUNBOOK.md` (deploy + phone-test instructions).

### What Windows changes, and what it does not

**You do not need to build the APKs locally.** `codemagic.yaml` is a cloud
build: it runs on Codemagic's Linux machines and produces both APKs. You trigger
it by pushing to the branch or by pressing rebuild in the Codemagic dashboard.
Nothing about the build needs a local toolchain, a JDK, or an Android SDK. This
is deliberate — GitHub Actions is blocked by a billing lock on that account, and
Codemagic's free tier asks for no payment method.

**To run the test suites locally you need Flutter on Windows:**
install Flutter, ensure `flutter` is on `PATH` in PowerShell, and run
`flutter doctor`. Only the Flutter SDK and Git are needed — not the Android SDK,
because Codemagic does the compiling.

```powershell
cd apps\rider
flutter pub get
flutter analyze --fatal-infos
flutter test
cd ..\driver
flutter pub get
flutter analyze --fatal-infos
flutter test
```

**iOS cannot be built on Windows at all** — it needs macOS. Only Android is
buildable here, which is what the pilot needs (a Samsung S10 Lite).

**`push-to-github.sh` will not run** in PowerShell; it is a convenience helper
from the Linux session. Use ordinary `git push`, or the GitHub Desktop client.
Everything else in the repo is cross-platform.

**Every suite in the CI `verify` job is green as of the first run on Windows.**
`deno test` passes 225 Edge Function tests, and `flutter analyze --fatal-infos`
and `flutter test` pass for `packages\mng_core` (48 tests), `apps/rider` (144)
and `apps/driver` (217). Thirty-one genuine Dart failures were fixed; see §5.
The Deno suite needed no fixes — it had never failed.

---

## 2. What is real

- **Supabase is deployed and live.** Project `mkdbzddgafkqnejivikt`, region
  eu-west-1. Schema, RLS and five Edge Functions are deployed. A full ride
  lifecycle was exercised against it end to end: request → offer → accept →
  arriving → ongoing → completed → settle, with the ledger and payout verified
  to balance in the real database.
- **Accounts exist:** `rider@meetngo.app` and `driver@meetngo.app`, password
  `Meetngo2026`.
- **A pilot driver is seeded** (`supabase/seed/pilot_driver.sql`) — approved
  driver, approved vehicle, a position at Osu. Without this no ride can happen:
  the database refuses to let a client set `role`, `kyc_status` or approve a
  vehicle, by design. An admin must do it through SQL.
- **Sign-up now saves the name.** Migration
  `20260928000001_persist_signup_name.sql` is applied live. Verified on real
  Postgres: the name persists, and a hostile `{"role":"admin"}` signup payload
  is still clamped to a rider.
- **Maps are real.** `flutter_map` with OpenStreetMap raster tiles, no API key
  and no billing. Tile endpoint returns HTTP 200 from this host. Pickup and
  dropoff pins plus a polyline on the rider's tracking screen; driver position
  and pickup on the driver's active-trip screen.
- **Location is real.** `geolocator` with runtime permission handling.
- **The tabs are built.** The "Not built yet" placeholder is gone from both
  apps. Rider: Home, Bookings, Chat, Profile. Driver: Drivers, Trips, Earnings,
  Profile. Driver sign-up exists.
- **Animations:** amber brand splash on launch, staggered entrance on login and
  sign-up.
- **Both release manifests have `INTERNET`.** This was a real bug: Flutter's
  template puts it only in the `debug` and `profile` manifests, so the shipped
  APK could not resolve any hostname and every call died with
  `Failed host lookup ... errno = 7`.

## 3. What is still demo, and cannot be otherwise

**Payments are fake, and this is not fixable in code.** Taking real money needs a
payment provider merchant account: a registered business, a bank account, and
identity checks with that provider. The user has stated they are not spending
money. `demo-pay` and the settlement flow are honest simulations. The provider
interface is the seam a real one drops into.

Everything else was made real.

## 4. Known gaps

- **Every test suite now runs and passes on this branch** — see §5. The Dart
  suites (`mng_core` 48, `rider` 144, `driver` 217) and the Deno Edge Function
  suite (225) are all green, so the whole `verify` job in CI is accounted for
  locally for the first time.
- **The deployed HTTP round trip for the Edge Functions has never been run
  against a live project** with a real phone. First thing a pilot does; it is in
  `RUNBOOK.md`.
- **`otp-mail` is not written.** The password-reset screens are built and
  compile, but sending a code will fail.
- **The driver onboarding is a stub.** Ghana Card OCR and selfie liveness are
  placeholders behind a `DocumentScanner` interface; the real capture is not
  wired.
- **Android/iOS release builds were never produced from this branch.** Codemagic
  builds them; the last successful build was before `ea81783`.
- `requestPayout` in the driver wallet moves no money and writes nothing — a
  withdrawal applies to the session balance only. The screen says so. This is
  the most likely thing to be mistaken for real when demonstrating.

## 5. The tests, run for the first time

They were not run before because the dev box was Linux with 2.7 GB RAM, ~40 MB
free and **no swap**; `flutter test` on more than one file OOM-killed the
terminal, and that virtual disk rejects `swapon` with `Invalid argument`. This
machine has 7.7 GB and 216 GB free, so they ran in full.

**First run: 31 failures out of 409 Dart tests. All fixed; all three packages
now pass `flutter analyze --fatal-infos` and `flutter test`.** The counts now
are `mng_core` 48, `rider` 144, `driver` 217. The Deno Edge Function suite ran
clean on its first and only attempt: **225 passed, 0 failed**, no fixes needed.

### The four that were worth the run

**28 of the 31 were one bug in the rider's map.** `flutter_map`'s
`SimpleAttributionWidget` lays its credit out as a `Row(mainAxisSize: min)`
holding the fixed string `'flutter_map | © '` beside the source text. Two
unshrinkable runs do not fit the map panel at 200% text scale — the rider's own
accessibility test put it **255px past a 344px panel** — and every widget test
that rendered a `RideMap` failed on the resulting `RenderFlex overflowed`
instead of on what it was testing. `apps/rider/lib/src/map/ride_map.dart` now
draws the credit itself, as a wrapping `Text` in a `Positioned`, exactly as
`DriverMapPanel` already did. The driver's own map never had this bug, which is
why only the rider broke.

Related, and the second half of that fix: the rider had **no tile-provider test
seam**. `RideMap` took a `tileProvider` argument, but all three screens that
build a map construct it themselves, so no test could reach that argument and
every map test went to the network and got `flutter_test`'s empty 400. Added
`RideMap.tileProviderOverride`, mirroring `DriverMapPanel.tileProviderOverride`.

**One test asserted a bug.** `home_screen_test.dart` demanded *no*
`Icons.directions_car` anywhere on the home screen, to prove the old hard-coded
vehicle list was gone. But `CategoryChips` gives `RideCategory.standard` a car,
`premium` a sparkle and `van` a shuttle — so the assertion forbade a correct
control. Scoped to the Standard chip, and pinned to exactly one car icon, which
is what a restored four-car list would break.

**One test was wrong about the clock.** `offer_queue_test.dart` asserted a fresh
20-second offer reads `19`, reasoning that the two `DateTime.now()` calls are
"microseconds apart". On Windows they are not: the clock granularity is ~15.6 ms
and **1999 of 2000 consecutive pairs read identical**, so the difference is
exactly 20 s and truncation of 20.0 is 20. The production code was right. Now
pinned on 19.5 s and 1.5 s — off the boundary, so it still fails if a `.round()`
is ever added, with half a second of slack for any clock.

**One test fought its own overlay.** `active_trip_test.dart` tapped *Navigate*,
then *Call*, which share a row low on a 390x844 screen. The SnackBar from the
first tap is laid out over the bottom of the Scaffold, so the second tap hit
the SnackBar, Flutter warned the hit test missed, and the test failed on an
assertion about the second button. `pumpAndSettle` does not clear it — the
dismiss is a timer, not a frame — so the duration is now advanced past it
explicitly and the absence of a SnackBar is asserted before the second tap.

### Two test bugs found but not failures

`FakeTripRepository` in `tracking_screen_test.dart` declared `cancelCalls` and
never incremented it, so `expect(c.repo.cancelCalls, 0)` — the assertion that
proves the controller's own guard short-circuits before calling the function —
was vacuous. It now increments, and the success path asserts it reaches 1 so the
zero means something.

## 5a. Setting Flutter up on this machine

Flutter was **not** installed and had to be installed to run any of this.
`C:\dev\flutter`, and it is already on the user `PATH`.

- Flutter **3.47.5** stable, Dart 3.13.4. This is not an arbitrary choice: every
  `pubspec.yaml` pins `sdk: ^3.13.4`, which is exactly the bundled Dart, so the
  `pubspec.lock` files resolve untouched. A newer SDK would have been free to
  move versions underneath the tests.
- Two Windows-specific snags, both cost time:
  - `Expand-Archive` is unusably slow on a 1.8 GB archive — it had produced
    1,834 of ~19,000 files after two minutes of CPU. `tar -xf` is bundled with
    Windows and did the same job in **97 seconds**. Use `tar`, not
    `Expand-Archive`, for anything this size.
  - The first `flutter pub get` runs a one-time `pub cache preload` that pulls
    ~200 common packages. It looks like a hang; it is not. Wait it out.
- `.ps1` files will not run under the default execution policy. Use
    `powershell -NoProfile -ExecutionPolicy Bypass -File ...` per-process rather
  than loosening the machine's policy.
- **Deno 2.9.7** is at `C:\dev\deno`, on the user `PATH`, for the Edge Function
  tests. They are fast (2s) and need no network:

  ```powershell
  cd supabase
  deno test --allow-env --allow-read=functions/ functions/_tests/
  ```

  `225 passed | 0 failed`. The `--allow-read=functions/` is deliberate and
  scoped: `settlement_clients_wiring.test.ts` asserts over the *source text* of
  the `clients.ts` files, which the port-level tests cannot otherwise reach, so
  that one file is the only reason the flag is needed.

### Building the APKs on Windows

Both release APKs now build here, so Codemagic is no longer the only route. This
is what it took, and two of the four items are **hard requirements** that will
bite any machine or cloud runner that does not have them:

```powershell
$env:JAVA_HOME='C:\dev\jdk21\jdk-21.0.12.1+1'   # JDK 21, see below
cd apps\rider
flutter build apk --release --target-platform android-arm64,android-x64 `
  -Dorg.gradle.jvmargs=-Xmx2560m -XX:MaxMetaspaceSize=768m
```

- **JDK 21 is required, not preferred.** `maplibre_gl` 0.27.1 sets
  `sourceCompatibility`/`targetCompatibility` to `VERSION_21` in its own
  `android/build.gradle`. On JDK 17 the build dies in
  `:maplibre_gl:compileReleaseJavaWithJavac` with
  `error: invalid source release: 21`. Installed at `C:\dev\jdk21`.
- **`--target-platform android-arm64,android-x64` is required.** 32-bit arm is
  broken: `gen_snapshot` for `armeabi-v7a` exits 255 after about ten minutes,
  reporting `Unable to read file: app.dill` for a file that exists and is
  readable. It is the only invocation that passes the legacy
  `--no-sim-use-hardfp --no-use-integer-division` flags; arm64 and x86_64 both
  produce `app.so` cleanly. **A default `flutter build apk` still tries
  `armeabi-v7a` and fails**, so this flag is needed in `codemagic.yaml` and
  `.github/workflows/ci.yml` too, not just locally. The APKs therefore carry no
  32-bit Dart code and will not install on a 32-bit-only device; the S10 Lite is
  arm64.
- **`org.gradle.jvmargs` needs overriding on a small machine.** The repo's
  `android/gradle.properties` asks for `-Xmx8G`, more than this box's entire
  7.7 GB. The Dart AOT compiler runs as a separate process and was starved
  into dying silently. Passed on the command line rather than edited into the
  repo, so cloud runners are unaffected — but it is a latent footgun.
- Android SDK 36 at `C:\dev\android-sdk`: platform-tools, `platforms;android-36`,
  `build-tools;36.0.0`, and `ndk;28.2.13676358`. The NDK version is
  `maplibre_gl`'s own pin, not a free choice. `flutter doctor` reports the
  Android toolchain clean.
- The Gradle wrapper's own downloader **stalls at 0 bytes** on the
  `services.gradle.org` redirect. Every other large download worked, so it is
  the wrapper rather than the network: fetch `gradle-<v>-all.zip` with
  `Invoke-WebRequest` into `~/.gradle/wrapper/dists/<name>/<hash>/` by hand and
  the build proceeds.

Verified in the built artifacts rather than from the build's exit code:
`libmaplibre.so` present for all three ABIs, and
`android.permission.INTERNET` present in the release manifest.

## 6. Traps that will bite you

These cost real time in this build. All verified, not assumed.

- **The 3D map is not covered by the test suite, and cannot be.** MapLibre draws
  through a native platform view; under `flutter test` there is no platform view
  to create, so the widget cannot be built at all. The old `flutter_map` version
  *could* be rendered in a test with only its tile source swapped, so every test
  that rendered a screen also exercised that screen's map. `disabledForTest` now
  substitutes an empty box. This is a real loss of coverage, taken knowingly to
  get 3D without a billing account, and the map is verified by compiling and by
  looking at it on a phone instead.
- **Only the `liberty` OpenFreeMap style has 3D buildings.** Measured against
  all three the service publishes: `liberty` has one `fill-extrusion` layer over
  the `building` source-layer, `positron` and `bright` have **zero**. Swapping
  to either for aesthetics silently flattens the map back to 2D.
- **A style filter is a raw list, not a typed object.** `maplibre_gl`'s `filter`
  parameter is `dynamic` and `LineLayerProperties.lineCap`/`lineJoin` are
  `dynamic` too, so they take the style's own string values (`'round'`) and a
  bare expression list (`['==', ['get', 'role'], 'pickup']`). There is no
  `PropertyValueExpression` class and no `LineCap` enum.

- **`postgrest 2.9.1`:** `PostgrestBuilder implements Future<T>` and has **no
  `data` and no `error`**. Awaiting yields the **rows**; failure **throws**.
  `final res = await ...; res.data` does not compile. This appeared 24 times in
  the old plan.
- **`select()` returns `PostgrestFilterBuilder<PostgrestList>`**, so casting the
  result is `unnecessary_cast` — **fatal** under `--fatal-infos`.
- The filter is **`inFilter`**, never `in` (a Dart keyword).
- A zero-row **`.single()` throws**, so a 404 branch under it is unreachable.
- **Deno Edge Functions have no persisted session.** `getUser()` with no
  argument returns `Auth session missing!`. Strip the `Bearer ` scheme and pass
  the token. PostgREST requires the scheme word, so a bare token yields an empty
  token on a PostgREST port.
- **`serve()` at module scope makes a file unimportable**, so a handler cannot be
  unit-tested. Every function here is split as `handler.ts` (pure, port-injected)
  + `clients.ts` (Supabase) + a one-line `index.ts`.
- **`ledger_entries.driver_id` is `not null`** and the platform has no account of
  its own, so a commission is a negative entry against the driver. The fare entry
  is the **gross**; the commission entry is `-(fare - payout)`, derived from the
  payout so the sum holds by construction. Do not "tidy" this.
- **`vehicles` update policies carry `approved = false` in the WITH CHECK**, and
  the check runs on the new row — so resending `approved: false` on a plate
  correction against an approved vehicle **silently de-approves it**. Send a
  partial update omitting `approved`.
- **`TripStop` has no `operator ==`.** Assert on `.address`/`.point` in tests,
  never on a `TripStop` instance.
- **Widget tests need the design surface** or ScreenUtil sizes are wrong and rows
  overflow: `tester.view.physicalSize = Size(1170, 2532)`,
  `tester.view.devicePixelRatio = 3.0`.
- **`DateTime.now()` on Windows has ~15.6 ms granularity**, so two consecutive
  calls return the *same* instant — measured 1999/2000 pairs identical. Never
  write a test that depends on a few microseconds having elapsed between
  constructing a fixture and reading a clock off it.
- **A `SnackBar` absorbs taps aimed at whatever is under it.** Two buttons low
  on a 390x844 screen, the first of which opens a SnackBar, means the second is
  not tappable until that SnackBar is gone. `pumpAndSettle` will not clear it:
  the dismiss is a timer, not a frame. Advance the duration explicitly.
- `unnecessary_underscores` is on and CI uses `--fatal-infos`: `(_, _)`, never
  `(_, __)`.
- There is **no formatting standard** in this repo and no `dart format` step in
  CI. Do not add one.

## 7. Secrets

These were pasted in chat and **must be deleted**:
- a Supabase personal access token (`sbp_...`)
- a GitHub personal access token (`ghp_...`)

They are stored locally at `~/.config/meetngo/` (mode 600). Rotate or revoke both.

The Supabase **anon** key is safe to ship inside the APK and is already baked
into the build. It is a publishable/anon credential by design.
