#!/bin/bash
# Rebuilds DeskPad (debug), refreshes ~/DeskPad.app in place, re-signs it with the same stable
# identity so macOS keeps the Screen Recording permission across rebuilds, and relaunches it.
# One-time setup of that signing identity: see CLAUDE.md.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=$HOME/DeskPad.app
IDENTITY=${SIGN_IDENTITY:-DeskPad Dev Signing}
BUNDLE_ID=${BUNDLE_ID:-io.github.lerch-florian.DeskPad}

cd "$ROOT"
swift build
BUNDLE_ID=$BUNDLE_ID "$ROOT/scripts/assemble-app.sh" "$(swift build --show-bin-path)/DeskPad" "$APP" 0.0.0-dev

codesign --force --deep --sign "$IDENTITY" -i "$BUNDLE_ID" --entitlements "$ROOT/DeskPad/DeskPad.entitlements" "$APP"
codesign -dr - "$APP" 2>&1 | grep designated

pkill -x DeskPad 2>/dev/null || true
sleep 1
open "$APP"
