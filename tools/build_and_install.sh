#!/usr/bin/env bash
# Buduje wersję Release i instaluje Transkryptor.app do /Applications.
# Podpisuje stałym certyfikatem „Transkryptor Self-Signed" jeśli istnieje (trwała
# tożsamość = zgody Keychain/Nagrywanie ekranu przeżywają przebudowy), inaczej ad-hoc.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IDENTITY="Transkryptor Self-Signed"
APP="build/Build/Products/Release/Transkryptor.app"

echo "▸ Generuję projekt (xcodegen)…"
xcodegen generate >/dev/null

echo "▸ Buduję wersję Release (bez podpisu)…"
xcodebuild -project Transkryptor.xcodeproj -scheme Transkryptor \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build -clonedSourcePackagesDirPath build/SourcePackages \
  CODE_SIGNING_ALLOWED=NO build | tail -1

echo "▸ Podpisuję…"
if security find-identity -p codesigning | grep -q "$IDENTITY" \
   && codesign --force --deep --sign "$IDENTITY" "$APP" 2>/dev/null; then
  echo "  ✓ podpisano stałym certyfikatem: $IDENTITY"
else
  codesign --force --deep --sign - "$APP"
  echo "  ⚠︎ podpisano ad-hoc (brak/niezaufany certyfikat — zgody mogą się resetować)"
fi

echo "▸ Ubijam działające instancje (ważne — inaczej zobaczysz stary build)…"
pkill -9 -x Transkryptor 2>/dev/null || true
sleep 1

echo "▸ Instaluję do /Applications…"
rm -rf "/Applications/Transkryptor.app"
cp -R "$APP" "/Applications/Transkryptor.app"

/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
  -f "/Applications/Transkryptor.app" >/dev/null 2>&1 || true

echo "▸ Uruchamiam świeżą kopię…"
open /Applications/Transkryptor.app

echo "✓ Gotowe: /Applications/Transkryptor.app"
