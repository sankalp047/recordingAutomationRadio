#!/usr/bin/env bash
# Builds a release .app and wraps it in a DMG for internal distribution.
#
#   ./build-release.sh                 unsigned - users must right-click > Open
#   ./build-release.sh "Developer ID Application: Your Co (TEAMID)"
#                                      signed - add notarisation to remove all warnings
set -euo pipefail
cd "$(dirname "$0")"
IDENTITY="${1:-}"
OUT="dist"
rm -rf "$OUT" .build/Build/Products/Release
mkdir -p "$OUT"

xcodegen generate >/dev/null
echo "building..."
xcodebuild -project RadioQA.xcodeproj -scheme RadioQA -configuration Release \
  -derivedDataPath .build \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

APP=$(find .build/Build/Products/Release -name "*.app" -maxdepth 1 | head -1)
[ -n "$APP" ] || { echo "no .app produced"; exit 1; }
cp -R "$APP" "$OUT/"
APP_NAME=$(basename "$APP")

if [ -n "$IDENTITY" ]; then
  echo "signing with: $IDENTITY"
  codesign --force --deep --options runtime --timestamp \
    --sign "$IDENTITY" "$OUT/$APP_NAME"
  codesign --verify --strict --verbose=2 "$OUT/$APP_NAME"
  echo
  echo "now notarise so Gatekeeper stops warning:"
  echo "  ditto -c -k --keepParent \"$OUT/$APP_NAME\" \"$OUT/upload.zip\""
  echo "  xcrun notarytool submit \"$OUT/upload.zip\" --apple-id <id> --team-id <team> --password <app-specific-password> --wait"
  echo "  xcrun stapler staple \"$OUT/$APP_NAME\""
else
  echo "NOT signed - recipients will need to right-click > Open the first time."
fi

hdiutil create -volname "PM Radio Logs" -srcfolder "$OUT/$APP_NAME" \
  -ov -format UDZO "$OUT/PMRadioLogs.dmg" >/dev/null
echo "wrote $OUT/PMRadioLogs.dmg ($(du -h "$OUT/PMRadioLogs.dmg" | cut -f1))"
