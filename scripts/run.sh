#!/bin/bash
# Dev loop: kill the running app, rebuild (dev variant), relaunch.
# The bundle binary is named ReLayout for both dev and release, so one killall
# catches whichever is running.
# Traces to /tmp/relayout.log by default (RELAYOUT_DEBUG=0 to build without).
set -euo pipefail
cd "$(dirname "$0")/.."

killall ReLayout 2>/dev/null || true
RELAYOUT_DEV=1 RELAYOUT_DEBUG="${RELAYOUT_DEBUG:-1}" ./scripts/build.sh
open "dist/ReLayout (dev).app"
