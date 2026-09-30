#!/bin/sh
# Local updater checks. No Keychain access, privileged install, or audio capture.
set -eu
umask 077
cd "$(dirname "$0")/.."
STAGE=$(mktemp -d)
cleanup() {
    rm -rf "$STAGE"
    rm -f artifacts/Mixoto_0.2.1_universal.dmg artifacts/appcast.xml
    unset VERSION TAG SPARKLE_PUBLIC_ED_KEY SPARKLE_PRIVATE_ED_KEY
    sh scripts/build-app.sh
}
trap cleanup EXIT
export SIGN_IDENTITY=-
export VERSION=0.2.1
export TAG=v$VERSION
# CryptoKit creates a test seed in memory. Never print the private key.
swift - "$STAGE" <<'SWIFT'
import Foundation
import CryptoKit
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedString().write(to: folder.appendingPathComponent("private"), atomically: true, encoding: .utf8)
try key.publicKey.rawRepresentation.base64EncodedString().write(to: folder.appendingPathComponent("public"), atomically: true, encoding: .utf8)
try Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString().write(to: folder.appendingPathComponent("wrong-private"), atomically: true, encoding: .utf8)
SWIFT
export SPARKLE_PUBLIC_ED_KEY=$(cat "$STAGE/public")
export SPARKLE_PRIVATE_ED_KEY=$(cat "$STAGE/private")
sh scripts/build-app.sh
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' artifacts/Mixoto.app/Contents/Info.plist)" = "$VERSION"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' artifacts/Mixoto.app/Contents/Info.plist)" = "$VERSION"
codesign --verify --deep --strict artifacts/Mixoto.app
mkdir "$STAGE/image"
ditto artifacts/Mixoto.app "$STAGE/image/Mixoto.app"
DMG="artifacts/Mixoto_${VERSION}_universal.dmg"
hdiutil create -ov -volname Mixoto -srcfolder "$STAGE/image" -fs HFS+ -format UDZO "$DMG"
sh scripts/generate-appcast.sh
SIGN=.build/artifacts/sparkle/Sparkle/bin/sign_update
printf '%s\n' "$SPARKLE_PRIVATE_ED_KEY" | "$SIGN" --ed-key-file - --verify artifacts/appcast.xml
SIGNATURE=$(python3 - <<'PY'
import xml.etree.ElementTree as ET
root = ET.parse("artifacts/appcast.xml").getroot()
print(root.find("./channel/item/enclosure").attrib["{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"])
PY
)
printf '%s\n' "$SPARKLE_PRIVATE_ED_KEY" | "$SIGN" --ed-key-file - --verify "$DMG" "$SIGNATURE"
cp "$DMG" "$STAGE/tampered.dmg"
printf 'changed' >> "$STAGE/tampered.dmg"
if printf '%s\n' "$SPARKLE_PRIVATE_ED_KEY" | "$SIGN" --ed-key-file - --verify "$STAGE/tampered.dmg" "$SIGNATURE"; then
    echo "ERROR: A changed archive passed signature validation." >&2
    exit 1
fi
cp artifacts/appcast.xml "$STAGE/tampered.xml"
python3 - "$STAGE/tampered.xml" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
path.write_text(path.read_text().replace("/releases/download/", "/releases/tampered/"))
PY
if printf '%s\n' "$SPARKLE_PRIVATE_ED_KEY" | "$SIGN" --ed-key-file - --verify "$STAGE/tampered.xml"; then
    echo "ERROR: A changed feed passed signature validation." >&2
    exit 1
fi
SPARKLE_PRIVATE_ED_KEY=$(cat "$STAGE/wrong-private")
export SPARKLE_PRIVATE_ED_KEY
if sh scripts/generate-appcast.sh; then
    echo "ERROR: A mismatched private key was accepted." >&2
    exit 1
fi
MIXOTO_SMOKE_REPORT="$STAGE/smoke.json" artifacts/Mixoto.app/Contents/MacOS/Mixoto
python3 - "$STAGE/smoke.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
assert report["windowTitle"] == "Mixoto"
assert report["driverBundled"] and report["installerBundled"]
assert not report["running"]
PY
echo "Updater signature, mismatch, bundle, version, and native smoke tests passed."
