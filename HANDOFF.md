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

**These suites have never been run green on this branch.** `flutter analyze
--fatal-infos` is clean for both apps (that compiles the tests too, so they
compile). The tests themselves were written but **not executed** — see §5.

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

- **No tests have been run on this branch.** Highest-value first job.
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

## 5. Why tests were not run

The dev box was Linux with 2.7 GB RAM, ~40 MB free and **no swap**. Swap cannot
be added — that virtual disk rejects `swapon` with `Invalid argument`. Running
`flutter test` on more than one file at a time OOM-killed the terminal, and that
happened repeatedly. `flutter analyze --fatal-infos` is a single process and is
safe.

A Windows machine does not have that constraint. **Run the suites properly.**
Expect genuine failures: the new screen tests were written against a plan, not
against running output.

## 6. Traps that will bite you

These cost real time in this build. All verified, not assumed.

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
