#!/usr/bin/env bash
# Builds the macOS app icon from the PM Radio Logs artwork.
#   ./branding/make-icon.sh branding/logo.png
# Source should be square and at least 1024x1024.
set -euo pipefail
SRC="${1:-branding/logo.png}"
[ -f "$SRC" ] || { echo "no such file: $SRC"; exit 1; }
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)/AppIcon.iconset
mkdir -p "$OUT"
for s in 16 32 64 128 256 512 1024; do
  sips -z $s $s "$SRC" --out "$OUT/icon_${s}x${s}.png" >/dev/null
done
# Retina variants are the next size up, named as @2x of the smaller one.
cp "$OUT/icon_32x32.png"     "$OUT/icon_16x16@2x.png"
cp "$OUT/icon_64x64.png"     "$OUT/icon_32x32@2x.png"
cp "$OUT/icon_256x256.png"   "$OUT/icon_128x128@2x.png"
cp "$OUT/icon_512x512.png"   "$OUT/icon_256x256@2x.png"
cp "$OUT/icon_1024x1024.png" "$OUT/icon_512x512@2x.png"
rm -f "$OUT/icon_64x64.png" "$OUT/icon_1024x1024.png"
iconutil -c icns "$OUT" -o RadioQA/Resources/AppIcon.icns
# the same artwork, shown inside the app
sips -z 512 512 "$SRC" --out RadioQA/Resources/Logo.png >/dev/null
echo "wrote RadioQA/Resources/AppIcon.icns and Logo.png"
