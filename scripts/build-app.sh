#!/bin/zsh
# Build Fieldwatch.app from the Swift package.
#   scripts/build-app.sh                 release build, signed with your Apple Development identity (else ad-hoc)
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh   sign with a specific identity
#   UNIVERSAL=1 scripts/build-app.sh     arm64 + x86_64
#   CONFIG=debug scripts/build-app.sh    debug build
set -euo pipefail
cd "${0:A:h}/.."

CONFIG="${CONFIG:-release}"
OUT="build"
APP="$OUT/Fieldwatch.app"

archs=(--arch arm64)
[[ "${UNIVERSAL:-0}" == "1" ]] && archs=(--arch arm64 --arch x86_64)

echo "› swift build ($CONFIG)"
swift build -c "$CONFIG" --product Fieldwatch "${archs[@]}"
BIN_DIR="$(swift build -c "$CONFIG" --product Fieldwatch "${archs[@]}" --show-bin-path)"

echo "› assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Fieldwatch" "$APP/Contents/MacOS/Fieldwatch"
cp Support/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# SwiftPM resource bundles (radiodb.bin, stock catalog) go in Contents/Resources.
for b in "$BIN_DIR"/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done

# Optional extras.
[[ -f Support/Fieldwatch_User_Manual.pdf ]] && cp Support/Fieldwatch_User_Manual.pdf "$APP/Contents/Resources/"

# Icon.
if [[ ! -f Support/AppIcon.icns ]]; then
  ICONSET="$OUT/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Support/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Support/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Support/AppIcon.icns
fi
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign. A stable identity keeps Bluetooth / Location grants across rebuilds; ad-hoc asks again each build.
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  # Hash, not name: several certificates can share one name.
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')"
fi
[[ -z "$IDENTITY" ]] && IDENTITY="-"
echo "› codesign ($IDENTITY)"
codesign --force --options runtime --timestamp=none --entitlements Support/Fieldwatch.entitlements \
  --sign "$IDENTITY" "$APP/Contents/Resources/"*.bundle(N) 2>/dev/null || true
codesign --force --options runtime --timestamp=none --entitlements Support/Fieldwatch.entitlements \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP" && echo "✓ $APP"
