#!/usr/bin/env bash
# Ad-hoc sign the built app inside-out (extensions with their sandbox
# entitlements first, then the host app) and print diagnostics.
set -euo pipefail

APP="${1:?usage: sign.sh path/to/EPSQuickLook.app}"
PREVIEW="$APP/Contents/PlugIns/EPSPreviewExtension.appex"
THUMB="$APP/Contents/PlugIns/EPSThumbnailExtension.appex"

if [ ! -d "$PREVIEW" ] || [ ! -d "$THUMB" ]; then
  echo "error: extensions were not embedded into the app"
  find "$APP" -maxdepth 3
  exit 1
fi

sign() { codesign --force --sign - --timestamp=none "$@"; }
sign --entitlements Support/PreviewExtension.entitlements "$PREVIEW"
sign --entitlements Support/ThumbnailExtension.entitlements "$THUMB"
sign "$APP"

echo "── verify"
codesign --verify --deep --strict --verbose=2 "$APP"

for x in "$PREVIEW" "$THUMB"; do
  echo "── $(basename "$x")"
  /usr/libexec/PlistBuddy -c "Print :NSExtension" "$x/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Print :CFBundlePackageType" "$x/Contents/Info.plist"
  codesign -d --entitlements - "$x" 2>/dev/null || true
  lipo -info "$x/Contents/MacOS/"*
done
lipo -info "$APP/Contents/MacOS/"*
