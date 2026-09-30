#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
DRIVER="$PWD/artifacts/MixotoAudio.driver"
mkdir -p "$DRIVER/Contents/MacOS" "$DRIVER/Contents/Resources"
rtk proxy xcrun clang -std=c11 -O2 -fblocks -fvisibility=hidden -bundle \
  -mmacosx-version-min=15.0 -framework CoreAudio -framework CoreFoundation \
  Driver/MixotoDriver.c Driver/Loopback.c -o "$DRIVER/Contents/MacOS/MixotoAudio"
cp Driver/Info.plist "$DRIVER/Contents/Info.plist"
cp Driver/AppleSample/LICENSE.txt "$DRIVER/Contents/Resources/AppleSample-LICENSE.txt"
rtk proxy codesign --force --sign - --identifier local.mixoto.audio "$DRIVER"
rtk proxy codesign --verify --strict "$DRIVER"
rtk proxy plutil -lint "$DRIVER/Contents/Info.plist"
echo "Built: $DRIVER (not installed)"
