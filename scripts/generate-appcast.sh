#!/bin/sh
# Sign the notarized release DMG and its Sparkle feed. Never trace this script:
# SPARKLE_PRIVATE_ED_KEY is a secret exported by Sparkle's generate_keys -x.
set -eu
cd "$(dirname "$0")/.."
: "${VERSION:?}" "${SPARKLE_PRIVATE_ED_KEY:?}"
TAG=${TAG:-v$VERSION}
DMG="Mixoto_${VERSION}_universal.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp "artifacts/$DMG" "$STAGE/$DMG"
printf '%s\n' "$SPARKLE_PRIVATE_ED_KEY" | .build/artifacts/sparkle/Sparkle/bin/generate_appcast \
    --ed-key-file - --maximum-deltas 0 \
    --download-url-prefix "https://github.com/coollabsio/Mixoto/releases/download/$TAG/" \
    --link "https://github.com/coollabsio/Mixoto/releases/tag/$TAG" \
    -o "$STAGE/appcast.xml" "$STAGE"
# generate_appcast can warn (without failing) about mismatched signing keys.
# Do not publish a feed unless it includes a signed archive for this version.
python3 - "$STAGE/appcast.xml" "$VERSION" "$TAG" "$DMG" <<'PY'
import base64
import sys
import xml.etree.ElementTree as ET

path, version, tag, filename = sys.argv[1:]
sparkle = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
root = ET.parse(path).getroot()
item, = root.findall("./channel/item")
assert item.findtext(f"{sparkle}version") == version, "Wrong update version"
enclosure = item.find("enclosure")
assert enclosure is not None, "Missing update archive"
signature = enclosure.attrib.get(f"{sparkle}edSignature", "")
assert len(base64.b64decode(signature, validate=True)) == 64, "Missing archive signature (check signing key pair)"
assert enclosure.attrib["url"] == f"https://github.com/coollabsio/Mixoto/releases/download/{tag}/{filename}", "Wrong download URL"
PY
printf '%s\n' "$SPARKLE_PRIVATE_ED_KEY" | .build/artifacts/sparkle/Sparkle/bin/sign_update \
    --ed-key-file - --verify "$STAGE/appcast.xml"
cp "$STAGE/appcast.xml" artifacts/appcast.xml
echo "Built: artifacts/appcast.xml"
