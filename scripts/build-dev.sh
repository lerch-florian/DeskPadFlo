#!/bin/bash
# Rebuilds DeskPad via the throwaway SwiftPM package and refreshes ~/DeskPad.app
# in place, re-signed with the same stable identity so macOS keeps the
# Screen Recording permission across rebuilds. See CLAUDE.md.
set -euo pipefail

SRC=/Users/florianlerch/ExternProjects/DeskPad/DeskPad
PKG=$HOME/deskpad-cli-build
APP=$HOME/DeskPad.app
IDENTITY="DeskPad Dev Signing"

# Link any new source files (existing links are refreshed harmlessly).
for f in $(find "$SRC" -name "*.swift"); do
  ln -sf "$f" "$PKG/Sources/DeskPadCLI/$(basename "$f")"
done

cd "$PKG"
swift build

# Overwrite the binary inside the existing bundle; never recreate the bundle,
# so its path and bundle identifier stay constant.
cp .build/debug/DeskPadCLI "$APP/Contents/MacOS/DeskPad"
codesign --force --deep --sign "$IDENTITY" -i com.deskpad.dev-test "$APP"
codesign -dr - "$APP" 2>&1 | grep designated

pkill -x DeskPad 2>/dev/null || true
sleep 1
open "$APP"
