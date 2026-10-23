#!/bin/bash
# Grants Accessibility for e2e on a test Mac with SIP off (a CI runner, a VM):
# the dev app by its own designated requirement, plus the given executables by
# path (whatever posts the harness's keys). Writes the system TCC.db: needs sudo.
# usage: [SERVICES="kTCCService…"] grant-tcc.sh "<app path>" [executable …]
# SERVICES: what the executables get (default Accessibility + PostEvent).
set -euo pipefail
APP="$1"; shift
DB="/Library/Application Support/com.apple.TCC/TCC.db"
csrutil status | grep -q disabled || { echo "SIP is on: TCC.db is read-only" >&2; exit 1; }
NOW=$(date +%s)
row() {   # service, client, client_type (0 bundle id, 1 path), csreq hex or NULL
    echo "'$1','$2',$3,2,4,1,$4,NULL,0,'UNUSED',NULL,0,$NOW,NULL,NULL,'UNUSED',$NOW"
}
# The code's designated requirement as a blob literal, NULL when it has none. An
# ad-hoc signature's is implicit: printed as "# designated => cdhash H\"…\"".
requirement() {
    local req
    req=$(mktemp)
    codesign -d -r- "$1" 2>&1 | sed -n 's/^#* *designated => //p' > "$req"
    if [ -s "$req" ] && csreq -r "$req" -b "$req.bin" 2>/dev/null; then
        echo "X'$(xxd -p "$req.bin" | tr -d '\n')'"
    else
        echo NULL
    fi
    rm -f "$req" "$req.bin"
}
ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")
sudo sqlite3 "$DB" "INSERT OR REPLACE INTO access VALUES($(row kTCCServiceAccessibility "$ID" 0 "$(requirement "$APP")"));"
for exe in "$@"; do
    for service in ${SERVICES:-kTCCServiceAccessibility kTCCServicePostEvent}; do
        sudo sqlite3 "$DB" "INSERT OR REPLACE INTO access VALUES($(row $service "$exe" 1 "$(requirement "$exe")"));"
    done
done
sudo sqlite3 "$DB" "SELECT service, client, auth_value FROM access WHERE client IN ('$ID'$(printf ",'%s'" "$@"));"
