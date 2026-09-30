#!/bin/sh
# Builds a universal (arm64 + x86_64) Mixoto.app with the driver inside.
# SIGN_IDENTITY: codesign identity; default "-" (ad hoc, local use only).
#   A real identity adds hardened runtime and a secure timestamp for notarization.
# VERSION: optional CFBundleShortVersionString, e.g. 1.2.3.
# SPARKLE_PUBLIC_ED_KEY: public key from Sparkle's generate_keys tool.
#   Required for Developer ID builds; local builds without it disable updates.
set -eu
cd "$(dirname "$0")/.."
SIGN_IDENTITY=${SIGN_IDENTITY:--}
if [ "$SIGN_IDENTITY" != - ] && [ -z "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
    echo "Developer ID builds require SPARKLE_PUBLIC_ED_KEY." >&2
    exit 1
fi
if [ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
    python3 -c 'import base64, os; assert len(base64.b64decode(os.environ["SPARKLE_PUBLIC_ED_KEY"], validate=True)) == 32, "Invalid Sparkle public key"'
fi
sh scripts/build-driver.sh
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path | tail -1)
APP="$PWD/artifacts/Mixoto.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
# SwiftPM links with --sysroot, so ld records the deployment target (15.0) as
# the SDK version. macOS then shows the pre-Tahoe look. Record the real SDK.
xcrun vtool -set-build-version macos 15.0 "$(xcrun --show-sdk-version)" -replace \
    -output "$APP/Contents/MacOS/Mixoto" "$BIN/Mixoto"
cp scripts/Info.plist "$APP/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
    /usr/libexec/PlistBuddy -c "Add SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$APP/Contents/Info.plist"
fi
# Preserve framework symlinks and re-sign nested code from the inside out.
SPARKLE=.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
set -- --force --sign "$SIGN_IDENTITY"
[ "$SIGN_IDENTITY" = - ] || set -- "$@" --options runtime --timestamp
codesign "$@" "$FRAMEWORK/Versions/B/Autoupdate"
codesign "$@" "$FRAMEWORK/Versions/B/Updater.app"
codesign "$@" "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
codesign "$@" "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
codesign "$@" "$FRAMEWORK"
cp Resources/AppIcon.icns Resources/Assets.car "$APP/Contents/Resources/"
cp -R artifacts/MixotoAudio.driver "$APP/Contents/Resources/MixotoAudio.driver"
cp scripts/install-driver.sh "$APP/Contents/Resources/install-driver.sh"
set -- --force --sign "$SIGN_IDENTITY" --identifier io.coollabs.mixoto --entitlements scripts/Mixoto.entitlements
[ "$SIGN_IDENTITY" = - ] || set -- "$@" --options runtime --timestamp
codesign "$@" "$APP"
codesign --verify --deep --strict "$APP"
codesign --verify --strict "$APP/Contents/Resources/MixotoAudio.driver"
echo "Built: $APP"
echo "Open with: open artifacts/Mixoto.app"
