#!/bin/bash
# Compile and run reLayout's unit tests. -DTESTING swaps main.swift's GUI bootstrap
# for tests.swift's entry point; both files compile together so the tests exercise
# the real conversion engine + helpers, not copies.
set -euo pipefail
cd "$(dirname "$0")"

BIN="$(mktemp -d)/relayout-tests"
swiftc -DTESTING -parse-as-library -o "$BIN" main.swift tests.swift Core/*.swift \
    -framework Cocoa -framework Carbon
"$BIN"
