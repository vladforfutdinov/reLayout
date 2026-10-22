#!/bin/bash
# macOS e2e in a test VM over SSH, so this Mac's keyboard and screen stay free.
# Ships this checkout's HEAD (a git bundle, nothing pushed) and runs
# scripts/e2e/vm-run.sh there. Host: $RELAYOUT_MAC_VM, default the ssh alias
# `mac-vm`. VM setup: docs/ARCHITECTURE.md (macOS test VM).
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${RELAYOUT_MAC_VM:-mac-vm}"
bundle=$(mktemp -t relayout-e2e)
git bundle create "$bundle" HEAD 2>/dev/null
scp -q "$bundle" "$HOST:/tmp/relayout.bundle"
rm -f "$bundle"
ssh "$HOST" 'bash -s' < scripts/e2e/vm-run.sh
