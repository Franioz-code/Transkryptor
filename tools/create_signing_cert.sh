#!/usr/bin/env bash
# Tworzy stały, samopodpisany certyfikat do podpisywania kodu i importuje go do
# pęku „login". Dzięki niemu aplikacja ma stałą tożsamość między przebudowami,
# więc zgody (Keychain, Nagrywanie ekranu) przestają się resetować.
set -euo pipefail

NAME="Transkryptor Self-Signed"

OPENSSL=/opt/homebrew/opt/openssl@3/bin/openssl
[ -x "$OPENSSL" ] || OPENSSL=$(command -v openssl)

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "✓ Certyfikat już istnieje: $NAME"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "▸ Generuję samopodpisany certyfikat code signing…"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
  -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

# -legacy: stary format PKCS12 zgodny z narzędziem `security` w macOS.
"$OPENSSL" pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -name "$NAME" -passout pass:transkryptor

echo "▸ Importuję do pęku login (z dostępem dla codesign)…"
security import "$TMP/identity.p12" \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  -P transkryptor -T /usr/bin/codesign

echo "✓ Gotowe. Tożsamości code signing:"
security find-identity -v -p codesigning | grep "$NAME" || true
