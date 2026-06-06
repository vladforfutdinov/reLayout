#!/bin/bash
# Dev loop: kill the running app, rebuild (dev variant), relaunch.
# The bundle binary is named ReLayout for both dev and release, so one killall
# catches whichever is running.
set -euo pipefail
cd "$(dirname "$0")/.."

killall ReLayout 2>/dev/null || true
RELAYOUT_DEV=1 ./scripts/build.sh
open "dist/ReLayout (dev).app"
