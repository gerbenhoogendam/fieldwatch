#!/bin/zsh
# Build a notarized, stapled Fieldwatch.app and Fieldwatch-<version>.dmg (arm64 + x86_64).
#
#   NOTARY_PROFILE=fieldwatch-notary scripts/release.sh
#
# One-time setup (stores an app-specific password in your keychain; you type it, not this script):
#   xcrun notarytool store-credentials fieldwatch-notary --apple-id <you@example.com> --team-id <TEAMID>
#
# Without NOTARY_PROFILE the script signs and packages but skips notarization (for a dry run).
set -euo pipefail
cd "${0:A:h}/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Support/Info.plist)"
APP="build/Fieldwatch.app"
OUT="build/release"
DMG="$OUT/Fieldwatch-$VERSION.dmg"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
[[ -z "$IDENTITY" ]] && { echo "No Developer ID Application certificate found." >&2; exit 1; }

echo "› build + sign ($IDENTITY)"
UNIVERSAL=1 SIGN_IDENTITY="$IDENTITY" scripts/build-app.sh
# Re-sign with a secure timestamp (required for notarization).
codesign --force --options runtime --timestamp --entitlements Support/Fieldwatch.entitlements \
  --sign "$IDENTITY" "$APP/Contents/Resources/"*.bundle(N)
codesign --force --options runtime --timestamp --entitlements Support/Fieldwatch.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

rm -rf "$OUT"; mkdir -p "$OUT"

notarize() {
  local file="$1"
  echo "› notarize $(basename "$file") (this can take a few minutes)"
  xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$OUT/notary.json" || true
  local result="$(/usr/bin/plutil -extract status raw "$OUT/notary.json" 2>/dev/null || echo unknown)"
  if [[ "$result" != "Accepted" ]]; then
    cat "$OUT/notary.json" >&2
    local id="$(/usr/bin/plutil -extract id raw "$OUT/notary.json" 2>/dev/null || true)"
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    echo "Notarization failed: $result" >&2
    exit 1
  fi
}

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --keepParent "$APP" "$OUT/Fieldwatch-notarize.zip"
  notarize "$OUT/Fieldwatch-notarize.zip"
  xcrun stapler staple "$APP"
  rm "$OUT/Fieldwatch-notarize.zip"
else
  echo "› NOTARY_PROFILE not set: skipping notarization (dry run)"
fi

echo "› dmg"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Fieldwatch.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Fieldwatch $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl -a -vv -t install "$DMG"
  spctl -a -vv "$APP"
fi

ditto -c -k --keepParent "$APP" "$OUT/Fieldwatch-$VERSION.zip"
shasum -a 256 "$DMG" "$OUT/Fieldwatch-$VERSION.zip" | tee "$OUT/SHA256SUMS.txt"
echo "✓ $DMG"
