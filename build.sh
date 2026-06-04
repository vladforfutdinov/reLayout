#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="ReLayout.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -O -o "$APP/Contents/MacOS/ReLayout" main.swift \
    -framework Cocoa -framework Carbon

# Sign with the stable self-signed identity if present (run ./make-cert.sh once),
# so the Accessibility grant survives rebuilds. Fall back to ad-hoc otherwise.
IDENTITY="ReLayout Self Signed"
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
else
    echo "WARNING: '$IDENTITY' not found — run ./make-cert.sh first. Ad-hoc signing (grant will re-prompt)."
    codesign --force --deep --sign - "$APP"
fi

echo "Built $APP"
echo
echo "Run:   open ./$APP"
echo "First launch: System Settings > Privacy & Security > Accessibility -> enable ReLayout, then relaunch."
echo "Hotkey: Ctrl+Option+R  (select text, then press)."
