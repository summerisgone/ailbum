#!/usr/bin/env bash
# Package the Swift app as build/swift/Ailbum.app (+ optional .dmg).
# Usage: swift/Tools/package_app.sh [--no-models] [--dmg]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKG="$ROOT/swift"
OUT="$ROOT/build/swift"
APP="$OUT/Ailbum.app"
NO_MODELS=0
DMG=0
for a in "$@"; do
  case "$a" in
    --no-models) NO_MODELS=1 ;;
    --dmg) DMG=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

VERSION="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$ROOT/desktop/package.json" | head -1)"
: "${VERSION:=0.0.0}"

FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
FLAGS=()
if [ -d "$FW" ]; then FLAGS=(-Xswiftc "-F$FW" -Xlinker "-F$FW"); fi

for product in AilbumApp ailbum-swift; do
  swift build -c release --package-path "$PKG" --product "$product" ${FLAGS[@]+"${FLAGS[@]}"}
done
BIN="$(swift build -c release --package-path "$PKG" --show-bin-path ${FLAGS[@]+"${FLAGS[@]}"})"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/AilbumApp" "$APP/Contents/MacOS/Ailbum"
cp "$BIN/ailbum-swift" "$APP/Contents/MacOS/ailbum-swift"
for b in "$BIN"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done
if [ "$NO_MODELS" = 0 ]; then
  mkdir -p "$APP/Contents/Resources/Models"
  cp -R "$PKG"/Models/*.mlpackage "$PKG/Models/clip_text.json" "$APP/Contents/Resources/Models/"
fi

ICON_KEY=""
SVG="$ROOT/desktop/build-resources/icon.svg"
if [ -f "$SVG" ]; then
  TMP="$(mktemp -d)"
  if qlmanage -t -s 1024 -o "$TMP" "$SVG" >/dev/null 2>&1 && [ -f "$TMP/icon.svg.png" ]; then
    SET="$TMP/AppIcon.iconset"
    mkdir "$SET"
    ok=1
    for s in 16 32 128 256 512; do
      sips -z $s $s "$TMP/icon.svg.png" --out "$SET/icon_${s}x${s}.png" >/dev/null 2>&1 || ok=0
      sips -z $((s*2)) $((s*2)) "$TMP/icon.svg.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null 2>&1 || ok=0
    done
    if [ "$ok" = 1 ] && iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns" >/dev/null 2>&1; then
      ICON_KEY="  <key>CFBundleIconFile</key><string>AppIcon</string>"
    fi
  fi
  rm -rf "$TMP"
fi
[ -n "$ICON_KEY" ] || echo "warning: icon generation skipped" >&2

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Ailbum</string>
  <key>CFBundleDisplayName</key><string>Ailbum</string>
  <key>CFBundleIdentifier</key><string>io.github.ailbum.desktop</string>
  <key>CFBundleExecutable</key><string>Ailbum</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
$ICON_KEY
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"

if [ "$DMG" = 1 ]; then
  DMGFILE="$OUT/Ailbum-$VERSION-mac-arm64.dmg"
  rm -f "$DMGFILE"
  hdiutil create -volname Ailbum -srcfolder "$APP" -ov -format UDZO "$DMGFILE"
  echo "dmg: $DMGFILE"
fi
echo "app: $APP"
