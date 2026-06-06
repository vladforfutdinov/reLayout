#!/bin/bash
# Build reLayout.dmg — a drag-to-Applications disk image (the standard macOS
# installer). Run ./scripts/build.sh first; this packages the resulting dist/ReLayout.app.
# No code-signing cert needed beyond what build.sh already applied. Works
# headless (CI) — uses hdiutil, no Finder scripting.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/ReLayout.app"
DMG="dist/reLayout.dmg"
VOLNAME="reLayout"

[ -d "$APP" ] || { echo "error: $APP not found — run ./scripts/build.sh first" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Lay out the image: the app plus a symlink to /Applications, so the user just
# drags one onto the other.
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
# hdiutil can intermittently fail with "Resource busy" on CI (Spotlight/mount
# races over the staging dir); retry a few times.
for attempt in 1 2 3 4; do
    if hdiutil create \
        -volname "$VOLNAME" \
        -srcfolder "$STAGE" \
        -fs HFS+ \
        -format UDZO \
        -ov \
        "$DMG"; then
        break
    fi
    if [ "$attempt" = 4 ]; then echo "error: hdiutil create failed after retries" >&2; exit 1; fi
    echo "hdiutil create failed (attempt $attempt) -- retrying in 5s"
    sleep 5
done

echo "Built $DMG"
