#!/bin/bash
# One-time: create a stable self-signed code-signing identity in the login keychain
# so the Accessibility grant survives rebuilds (ad-hoc signing re-prompts forever
# on macOS 26+).
set -euo pipefail

NAME="ReLayout Self Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "Identity '$NAME' already exists."
    exit 0
fi

DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

cat > "$DIR/cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = $NAME
[v3]
keyUsage             = critical, digitalSignature
extendedKeyUsage     = critical, codeSigning
basicConstraints     = critical, CA:false
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$DIR/key.pem" -out "$DIR/cert.pem" \
    -days 3650 -config "$DIR/cfg" 2>/dev/null

# import key + cert separately (avoids OpenSSL3<->Apple PKCS12 MAC mismatch).
# They pair into a code-signing identity by matching public key.
# -T lets codesign use the key without a per-sign auth prompt.
security import "$DIR/key.pem"  -k "$KEYCHAIN" -T /usr/bin/codesign
security import "$DIR/cert.pem" -k "$KEYCHAIN" -T /usr/bin/codesign

# trust the leaf for code signing (user domain; may pop one auth dialog)
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$DIR/cert.pem" || \
    echo "(trust step skipped — signing still works untrusted)"

echo "Created identity '$NAME'."
security find-identity -v -p codesigning | grep "$NAME" || true
