#!/bin/sh
# Regenerate Resources/AppIcon.icns and Resources/Assets.car from Resources/AppIcon.svg.
# Needs ImageMagick (brew install imagemagick) and Xcode (actool). Run when the SVG changes.
set -eu
cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SET="$WORK/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$SET"
magick -background none -density 1152 Resources/AppIcon.svg -resize 1024x1024 "$WORK/1024.png"
IMAGES=""
for size in 16 32 128 256 512; do
    for scale in 1 2; do
        px=$((size * scale))
        name="icon_${size}x${size}.png"
        [ "$scale" = 2 ] && name="icon_${size}x${size}@2x.png"
        magick "$WORK/1024.png" -filter Lanczos -resize "${px}x${px}" "$SET/$name"
        IMAGES="$IMAGES{\"idiom\":\"mac\",\"size\":\"${size}x${size}\",\"scale\":\"${scale}x\",\"filename\":\"$name\"},"
    done
done
printf '{"images":[%s],"info":{"version":1,"author":"xcode"}}\n' "${IMAGES%,}" > "$SET/Contents.json"
printf '{"info":{"version":1,"author":"xcode"}}\n' > "$WORK/Assets.xcassets/Contents.json"
mkdir -p "$WORK/out"
xcrun actool "$WORK/Assets.xcassets" --compile "$WORK/out" --platform macosx \
    --minimum-deployment-target 15.0 --app-icon AppIcon \
    --output-partial-info-plist "$WORK/partial.plist" --output-format human-readable-text >/dev/null
# actool's .icns holds only 16 and 128 px; iconutil keeps every size for macOS 15.
cp -R "$SET" "$WORK/AppIcon.iconset"
rm "$WORK/AppIcon.iconset/Contents.json"
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
cp "$WORK/out/Assets.car" Resources/
echo "Built: Resources/AppIcon.icns Resources/Assets.car"
