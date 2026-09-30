#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
rtk proxy sh scripts/build-driver.sh
rtk swift build -c release
BIN=$(rtk proxy swift build -c release --show-bin-path | tail -1)
APP="$PWD/artifacts/Mixoto.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# SwiftPM links with --sysroot, so ld records the deployment target (15.0) as
# the SDK version. macOS then shows the pre-Tahoe look. Record the real SDK.
/usr/bin/xcrun vtool -set-build-version macos 15.0 "$(/usr/bin/xcrun --show-sdk-version)" -replace \
    -output "$APP/Contents/MacOS/Mixoto" "$BIN/Mixoto"
cp scripts/Info.plist "$APP/Contents/Info.plist"
rm -rf "$APP/Contents/Resources/MixotoAudio.driver"
cp -R artifacts/MixotoAudio.driver "$APP/Contents/Resources/MixotoAudio.driver"
cp scripts/install-driver.sh "$APP/Contents/Resources/install-driver.sh"
rtk proxy codesign --force --sign - --identifier local.mixoto.app "$APP"
rtk proxy codesign --verify --strict "$APP"
rtk proxy codesign --verify --strict "$APP/Contents/Resources/MixotoAudio.driver"
echo "Built: $APP"
echo "Open with: rtk proxy open artifacts/Mixoto.app"
