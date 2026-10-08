#!/bin/bash
# Create a stable local code-signing identity named "QuotaBar Local".
# Keychain remembers this certificate across rebuilds. An ad-hoc signature
# does not, so "Always Allow" would be forgotten on every launch.
set -euo pipefail

NAME="QuotaBar Local"
if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  exit 0
fi

echo "==> creating local code-signing identity: $NAME"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" << 'EOF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = QuotaBar Local
[ ext ]
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" \
  -out "$TMP/cert.pem" \
  -days 3650 \
  -config "$TMP/cert.cnf"

LOGIN="$HOME/Library/Keychains/login.keychain-db"
security import "$TMP/key.pem" \
  -k "$LOGIN" \
  -T /usr/bin/codesign \
  -T /usr/bin/security \
  -A
security import "$TMP/cert.pem" \
  -k "$LOGIN" \
  -T /usr/bin/codesign \
  -T /usr/bin/security \
  -A

# The identity only shows up for codesign after the login keychain trusts it.
security add-trusted-cert -r trustRoot -k "$LOGIN" "$TMP/cert.pem"

security find-identity -v -p codesigning | grep -q "\"$NAME\""
