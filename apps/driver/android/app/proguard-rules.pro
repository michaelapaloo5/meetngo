# Release shrinking rules, and the only reason this file exists.
#
# ## ML Kit's optional language models
#
# `google_mlkit_text_recognition` references the Chinese, Devanagari, Japanese and
# Korean recognisers from its own code. Only the Latin model is on the classpath
# -- a Ghana Card is printed in English, and the four language packages are
# several megabytes each that a driver would download and never use -- so R8
# reports those classes as missing and the release build fails at
# `minifyReleaseWithR8` with:
#
#   Missing class com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions$Builder
#
# `-dontwarn` is the right answer rather than adding the four dependencies. The
# code that touches them is only reached when a recogniser for that script is
# constructed, and this app only ever constructs the Latin one.
-dontwarn com.google.mlkit.**

# The Latin path must survive, and the two rules below are the ones ML Kit's own
# documentation gives. `TextRecognizer` is built and its result passed across the
# plugin boundary by name, so R8 cannot see the call and would otherwise strip or
# rename the members the channel invokes.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_text** { *; }
-keep class com.google.android.gms.internal.mlkit_common** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common** { *; }
