#!/usr/bin/env bash
# Compila FolderBase in RELEASE, assembla il bundle .app e lo impacchetta in un
# .dmg distribuibile (con collegamento ad /Applications per il drag&drop classico).
# Output:  dist/FolderBase-<versione>.dmg
#
# Uso:  ./make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="FolderBase"
CONFIG="release"
BUILD_PATH="/tmp/folderbase-run"
ICON_PNG="AppIcon.png"
BUNDLE_ID="com.paolosturbini.folderbase"
VERSION="1.5.11"
DIST_DIR="dist"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: PAOLO ANTONIO STURBIN (F9SXX7XX48)}"

echo ">> Compilo in ${CONFIG}..."
swift build -c "${CONFIG}" --build-path "${BUILD_PATH}"

BIN="${BUILD_PATH}/${CONFIG}/${APP_NAME}"
if [ ! -f "${BIN}" ]; then
    echo "Errore: eseguibile non trovato in ${BIN}"
    exit 1
fi

# --- Assembla il bundle .app in una cartella di staging temporanea ---
STAGE="$(mktemp -d)"
APP="${STAGE}/${APP_NAME}.app"
echo ">> Creo il bundle ${APP_NAME}.app..."
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/${APP_NAME}"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>        <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>         <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>         <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundleVersion</key>            <string>18</string>
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>     <string>14.4</string>
    <key>NSHighResolutionCapable</key>    <true/>
    <key>NSPrincipalClass</key>           <string>NSApplication</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key> <true/>
    </dict>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>       <string>${BUNDLE_ID}</string>
            <key>CFBundleTypeRole</key>      <string>Viewer</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>folderbase</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Guide HTML bilingui
for help_file in FolderBase/Resources/help_it.html FolderBase/Resources/help_en.html; do
    [ -f "${help_file}" ] && cp "${help_file}" "${APP}/Contents/Resources/"
done

# Icona
if [ -f "${ICON_PNG}" ]; then
    echo ">> Genero l'icona..."
    WORK="$(mktemp -d)"
    ICONSET="${WORK}/AppIcon.iconset"
    mkdir -p "${ICONSET}"
    for size in 16 32 128 256 512; do
        dbl=$(( size * 2 ))
        sips -z "${size}" "${size}" "${ICON_PNG}" --out "${ICONSET}/icon_${size}x${size}.png" >/dev/null
        sips -z "${dbl}" "${dbl}" "${ICON_PNG}" --out "${ICONSET}/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "${ICONSET}" -o "${APP}/Contents/Resources/AppIcon.icns"
    rm -rf "${WORK}"
else
    echo "Attenzione: ${ICON_PNG} non trovato, l'app usera' l'icona generica."
fi

# Firma Developer ID con hardened runtime e timestamp Apple.
echo ">> Firmo l'app con ${SIGN_IDENTITY}..."
codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "${SIGN_IDENTITY}" \
    "${APP}"
codesign --verify --deep --strict --verbose=2 "${APP}"

# --- Layout del DMG: app + collegamento ad /Applications ---
ln -s /Applications "${STAGE}/Applications"

mkdir -p "${DIST_DIR}"
DMG="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"
rm -f "${DMG}"
DMG_WORK="$(mktemp -d)"
SIGNABLE_DMG="${DMG_WORK}/${APP_NAME}-${VERSION}.dmg"

echo ">> Creo il DMG..."
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGE}" \
    -ov -format UDZO \
    "${SIGNABLE_DMG}" >/dev/null

rm -rf "${STAGE}"
echo ">> Firmo il DMG con ${SIGN_IDENTITY}..."
# hdiutil/Finder puo' aggiungere attributi estesi locali che impediscono a
# codesign di aggiornare il contenitore. Non fanno parte del contenuto del DMG.
xattr -c "${SIGNABLE_DMG}"
codesign \
    --force \
    --timestamp \
    --sign "${SIGN_IDENTITY}" \
    "${SIGNABLE_DMG}"
codesign --verify --strict --verbose=2 "${SIGNABLE_DMG}"
# Su macOS recenti una cartella Documents con attributo com.apple.provenance può rifiutare
# il rename cross-directory di un contenitore appena firmato. La copia conserva firma e bytes.
xattr -d com.apple.provenance "${DIST_DIR}" 2>/dev/null || true
# `cp -X` NON copia gli attributi estesi (es. com.apple.provenance): copiarli nella cartella
# Documents protetta causava "Operation not permitted". Firma e bytes del DMG restano intatti.
cp -X "${SIGNABLE_DMG}" "${DMG}"
rm -f "${SIGNABLE_DMG}"
rmdir "${DMG_WORK}"
echo "OK: creato ${DMG}"
