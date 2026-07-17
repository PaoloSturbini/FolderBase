#!/usr/bin/env bash
# Invia il DMG gia' firmato al servizio notarile Apple, attende l'esito,
# applica il ticket e verifica il risultato finale.
#
# Prima configurazione (una sola volta):
#   xcrun notarytool store-credentials "folderbase-notary" \
#     --apple-id "IL_TUO_APPLE_ID" --team-id "F9SXX7XX48"
#
# Uso:
#   ./make-dmg.sh
#   ./notarize-dmg.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="FolderBase"
VERSION="1.5.10"
NOTARY_PROFILE="${NOTARY_PROFILE:-folderbase-notary}"
DMG="dist/${APP_NAME}-${VERSION}.dmg"

if [ ! -f "${DMG}" ]; then
    echo "Errore: ${DMG} non trovato. Esegui prima ./make-dmg.sh."
    exit 1
fi

echo ">> Invio ${DMG} ad Apple e attendo l'esito..."
xcrun notarytool submit "${DMG}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait

echo ">> Applico il ticket di notarizzazione al DMG..."
xcrun stapler staple "${DMG}"
xcrun stapler validate "${DMG}"

echo ">> Verifico Gatekeeper..."
spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG}"

echo "OK: ${DMG} e' firmato, notarizzato e provvisto di ticket Apple."
