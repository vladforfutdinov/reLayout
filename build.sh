#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="ReLayout.app"

# Version, in precedence order:
#   1. RELAYOUT_VERSION env (manual override)
#   2. exact git tag on HEAD            -> release version  (e.g. 1.2.3)
#   3. git describe (nearest tag + dev) -> dev version      (e.g. 1.2.3-4-gabc123)
#   4. VERSION file                     -> last-resort fallback
version_from_git() {
    git describe --tags --exact-match 2>/dev/null && return
    git describe --tags --always --dirty 2>/dev/null && return
    return 1
}
VERSION="${RELAYOUT_VERSION:-$(version_from_git || tr -d '[:space:]' < VERSION)}"
VERSION="${VERSION#v}"
SHORT="${VERSION%%-*}"   # CFBundleShortVersionString must be plain dotted numbers
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 0)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

# inject version (short = release number; build = commit count)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
echo "version: $VERSION (short $SHORT, build $BUILD)"

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
