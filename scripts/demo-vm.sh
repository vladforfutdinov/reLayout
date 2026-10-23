#!/bin/bash
# Demo recording in the macOS test VM: full screen without the cursor plus a log of
# keys and mouse (scripts/demo/record.swift); zooms, camera, cursor and key overlay
# are made in post. Host: $RELAYOUT_MAC_VM, default the ssh alias `mac-vm`.
#   scripts/demo-vm.sh setup   ship HEAD, build the dev app and the recorder, install KeyCastr, grant TCC
#   scripts/demo-vm.sh start   start recording in the VM's GUI session
#   scripts/demo-vm.sh stop    stop it and copy the take to dist/demo/<take>/
#   scripts/demo-vm.sh take    fresh prefs, play scripts/demo/scenario.swift while recording, copy the take
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${RELAYOUT_MAC_VM:-mac-vm}"
REC='$HOME/src/relayout/.build/demo-record'

case "${1:-}" in
setup)
    # The working tree as a commit on no branch, uncommitted edits included.
    index=$(mktemp -t relayout-index)
    cp "$(git rev-parse --git-path index)" "$index"
    GIT_INDEX_FILE=$index git add -A
    wip=$(git commit-tree -p HEAD -m "demo take: working tree" "$(GIT_INDEX_FILE=$index git write-tree)")
    rm -f "$index"
    git update-ref refs/demo/wip "$wip"
    bundle=$(mktemp -t relayout-demo)
    git bundle create "$bundle" refs/demo/wip 2>/dev/null
    scp -q "$bundle" "$HOST:/tmp/relayout.bundle"
    rm -f "$bundle"
    ssh "$HOST" 'bash -s' <<'EOF'
set -euo pipefail
SRC="$HOME/src/relayout"
[ -d "$SRC/.git" ] || git clone -q /tmp/relayout.bundle "$SRC"
cd "$SRC"
git fetch -q /tmp/relayout.bundle refs/demo/wip
git checkout -q --force FETCH_HEAD
echo "at $(git log --oneline -1)"
who | grep -q console || { echo "nobody is logged in to the GUI: log in to the VM first" >&2; exit 1; }
sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX$(sw_vers -productVersion | cut -d. -f1).sdk"
[ -d "$sdk" ] && export SDKROOT="$sdk"
swift scripts/e2e/enable-layouts.swift com.apple.keylayout.ABC com.apple.keylayout.Russian com.apple.keylayout.Ukrainian-PC
RELAYOUT_DEV=1 ./scripts/build.sh >/dev/null
mkdir -p .build
swiftc -O scripts/demo/record.swift -o .build/demo-record
swiftc -O scripts/demo/scenario.swift -o .build/demo-scenario
swiftc -O scripts/demo/cursor.swift -o .build/demo-cursor
if [ ! -d /Applications/KeyCastr.app ]; then
    url=$(curl -fsSL https://api.github.com/repos/keycastr/keycastr/releases/latest | sed -n 's/.*"browser_download_url": *"\([^"]*\.zip\)".*/\1/p' | head -1)
    [ -n "$url" ] || { echo "no KeyCastr zip in the latest release" >&2; exit 1; }
    echo "KeyCastr: $url"
    curl -fsSL -o /tmp/keycastr.zip "$url"
    sudo ditto -x -k /tmp/keycastr.zip /Applications
    rm -f /tmp/keycastr.zip
fi
scripts/e2e/grant-tcc.sh "dist/ReLayout (dev).app"
# Over SSH the recorder counts as sshd-keygen-wrapper's for TCC (see vm-run.sh).
SERVICES="kTCCServiceAccessibility kTCCServiceListenEvent kTCCServiceScreenCapture" \
    scripts/e2e/grant-tcc.sh /Applications/KeyCastr.app "$SRC/.build/demo-record" /usr/libexec/sshd-keygen-wrapper /bin/bash
SERVICES="kTCCServiceAccessibility kTCCServicePostEvent kTCCServiceAppleEvents" \
    scripts/e2e/grant-tcc.sh "dist/ReLayout (dev).app" "$SRC/.build/demo-scenario"
pkill -f 'ReLayout \(dev\)' || true
sudo launchctl asuser "$(id -u)" sudo -u "$(whoami)" open "dist/ReLayout (dev).app"
mkdir -p "$HOME/demo"
sudo launchctl asuser "$(id -u)" sudo -u "$(whoami)" .build/demo-cursor "$HOME/demo/cursor"
echo "VM ready for recording"
EOF
    mkdir -p dist/demo
    scp -q "$HOST:demo/cursor.png" "$HOST:demo/cursor.json" dist/demo/
    ;;
start)
    ssh "$HOST" "pgrep -x demo-record >/dev/null && { echo 'already recording' >&2; exit 1; }
        take=\$HOME/demo/\$(date +%Y%m%d-%H%M%S); mkdir -p \$take; echo \$take > \$HOME/demo/last
        sudo launchctl asuser \$(id -u) sudo -u \$(whoami) nohup $REC \$take > \$take/record.log 2>&1 &
        sleep 2; cat \$take/record.log"
    ;;
