#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Version, in precedence order:
#   1. RELAYOUT_VERSION env (manual override)
#   2. exact git tag on HEAD            -> release version  (e.g. 1.2.3)
#   3. git describe (nearest tag + dev) -> dev version      (e.g. 1.2.3-4-gabc123)
#   4. 0.0.0-dev                        -> no git / no tags
version_from_git() {
    git describe --tags --exact-match 2>/dev/null && return
    git describe --tags --always --dirty 2>/dev/null && return
    return 1
}
VERSION="${RELAYOUT_VERSION:-$(version_from_git || echo 0.0.0-dev)}"
VERSION="${VERSION#v}"
SHORT="${VERSION%%-*}"   # CFBundleShortVersionString must be plain dotted numbers
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 0)"

# Release vs dev: a release is built on an exact version tag (CI). Dev builds get
# a distinct bundle id, name AND .app filename so macOS keeps SEPARATE
# Accessibility / Input Monitoring grants and UserDefaults, and Finder/Settings
# show the suffix. Override with RELAYOUT_RELEASE=1 / RELAYOUT_DEV=1.
if git describe --tags --exact-match >/dev/null 2>&1; then IS_RELEASE=1; else IS_RELEASE=0; fi
[ "${RELAYOUT_RELEASE:-}" = "1" ] && IS_RELEASE=1
[ "${RELAYOUT_DEV:-}" = "1" ] && IS_RELEASE=0
if [ "$IS_RELEASE" = "1" ]; then
    APP="ReLayout.app";        BUNDLE_ID="com.vlad.relayout";     DISPLAY_NAME="reLayout"
else
    APP="ReLayout (dev).app";  BUNDLE_ID="com.vlad.relayout.dev"; DISPLAY_NAME="reLayout (dev)"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

# localizations: copy each <lang>.lproj/Localizable.strings into the bundle
mkdir -p "$APP/Contents/Resources"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

# app icon: composite the black "rL" wordmark onto an OPAQUE light rounded tile,
# so it stays visible on any background (Finder, the Sparkle updater window, Get
# Info) — a transparent glyph would vanish dark-on-dark. CFBundleIconFile=AppIcon.
ICON_SRC="$(mktemp -d)/appicon.png"
swift - "$ICON_SRC" Resources/for-light-text-1024.png <<'SWIFT'
import Cocoa
let out = CommandLine.arguments[1], glyphPath = CommandLine.arguments[2]
let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let inset: CGFloat = 64
let rect = NSRect(x: inset, y: inset, width: S - 2*inset, height: S - 2*inset)
let tile = NSBezierPath(roundedRect: rect, xRadius: 180, yRadius: 180)
tile.addClip()
NSGradient(colors: [NSColor(white: 0.97, alpha: 1), NSColor(white: 0.80, alpha: 1)])?
    .draw(in: rect, angle: -90)
if let glyph = NSImage(contentsOfFile: glyphPath) {
    let pad: CGFloat = 250
    glyph.draw(in: NSRect(x: pad, y: pad, width: S - 2*pad, height: S - 2*pad))
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
SWIFT
if [ -f "$ICON_SRC" ]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
    for pair in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" \
                "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" \
                "512:512x512" "1024:512x512@2x"; do
        px="${pair%%:*}"; nm="${pair##*:}"
        sips -z "$px" "$px" "$ICON_SRC" --out "$ICONSET/icon_${nm}.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET")"
    echo "icon: AppIcon.icns from $ICON_SRC"
fi

# "rL" wordmark variants for the static menu-bar icon + About panel
# (appearance-aware: white glyph on dark, black on light), loaded via NSImage(named:)
cp Resources/for-dark-text-1024.png Resources/for-light-text-1024.png "$APP/Contents/Resources/" 2>/dev/null || true

