#!/bin/sh

# Xcode Cloud post-clone bootstrap for this Flutter app.
#
# Xcode Cloud gives us a macOS image with Xcode + CocoaPods, but NOT Flutter.
# It runs this script right after cloning the repo and BEFORE resolving
# dependencies / running xcodebuild, so this is where we install Flutter and
# generate everything the CocoaPods + xcodebuild steps rely on:
#   1. install a pinned Flutter SDK (same version as .github CI: 3.44.0)
#   2. precache the iOS engine artifacts
#   3. `flutter pub get`
#   4. `flutter build ios --config-only` — writes ios/Flutter/Generated.xcconfig
#      (Podfile hard-requires it; see ios/Podfile `flutter_root`)
#   5. `pod install`
#
# Apple runs ci_scripts from its own directory, so we always cd to the repo
# root via $CI_PRIMARY_REPOSITORY_PATH (set by Xcode Cloud).
#
# See ios/ci_scripts/README.md for the App Store Connect workflow setup that
# must accompany this script.

set -e

# Keep in lockstep with .github/workflows/*.yml (flutter-version: '3.44.0').
FLUTTER_VERSION="3.44.0"
FLUTTER_HOME="$HOME/flutter"

echo "▸ Installing Flutter $FLUTTER_VERSION"
if [ ! -d "$FLUTTER_HOME" ]; then
  git clone https://github.com/flutter/flutter.git \
    --depth 1 --branch "$FLUTTER_VERSION" "$FLUTTER_HOME"
fi
export PATH="$FLUTTER_HOME/bin:$PATH"

# Xcode Cloud clones into a shallow, non-owned dir; mark it safe so git (which
# Flutter shells out to) doesn't refuse "dubious ownership".
git config --global --add safe.directory "$FLUTTER_HOME"

flutter --version

echo "▸ Precaching iOS artifacts"
flutter precache --ios

echo "▸ Resolving Dart dependencies"
cd "$CI_PRIMARY_REPOSITORY_PATH"
flutter pub get

# Generate ios/Flutter/Generated.xcconfig (FLUTTER_ROOT etc.) without building —
# this is what the Podfile and the Xcode build settings read.
echo "▸ Generating iOS build configuration"
flutter build ios --config-only --release --no-codesign

echo "▸ Installing CocoaPods dependencies"
cd "$CI_PRIMARY_REPOSITORY_PATH/ios"
pod install

echo "✓ ci_post_clone complete"