stop)
    take=$(ssh "$HOST" 'sudo pkill -INT -x demo-record || true
        for _ in $(seq 40); do pgrep -x demo-record >/dev/null || break; sleep 0.5; done
        cat $HOME/demo/last')
    mkdir -p dist/demo
    scp -rq "$HOST:$take" dist/demo/
    out="dist/demo/$(basename "$take")"
    cat "$out/record.log"
    ls -lh "$out"
    ;;
take)
    ssh "$HOST" 'set -e; cd ~/src/relayout; U=$(id -u); W=$(whoami)
        gui() { sudo launchctl asuser $U sudo -u $W "$@"; }
        pkill -x KeyCastr || true
        pkill -f "ReLayout \(dev\)" || true; sleep 1
        defaults delete com.example.relayout.dev 2>/dev/null || true
        defaults write com.apple.TextEdit NSShowAppCentricOpenPanelInsteadOfUntitledFile -bool false
        defaults write com.apple.TextEdit ApplePersistenceIgnoreState -bool true
        defaults write com.apple.TextEdit RichText -int 1
        defaults write com.apple.TextEdit NSFontSize -int 28
        defaults write com.apple.TextEdit CheckSpellingWhileTyping -bool false
        gui open "dist/ReLayout (dev).app"; sleep 3
        osa() { gui osascript -e "$1" >/dev/null || true; }
        osa "tell application \"TextEdit\" to quit saving no"
        osa "tell application \"Terminal\" to quit"
        sleep 1
        osa "tell application \"System Events\" to set visible of every process whose visible is true and name is not \"Finder\" to false"
        osa "tell application \"Finder\" to close every window"
        osa "tell application \"Terminal\" to activate"; sleep 1.5
        osa "tell application \"Terminal\" to set font size of current settings of front window to 20"
        osa "tell application \"Terminal\" to set bounds of front window to {90, 80, 850, 500}"
        osa "tell application \"Terminal\" to do script \"PROMPT=\\\"%~ %# \\\"; clear\" in front window"
        osa "tell application \"System Events\" to set visible of process \"Terminal\" to false"
        osa "tell application \"TextEdit\" to activate"; sleep 1.5
        osa "tell application \"TextEdit\" to close every window saving no"
        osa "tell application \"TextEdit\" to make new document"; sleep 0.5
        osa "tell application \"TextEdit\" to set bounds of front window to {90, 80, 850, 500}"
        gui .build/demo-scenario prep'
    "$0" start
    ssh "$HOST" 'sudo launchctl asuser $(id -u) sudo -u $(whoami) ~/src/relayout/.build/demo-scenario run "$(cat ~/demo/last)/markers.jsonl"' || echo "scenario failed" >&2
    "$0" stop
    ;;
*)
    sed -n '2,8p' "$0"; exit 1 ;;
esac
