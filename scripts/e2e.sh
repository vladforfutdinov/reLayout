#!/bin/bash
# End-to-end run: relaunches the dev build with known settings, types into a test
# window with synthetic keys (scripts/e2e/harness.swift), then restores the dev
# app's preferences and any reLayout that was running. Hands off the keyboard and
# mouse while it runs. Needs Accessibility for the terminal and ABC/U.S. + Russian
# layouts enabled. Build first with ./scripts/run.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/ReLayout (dev).app"
[ -d "$APP" ] || { echo "no $APP — run ./scripts/run.sh first" >&2; exit 1; }
ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")
BIN=.build/e2e-harness
mkdir -p .build
swiftc -O scripts/e2e/harness.swift -o "$BIN"

running=$(ps -axo command= | sed -n 's#^\(/.*\.app\)/Contents/MacOS/ReLayout$#\1#p' || true)
backup=$(mktemp -t relayout-e2e)
defaults export "$ID" "$backup" 2>/dev/null || : > "$backup"

restore() {
    killall ReLayout 2>/dev/null || true
    sleep 0.5
    if [ -s "$backup" ]; then defaults import "$ID" "$backup"; else defaults delete "$ID" 2>/dev/null || true; fi
    rm -f "$backup"
    # `||`, not `&&`: with nothing running the test would fail the trap under set -e.
    while IFS= read -r app; do [ -z "$app" ] || open "$app"; done <<< "$running"
}
trap restore EXIT

killall ReLayout 2>/dev/null || true
sleep 0.5
# Known state: auto-correct on, default hotkey (Shift twice), nothing learned or excluded.
for k in autoLearned autoKept autoLearnCounts autoLearnCandidates autoExcludedApps hotkeyExcludedApps \
         autoSameScript autoSpell autoEnterNewline \
         hkType hkCode hkMods hkChord hkTaps hkDisplay \
         autoHkType autoHkCode autoHkMods autoHkChord autoHkTaps autoHkDisplay; do
    defaults delete "$ID" "$k" 2>/dev/null || true
done
defaults write "$ID" autoMode -bool true
defaults write "$ID" hkDefaultPinned -bool true   # not a Mac from before the default changed
open "$APP"
sleep 2

"$BIN"
