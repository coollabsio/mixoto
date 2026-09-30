#!/bin/sh
# Builds a universal (arm64 + x86_64) Mixoto.app with the driver inside.
# SIGN_IDENTITY: codesign identity; default "-" (ad hoc, local use only).
#   A real identity adds hardened runtime and a secure timestamp for notarization.
# VERSION: optional CFBundleShortVersionString, e.g. 1.2.3.
set -eu
cd "$(dirname "$0")/.."
SIGN_IDENTITY=${SIGN_IDENTITY:--}
sh scripts/build-driver.sh
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path | tail -1)
APP="$PWD/artifacts/Mixoto.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# SwiftPM links with --sysroot, so ld records the deployment target (15.0) as
# the SDK version. macOS then shows the pre-Tahoe look. Record the real SDK.
xcrun vtool -set-build-version macos 15.0 "$(xcrun --show-sdk-version)" -replace \
    -output "$APP/Contents/MacOS/Mixoto" "$BIN/Mixoto"
cp scripts/Info.plist "$APP/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
cp Resources/AppIcon.icns Resources/Assets.car "$APP/Contents/Resources/"
cp -R artifacts/MixotoAudio.driver "$APP/Contents/Resources/MixotoAudio.driver"
cp scripts/install-driver.sh "$APP/Contents/Resources/install-driver.sh"
set -- --force --sign "$SIGN_IDENTITY" --identifier io.coollabs.mixoto --entitlements scripts/Mixoto.entitlements
[ "$SIGN_IDENTITY" = - ] || set -- "$@" --options runtime --timestamp
codesign "$@" "$APP"
codesign --verify --strict "$APP"
codesign --verify --strict "$APP/Contents/Resources/MixotoAudio.driver"
echo "Built: $APP"
echo "Open with: open artifacts/Mixoto.app"
