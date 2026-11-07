#!/bin/bash
# Installs the latest DeskPad release without Gatekeeper's "unidentified developer" prompt:
#
#   curl -fsSL https://raw.githubusercontent.com/lerch-florian/DeskPadFlo/main/scripts/install.sh | bash
#
# DeskPad isn't notarized (that needs a paid Apple Developer account). Gatekeeper only checks
# files carrying the quarantine flag that browsers attach to downloads; curl doesn't set it, so
# an app fetched this way just opens. Nothing here needs sudo.
#
# For testing / mirrors: DESKPAD_ZIP_URL (any curl URL, e.g. file://...), DESKPAD_APPS_DIR,
# DESKPAD_NO_OPEN=1.
set -euo pipefail

ZIP_URL=${DESKPAD_ZIP_URL:-https://github.com/lerch-florian/DeskPadFlo/releases/latest/download/DeskPad.zip}
APPS_DIR=${DESKPAD_APPS_DIR:-/Applications}

if [ ! -w "$APPS_DIR" ]; then
  APPS_DIR="$HOME/Applications"
  mkdir -p "$APPS_DIR"
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "Downloading DeskPad ..."
curl -fL --progress-bar "$ZIP_URL" -o "$WORK/DeskPad.zip"
ditto -x -k "$WORK/DeskPad.zip" "$WORK/unpacked"
[ -d "$WORK/unpacked/DeskPad.app" ] || { echo "The download doesn't contain DeskPad.app" >&2; exit 1; }
codesign --verify --deep --strict "$WORK/unpacked/DeskPad.app"

if pgrep -x DeskPad >/dev/null; then
  echo "Quitting the running DeskPad ..."
  pkill -x DeskPad || true
  sleep 1
fi

rm -rf "$APPS_DIR/DeskPad.app"
ditto "$WORK/unpacked/DeskPad.app" "$APPS_DIR/DeskPad.app"
xattr -dr com.apple.quarantine "$APPS_DIR/DeskPad.app" 2>/dev/null || true

echo "Installed to $APPS_DIR/DeskPad.app"
echo
echo "On first launch macOS asks for the Screen Recording permission (System Settings >"
echo "Privacy & Security > Screen Recording). Allow DeskPad there and start it again."

if [ -z "${DESKPAD_NO_OPEN:-}" ]; then
  open "$APPS_DIR/DeskPad.app"
fi
