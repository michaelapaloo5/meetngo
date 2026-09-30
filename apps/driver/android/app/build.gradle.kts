plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "gh.meetngo.meetngo_driver"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "gh.meetngo.meetngo_driver"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")

            // proguard-rules.pro and nothing else.
            //
            // The project's own rules are added to the library consumer rules
            // the Flutter plugin already contributes, rather than replacing them.
            // The file is here for one reason, which is that ML Kit's text
            // plugin references the Chinese, Devanagari, Japanese and Korean
            // recognisers and only the Latin model is on the classpath, so R8
            // stops the release build with:
            //
            //   Missing class com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions$Builder
            //
            // The Android default file is deliberately *not* named here. Naming
            // it would switch on shrinking options that were not on before this,
            // which is a different change and a bigger risk than the one being
            // fixed. See the file itself for the rules, and why -dontwarn is
            // right rather than four language dependencies.
            proguardFiles("proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// No dependencies block, and that is the change.
//
// `com.google.mlkit:face-detection:16.1.7` was declared here so that
// LivenessChannel.kt could call ML Kit's native API without going through the
// community plugin. It does not any more. ML Kit is out of this app entirely:
// face detection is MediaPipe on LiteRT via `face_detection_tflite`, and the
// anti-spoof model is MiniFASNet as a TFLite asset, so both arrive through the
// plugin's bundled native runtime.
//
// The APK is about 28 MB smaller for it, which is the other reason this is an
// improvement rather than a workaround: ML Kit's bundled detector was most of
// the driver's download and every byte of it was unusable.
