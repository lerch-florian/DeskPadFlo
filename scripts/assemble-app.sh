#!/bin/bash
# Usage: assemble-app.sh <built DeskPad binary> <output .app> <version>
# Wraps the SwiftPM-built binary into a DeskPad.app bundle: Info.plist from the template and an
# icon generated from the PNGs in the asset catalog (iconutil ships with macOS, so no Xcode and
# no asset-catalog compiler are needed). Does not sign; the callers do.
set -euo pipefail

BINARY=$1
APP=$2
VERSION=$3
BUNDLE_ID=${BUNDLE_ID:-io.github.lerch-florian.DeskPad}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ICONS="$ROOT/DeskPad/Assets.xcassets/AppIcon.appiconset"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/DeskPad"
sed -e "s|__BUNDLE_ID__|$BUNDLE_ID|" -e "s|__VERSION__|$VERSION|" "$ROOT/scripts/Info.plist.in" > "$APP/Contents/Info.plist"

ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
cp "$ICONS/Icon-16.png"   "$ICONSET/icon_16x16.png"
cp "$ICONS/Icon-32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$ICONS/Icon-32.png"   "$ICONSET/icon_32x32.png"
cp "$ICONS/Icon-64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$ICONS/Icon-128.png"  "$ICONSET/icon_128x128.png"
cp "$ICONS/Icon-256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$ICONS/Icon-256.png"  "$ICONSET/icon_256x256.png"
cp "$ICONS/Icon-512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$ICONS/Icon-512.png"  "$ICONSET/icon_512x512.png"
cp "$ICONS/Icon-1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"
