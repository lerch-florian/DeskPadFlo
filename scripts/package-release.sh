#!/bin/bash
# Builds a universal (Apple silicon + Intel) DeskPad.app and zips it to dist/DeskPad.zip.
#
#   scripts/package-release.sh [version]          version defaults to `git describe`
#
# Needs only the Command Line Tools. Signing:
#   - default: ad-hoc. Free, but every build then has a different identity, so macOS asks for the
#     Screen Recording permission again after each update.
#   - SIGN_IDENTITY="<certificate name>": sign with a (self-signed) certificate from your keychain.
#     The same certificate on every release keeps the permission across updates. See CLAUDE.md.
# Neither is notarized (that needs a paid Apple Developer account), so a browser-downloaded copy
# triggers Gatekeeper's "unidentified developer" prompt; scripts/install.sh avoids it.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

VERSION=${1:-$(git describe --tags --always --dirty 2>/dev/null | sed 's/^v//' || echo 0.0.0)}
IDENTITY=${SIGN_IDENTITY:--}
BUNDLE_ID=${BUNDLE_ID:-io.github.lerch-florian.DeskPad}
APP="$ROOT/dist/DeskPad.app"

# One build per architecture, merged with lipo: SwiftPM's single-invocation `--arch a --arch b`
# needs Xcode's build engine, which the Command Line Tools don't include.
rm -rf "$ROOT/dist"
mkdir -p "$ROOT/dist"
for arch in arm64 x86_64; do
  swift build -c release --triple "$arch-apple-macosx"
done
BINARY="$ROOT/dist/DeskPad-universal"
lipo -create -output "$BINARY" \
  "$(swift build -c release --triple arm64-apple-macosx --show-bin-path)/DeskPad" \
  "$(swift build -c release --triple x86_64-apple-macosx --show-bin-path)/DeskPad"

BUNDLE_ID=$BUNDLE_ID "$ROOT/scripts/assemble-app.sh" "$BINARY" "$APP" "$VERSION"
rm -f "$BINARY"

codesign --force --deep --sign "$IDENTITY" -i "$BUNDLE_ID" --entitlements "$ROOT/DeskPad/DeskPad.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ROOT/dist/DeskPad.zip"

echo
echo "Version:       $VERSION"
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/DeskPad")"
echo "Signature:     $(codesign -dr - "$APP" 2>&1 | grep designated | sed 's/designated => //')"
echo "Archive:       dist/DeskPad.zip ($(du -h "$ROOT/dist/DeskPad.zip" | cut -f1))"
echo "SHA-256:       $(shasum -a 256 "$ROOT/dist/DeskPad.zip" | cut -d' ' -f1)"
