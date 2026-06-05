#!/bin/bash
# Notarize a built (Developer ID-signed) artifact with Apple and staple the
# ticket. Uses an App Store Connect API key — no Apple ID / 2FA.
#
#   ./notarize.sh <submit-file> [staple-target]
#
# <submit-file>   what to upload (notarytool wants a .zip/.dmg/.pkg container)
# [staple-target] what to staple the ticket onto (default: the submit file).
#                 Staple the .app (then package it) so the app passes Gatekeeper
#                 even offline.
#
# Required env (decode the .p8 secret to a file in CI and point AC_API_KEY_PATH at it):
#   AC_API_KEY_PATH   path to the App Store Connect API .p8 private key
#   AC_API_KEY_ID     the key's Key ID
#   AC_API_ISSUER_ID  the issuer ID (UUID)
set -euo pipefail
cd "$(dirname "$0")"

SUBMIT="${1:?usage: notarize.sh <submit-file> [staple-target]}"
STAPLE="${2:-$SUBMIT}"
: "${AC_API_KEY_PATH:?set AC_API_KEY_PATH}"
: "${AC_API_KEY_ID:?set AC_API_KEY_ID}"
: "${AC_API_ISSUER_ID:?set AC_API_ISSUER_ID}"

echo "notarize: submitting $SUBMIT …"
xcrun notarytool submit "$SUBMIT" \
    --key "$AC_API_KEY_PATH" \
    --key-id "$AC_API_KEY_ID" \
    --issuer "$AC_API_ISSUER_ID" \
    --wait

echo "notarize: stapling $STAPLE …"
xcrun stapler staple "$STAPLE"
xcrun stapler validate "$STAPLE"
echo "notarize: done"
