#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="ReLayout.app"
# Version source of truth: RELAYOUT_VERSION env (set by CI from the git tag),
# falling back to the VERSION file for local/dev builds. Leading "v" stripped.
VERSION="${RELAYOUT_VERSION:-$(tr -d '[:space:]' < VERSION)}"
VERSION="${VERSION#v}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 0)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

# inject version (single source of truth = VERSION; build number = commit count)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

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
