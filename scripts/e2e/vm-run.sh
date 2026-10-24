#!/bin/bash
# Runs inside the macOS test VM (sent there by scripts/e2e-mac-vm.sh): checks out
# the shipped commit, builds the dev app, grants it Accessibility, and runs
# scripts/e2e.sh in the logged-in GUI session.
set -euo pipefail
SRC="$HOME/src/relayout"
[ -d "$SRC/.git" ] || git clone -q /tmp/relayout.bundle "$SRC"
cd "$SRC"
git fetch -q /tmp/relayout.bundle HEAD
git checkout -q --force FETCH_HEAD
echo "at $(git log --oneline -1)"

who | grep -q console || { echo "nobody is logged in to the GUI: log in to the VM first" >&2; exit 1; }
sudo -n true 2>/dev/null || { echo "sudo needs a password here: see docs/ARCHITECTURE.md (macOS test VM)" >&2; exit 1; }

# The SDK of this macOS release, when the tools carry one: a newer SDK can need a
# newer compiler than the tools have (CLT 27.0's SDK did not build with its 6.3.3).
sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX$(sw_vers -productVersion | cut -d. -f1).sdk"
[ -d "$sdk" ] && export SDKROOT="$sdk"

swift scripts/e2e/enable-layouts.swift com.apple.keylayout.ABC com.apple.keylayout.Russian com.apple.keylayout.Ukrainian-PC
RELAYOUT_DEV=1 RELAYOUT_DEBUG=1 ./scripts/build.sh >/dev/null
mkdir -p .build
swiftc -O scripts/e2e/harness.swift -o .build/e2e-harness
# Started over SSH, the harness counts as sshd-keygen-wrapper's for TCC (the
# GitHub image grants that one for the same reason); bash and the harness itself
# cover a run started in the VM's own Terminal.
scripts/e2e/grant-tcc.sh "dist/ReLayout (dev).app" /usr/libexec/sshd-keygen-wrapper /bin/bash "$SRC/.build/e2e-harness"

# The SSH session is outside the GUI session; the GUI one has the window server.
# sudo drops the environment: SDKROOT goes along explicitly.
sudo launchctl asuser "$(id -u)" sudo -u "$(whoami)" env SDKROOT="${SDKROOT:-}" \
    RELAYOUT_E2E_PERF="${RELAYOUT_E2E_PERF:-}" ./scripts/e2e.sh
