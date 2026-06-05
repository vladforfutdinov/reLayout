#!/bin/bash
# Render Casks/relayout.rb from the template (version + dmg sha256) and push it to
# the Homebrew tap repo over SSH using a deploy key. Run by CI on release; no-ops
# if TAP_DEPLOY_KEY is unset.
#
#   ./packaging/homebrew/update-cask.sh <version> <dmg-path>
#
# Env:
#   TAP_DEPLOY_KEY  private SSH deploy key (write) for the tap repo (skips if empty)
#   TAP_REPO        owner/name of the tap (default: vladforfutdinov/homebrew-relayout)
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root

VERSION="${1:?usage: update-cask.sh <version> <dmg-path>}"
DMG="${2:?usage: update-cask.sh <version> <dmg-path>}"
TAP_REPO="${TAP_REPO:-vladforfutdinov/homebrew-relayout}"

if [ -z "${TAP_DEPLOY_KEY:-}" ]; then
    echo "update-cask: TAP_DEPLOY_KEY unset — skipping tap bump"
    exit 0
fi

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"

KEYFILE="$(mktemp)"
printf '%s\n' "$TAP_DEPLOY_KEY" > "$KEYFILE"
chmod 600 "$KEYFILE"
export GIT_SSH_COMMAND="ssh -i $KEYFILE -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" "$KEYFILE"' EXIT

git clone "git@github.com:${TAP_REPO}.git" "$WORK"
mkdir -p "$WORK/Casks"
sed -e "s/__VERSION__/${VERSION}/g" -e "s/__SHA256__/${SHA}/g" \
    packaging/homebrew/relayout.rb.tmpl > "$WORK/Casks/relayout.rb"

cd "$WORK"
git add Casks/relayout.rb
if git diff --cached --quiet; then
    echo "update-cask: cask already up to date"
    exit 0
fi
git -c user.name="relayout-ci" -c user.email="ci@users.noreply.github.com" \
    commit -m "relayout ${VERSION}"
git push origin HEAD:main
echo "update-cask: pushed relayout ${VERSION} (sha ${SHA}) to ${TAP_REPO}"
