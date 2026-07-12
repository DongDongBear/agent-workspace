#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
BUILD_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/workdpace-build.XXXXXX")
APP="$BUILD_ROOT/workdpace.app"
DEST="$HOME/Applications/workdpace.app"
ARCH=$(uname -m)

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Bridge"
xcrun --sdk macosx swiftc -O -parse-as-library -target "${ARCH}-apple-macosx13.0" \
  -framework AppKit -framework WebKit \
  "$ROOT/Sources/Workdpace.swift" \
  -o "$APP/Contents/MacOS/workdpace"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/index.html" "$APP/Contents/Resources/index.html"
cp "$ROOT/Resources/Bridge/sesslist.sh" "$ROOT/Resources/Bridge/newsess.sh" \
  "$APP/Contents/Resources/Bridge/"
ICON_SOURCE="$BUILD_ROOT/AppIcon-1024.png"
ICONSET="$BUILD_ROOT/AppIcon.iconset"
"$APP/Contents/MacOS/workdpace" --write-icon "$ICON_SOURCE"
mkdir -p "$ICONSET"
while read -r name size; do
  sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/$name" >/dev/null
done <<'SIZES'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
SIZES
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null

if [ "${1:-}" = --check ]; then
  printf '%s\n' "$APP"
  exit 0
fi

STAGED=""
BACKUP=""
cleanup() {
  [ -z "$STAGED" ] || rm -rf "$STAGED"
  if [ -n "$BACKUP" ] && [ -e "$BACKUP" ]; then
    if [ -e "$DEST" ]; then
      printf 'Recovery copy preserved at %s\n' "$BACKUP" >&2
    elif ! mv "$BACKUP" "$DEST"; then
      printf 'Recovery copy left at %s\n' "$BACKUP" >&2
    fi
  fi
  rm -rf "$BUILD_ROOT"
}
trap cleanup EXIT
mkdir -p "$HOME/Applications"
STAGED="$HOME/Applications/.workdpace-install-$$.app"
BACKUP="$HOME/Applications/.workdpace-backup-$$.app"
rm -rf "$STAGED"
rm -rf "$BACKUP"
ditto "$APP" "$STAGED"
if [ -e "$DEST" ]; then
  EXISTING_ID=$(plutil -extract CFBundleIdentifier raw "$DEST/Contents/Info.plist" 2>/dev/null || true)
  [ "$EXISTING_ID" = io.github.dongdongbear.workdpace ] || {
    rm -rf "$STAGED"
    printf 'Refusing to replace %s: unexpected bundle identifier %s\n' "$DEST" "${EXISTING_ID:-missing}" >&2
    exit 1
  }
  mv "$DEST" "$BACKUP"
fi
if ! mv "$STAGED" "$DEST"; then
  exit 1
fi
STAGED=""
if [ -e "$BACKUP" ]; then
  rm -rf "$BACKUP"
fi
BACKUP=""
printf '%s\n' "$DEST"
