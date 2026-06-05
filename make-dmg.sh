#!/bin/bash
# Build reLayout.dmg — a drag-to-Applications disk image (the standard macOS
# installer). Run ./build.sh first; this packages the resulting ReLayout.app.
# No code-signing cert needed beyond what build.sh already applied. Works
# headless (CI) — uses hdiutil, no Finder scripting.
set -euo pipefail
cd "$(dirname "$0")"

APP="ReLayout.app"
DMG="reLayout.dmg"
VOLNAME="reLayout"

[ -d "$APP" ] || { echo "error: $APP not found — run ./build.sh first" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Lay out the image: the app plus a symlink to /Applications, so the user just
# drags one onto the other.
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG"

echo "Built $DMG"
