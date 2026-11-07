#!/bin/bash
# Builds a universal (Apple silicon + Intel) DeskPad.app and zips it to dist/DeskPad.zip.
#
#   scripts/package-release.sh [version]          version defaults to `git describe`
#
# Needs only the Command Line Tools. Signing:
#   - If the release certificate ("DeskPad Dev Signing") is in your keychain it is used, and the
#     result is checked against its pinned fingerprint below. The same certificate on every release
#     keeps users' Screen Recording permission across updates. See CLAUDE.md.
#   - Otherwise (e.g. a contributor's machine) the app is signed ad-hoc. That is fine locally, but
#     don't publish it: ad-hoc builds have a different identity every time, so users would be asked
#     for the permission again.
#   - SIGN_IDENTITY="<name>" forces a certificate ("-" forces ad-hoc).
# Neither is notarized (that needs a paid Apple Developer account), so a browser-downloaded copy
# triggers Gatekeeper's "unidentified developer" prompt; scripts/install.sh avoids it.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

VERSION=${1:-$(git describe --tags --always --dirty 2>/dev/null | sed 's/^v//' || echo 0.0.0)}

# The identity every published release must carry. The fingerprint is the SHA-1 of the
# certificate's public part (not a secret). Changing the certificate forces every user to grant
# Screen Recording again once: do it deliberately, with ALLOW_NEW_IDENTITY=1, and say so in the
# release notes.
RELEASE_IDENTITY="DeskPad Dev Signing"
RELEASE_CERT_HASH=${RELEASE_CERT_HASH:-dcf636eacacdd33031da32ad1ac66024bd9a9f5e}

if [ -n "${SIGN_IDENTITY:-}" ]; then
  IDENTITY=$SIGN_IDENTITY
elif security find-certificate -c "$RELEASE_IDENTITY" >/dev/null 2>&1; then
  IDENTITY=$RELEASE_IDENTITY
else
  IDENTITY=-
fi
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

REQUIREMENT=$(codesign -dr - "$APP" 2>&1 | grep designated || true)
if [ "$IDENTITY" = "-" ]; then
  SIGNED_AS="AD-HOC. Do NOT publish this: users would be asked for Screen Recording again after every update."
elif [[ "$REQUIREMENT" == *"$RELEASE_CERT_HASH"* ]]; then
  SIGNED_AS="release identity (certificate $RELEASE_CERT_HASH): OK to publish"
elif [ -n "${ALLOW_NEW_IDENTITY:-}" ]; then
  SIGNED_AS="a NEW identity (ALLOW_NEW_IDENTITY): every user will be asked for Screen Recording once"
else
  echo "ERROR: signed with a certificate that is not the pinned release identity." >&2
  echo "  expected certificate $RELEASE_CERT_HASH" >&2
  echo "  got      $REQUIREMENT" >&2
  echo "Use the right certificate, or set ALLOW_NEW_IDENTITY=1 if you are replacing it on purpose." >&2
  exit 1
fi

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ROOT/dist/DeskPad.zip"

echo
echo "Version:       $VERSION"
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/DeskPad")"
echo "Signature:     $(echo "$REQUIREMENT" | sed 's/designated => //')"
echo "Signed as:     $SIGNED_AS"
echo "Archive:       dist/DeskPad.zip ($(du -h "$ROOT/dist/DeskPad.zip" | cut -f1))"
echo "SHA-256:       $(shasum -a 256 "$ROOT/dist/DeskPad.zip" | cut -d' ' -f1)"