# inject version (short = release number; build = commit count)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
# full git version (e.g. 1.2.3 for a release tag, 1.2.3-4-gabc123[-dirty] for a
# dev build) — shown in the About panel so dev vs prod is obvious.
/usr/libexec/PlistBuddy -c "Set :RLVersionFull $VERSION" "$APP/Contents/Info.plist"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $DISPLAY_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$APP/Contents/Info.plist"
echo "version: $VERSION (short $SHORT, build $BUILD) — $DISPLAY_NAME [$BUNDLE_ID]"

SWIFT_FLAGS=(-O -parse-as-library)
LINK_FLAGS=(-framework Cocoa -framework Carbon)

# Sparkle auto-update is opt-in (WITH_SPARKLE=1, set by release CI) so local/test
# builds stay framework-free. Fetch a pinned Sparkle, embed the framework, compile
# the #if SPARKLE code, and rpath-link to the embedded framework.
SPARKLE_VERSION="2.6.4"
if [ "${WITH_SPARKLE:-0}" = "1" ]; then
    SPARKLE_DIR=".sparkle/$SPARKLE_VERSION"
    if [ ! -d "$SPARKLE_DIR/Sparkle.framework" ]; then
        echo "fetching Sparkle ${SPARKLE_VERSION}..."
        mkdir -p "$SPARKLE_DIR"
        curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
            | tar -xJ -C "$SPARKLE_DIR"
    fi
    mkdir -p "$APP/Contents/Frameworks"
    cp -R "$SPARKLE_DIR/Sparkle.framework" "$APP/Contents/Frameworks/"
    SWIFT_FLAGS+=(-D SPARKLE)
    LINK_FLAGS+=(-F "$SPARKLE_DIR" -framework Sparkle
                 -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
fi

swiftc "${SWIFT_FLAGS[@]}" -o "$APP/Contents/MacOS/ReLayout" main.swift "${LINK_FLAGS[@]}"

# Signing, in precedence order:
#   1. SIGN_IDENTITY set (CI / release) -> Developer ID Application + Hardened
#      Runtime + secure timestamp. This is what notarization requires.
#   2. local self-signed "ReLayout Self Signed" (run ./make-cert.sh once) so the
#      Accessibility grant survives rebuilds during development.
#   3. ad-hoc fallback.
# When Sparkle is embedded, sign it (and its nested XPC/helpers) FIRST, then the
# app, so the seal is valid inside-out.
#
# Hardened Runtime (--options runtime) is applied ONLY for Developer ID — it's a
# distribution/notarization requirement, and its library validation rejects an
# embedded framework that isn't signed by the SAME Team ID. With Developer ID both
# app and framework get your team, so it passes. Self-signed/ad-hoc have no team,
# so we skip hardened runtime locally (the Sparkle build still runs for testing).
SELF="ReLayout Self Signed"
sign_app() {   # $1 = identity, $2 = "yes" to harden (Developer ID only)
    local id="$1" opts=""
    [ "$2" = "yes" ] && opts="--options runtime --timestamp"
    if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
        codesign --force --deep $opts --sign "$id" "$APP/Contents/Frameworks/Sparkle.framework"
        codesign --force $opts --sign "$id" "$APP"
    else
        codesign --force --deep $opts --sign "$id" "$APP"
    fi
}
if [ -n "${SIGN_IDENTITY:-}" ]; then
    sign_app "$SIGN_IDENTITY" "yes"
    echo "signed: Developer ID ($SIGN_IDENTITY), hardened runtime"
elif security find-identity -v -p codesigning | grep -q "$SELF"; then
    sign_app "$SELF" "no"
    echo "signed: $SELF (local dev)"
else
    echo "WARNING: no signing identity — run ./make-cert.sh first. Ad-hoc signing (grant will re-prompt)."
    codesign --force --deep --sign - "$APP"
fi

echo "Built $APP"
echo
echo "Run:   open ./$APP"
echo "First launch: System Settings > Privacy & Security > Accessibility -> enable ReLayout, then relaunch."
echo "Hotkey: Ctrl+Option+R  (select text, then press)."
