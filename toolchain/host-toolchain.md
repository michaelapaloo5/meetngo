# Host C/C++ toolchain for native assets
#
# `face_detection_tflite` depends on `opencv_dart`, which ships a Dart native
# asset hook. That hook compiles OpenCV with CMake + Ninja + a C/C++ compiler,
# and it runs on the *host* during both `flutter test` and
# `flutter build apk` -- not only for Android. So all three tools have to exist
# on this machine or nothing builds, and the failure is a bare "Failed to find
# ninja with version=latest" with no hint that the package graph is the reason.
#
# None of this is in the repo. Each piece is a portable directory under C:\dev
# with no installer and no admin rights:
#
#   C:\dev\cmake-3.31.6-windows-x86_64   cmake.org, official Windows zip
#   C:\dev\ninja                        ninja-build releases, ninja-win.zip
#   C:\dev\llvm19                       llvm-project releases, LLVM-19.1.7-win64.exe
#                                       run with /S /D= to extract without installing
#   C:\dev\7zip\7zr.exe                 7-zip.org standalone extractor, used only
#                                       to unpack the LLVM installer
#
# `C:\dev\jdk21` and `C:\dev\android-sdk` are the other two, and the NDK under
# the SDK is what cross-compiles the Android side of the same hook.
#
# To use them, put all four bin directories on PATH and point the compiler at
# clang:
#
#   $env:Path = "C:\dev\cmake-3.31.6-windows-x86_64\bin;" +
#               "C:\dev\ninja;" +
#               "C:\dev\llvm19\bin;" + $env:Path
#   $env:CC  = "C:\dev\llvm19\bin\clang.exe"
#   $env:CXX = "C:\dev\llvm19\bin\clang++.exe"
#
# `build-driver.ps1` sets these. Without the two env vars cmake finds no
# compiler at all and reports "CMAKE_C_COMPILER not set, after EnableLanguage",
# which is the same error you get on a machine with no Visual Studio.
#
# This file exists because a build that fails for a missing build tool should
# cost one read of a README rather than an afternoon. It is the third time a
# missing-toolchain failure in this project looked like a code problem.
