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
