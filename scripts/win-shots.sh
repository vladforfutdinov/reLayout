#!/bin/bash
# Screenshots of the Windows port's Settings, Exceptions and Learned windows (light
# and dark theme) from HEAD, built in the Windows test VM (ssh alias, default win-vm).
# Usage: scripts/win-shots.sh [label]  -> dist/win-shots/<label>/{light,dark}/*.png
set -euo pipefail
cd "$(dirname "$0")/.."
host="${RELAYOUT_WIN_VM:-win-vm}"
label="${1:-head}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
git bundle create "$tmp/rl-shots.bundle" HEAD >/dev/null 2>&1
scp -q "$tmp/rl-shots.bundle" "$host:C:/src/rl-shots.bundle"
scp -q scripts/e2e/win-shots.ps1 "$host:C:/src/win-shots.ps1"
ssh "$host" "powershell -ExecutionPolicy Bypass -File C:\\src\\win-shots.ps1 -Ref HEAD -Label $label"
mkdir -p dist/win-shots && rm -rf "dist/win-shots/$label"
scp -q -r "$host:C:/src/rl-shots-out/$label" "dist/win-shots/$label"
echo "dist/win-shots/$label"
