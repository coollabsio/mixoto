#!/bin/sh
# Packages artifacts/Mixoto.app into a signed, notarized, stapled DMG.
# Run scripts/build-app.sh with a Developer ID SIGN_IDENTITY first.
# Needs: SIGN_IDENTITY, APPLE_ID, APPLE_PASSWORD (app-specific), APPLE_TEAM_ID.
# VERSION names the file: artifacts/Mixoto_<VERSION>_universal.dmg.
set -eu
cd "$(dirname "$0")/.."
: "${SIGN_IDENTITY:?}" "${APPLE_ID:?}" "${APPLE_PASSWORD:?}" "${APPLE_TEAM_ID:?}" "${VERSION:?}"
APP=artifacts/Mixoto.app
DMG="artifacts/Mixoto_${VERSION}_universal.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Mixoto.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname Mixoto -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
# notarytool exits 0 for an Invalid result, so check the status.
xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" --wait --output-format json > "$STAGE/notary.json"
cat "$STAGE/notary.json"
if ! grep -q '"status" *: *"Accepted"' "$STAGE/notary.json"; then
    ID=$(plutil -extract id raw "$STAGE/notary.json")
    xcrun notarytool log "$ID" --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID"
    exit 1
fi
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
echo "Built: $DMG"
