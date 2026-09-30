#!/bin/sh
# Builds a universal (arm64 + x86_64) driver bundle.
# SIGN_IDENTITY: codesign identity; default "-" (ad hoc, local use only).
set -eu
cd "$(dirname "$0")/.."
SIGN_IDENTITY=${SIGN_IDENTITY:--}
DRIVER="$PWD/artifacts/MixotoAudio.driver"
mkdir -p "$DRIVER/Contents/MacOS" "$DRIVER/Contents/Resources"
xcrun clang -std=c11 -O2 -fblocks -fvisibility=hidden -bundle -arch arm64 -arch x86_64 \
  -mmacosx-version-min=15.0 -framework CoreAudio -framework CoreFoundation \
  Driver/MixotoDriver.c Driver/Loopback.c -o "$DRIVER/Contents/MacOS/MixotoAudio"
cp Driver/Info.plist "$DRIVER/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" "$DRIVER/Contents/Info.plist"
fi
cp Driver/AppleSample/LICENSE.txt "$DRIVER/Contents/Resources/AppleSample-LICENSE.txt"
set -- --force --sign "$SIGN_IDENTITY" --identifier io.coollabs.mixoto.audio
[ "$SIGN_IDENTITY" = - ] || set -- "$@" --options runtime --timestamp
codesign "$@" "$DRIVER"
codesign --verify --strict "$DRIVER"
plutil -lint "$DRIVER/Contents/Info.plist"
echo "Built: $DRIVER (not installed)"
