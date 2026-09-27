# Meet 'N Go — Rides

Rider app, driver app, Supabase backend. Demo payments only.

## Host budget (measured 2026-09-27)

| Resource | Available | Consequence |
|---|---|---|
| Free RAM | ~322 MB | Gradle and `assembleAndroid` will OOM. `flutter test` (Dart VM) is the verification path. Android APK builds run on a bigger box. |
| Free disk | 2.7 GB free *after* SDK install (16 GB total, 84% used) | The Flutter SDK is 2.6 GB of that. There is no room for a Gradle cache. Reclaim targets if a later task needs space: `~/.gradle/caches` (838 MB), `~/flutter/bin/cache/artifacts` (913 MB), `~/.pub-cache` (170 MB). Never run `flutter precache --all`; `--android` only. No Linux desktop or web artifacts. |
| Docker | absent | No local Supabase stack. Use a hosted Supabase project. |
| OS | Linux | iOS cannot be compiled here. iOS code is written but not build-verified. |
| Android SDK | platform `android-34`, build-tools `34.0.0`, JDK 21 | Present but *not* matched to Flutter 3.47: the toolchain pins `compileSdk = flutter.compileSdkVersion`, which is 36 in this version, and `android-36` is not installed. An Android build would fail on the missing platform as well as on RAM. Never build Android here. |

## Setup

```bash
git clone --depth 1 -b stable https://github.com/flutter/flutter.git "$HOME/flutter"
curl -sSfL https://github.com/supabase/cli/releases/latest/download/supabase_linux_amd64.tar.gz \
  | tar -xz -C "$HOME/.local/bin"
curl -fsSL https://deno.land/install.sh | sh
export PATH="$HOME/flutter/bin:$HOME/.local/bin:$HOME/.deno/bin:$PATH"
flutter config --no-analytics
flutter precache --android
```

PATH is set in the same shell, and must be re-exported in every new shell — it does not persist between tool calls.

Supabase is installed as a single self-contained binary at `~/.local/bin/supabase` rather than via `npm install -g supabase`. The npm route pulls a large transitive dependency tree, which does not fit the 2.7 GB of free disk above. The binary is the same version `npm` would install.

Deno's installer puts it in `~/.deno/bin`; that is why both `$HOME/.local/bin` and `$HOME/.deno/bin` are on PATH.

## Screenutil is pinned to 5.x

Both apps depend on `flutter_screenutil: ^5.9.3`. The original plan called for `^2.1.0`, but every 2.x release predates null safety, so that constraint cannot resolve on Dart 3.13.4. The 5.x line is a rewrite, so verify API use against the installed source at `~/.pub-cache/hosted/pub.dev/flutter_screenutil-5.9.3/` rather than assuming 2.x behaviour.

Facts verified against the installed 5.9.3 source:

- `ScreenUtilInit` exists and is a `StatefulWidget` (`lib/src/screenutil_init.dart:65`). It is the recommended bootstrap: wrap the app and pass `designSize`.
  ```dart
  ScreenUtilInit(
    designSize: const Size(375, 812),
    builder: (context, child) => child!,
  )
  ```
- `ScreenUtil.init(context, designSize: ...)` **still exists** in 5.9.3 (`lib/src/screen_util.dart:151`) with the same positional `context` and named `designSize`. 2.x-style bootstrap calls still compile. It is not the 2.x API being removed.
- `ScreenUtil().setWidth(...)`, `.setHeight(...)` and `.setSp(...)` are instance methods on `ScreenUtil()` and work as in 2.x.
- The `.w`, `.h`, `.r`, `.dg`, `.dm` and `.sp` getters on `num` come from the `SizeExtension` in `lib/src/size_extension.dart`, which the package barrel exports. `24.w` and `16.h` still work.
- **`.sm` is deprecated** in 5.x and annotated `@Deprecated('use spMin instead')`. Use `.spMin`. This is the change most likely to bite, because 2.x code uses `.sm` freely.
- `EdgeInsets`, `BorderRadius`, `Radius` and `BoxConstraints` each have their own `w`/`h`/`r` extension in 5.x, so `padding.w` and `radius.h` compile.

## Verify

```bash
flutter --version
supabase --version
deno --version
(cd packages/mng_core && flutter test)
(cd apps/rider && flutter test)
(cd apps/driver && flutter test)
```
