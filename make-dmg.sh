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
VERSION="1.5"
DIST_DIR="dist"

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
    <key>CFBundleVersion</key>            <string>7</string>
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>     <string>14.4</string>
    <key>NSHighResolutionCapable</key>    <true/>
    <key>NSPrincipalClass</key>           <string>NSApplication</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key> <true/>
    </dict>
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

# Firma ad-hoc (NON notarizzazione: vedi note sotto)
codesign --force --deep --sign - "${APP}" >/dev/null 2>&1 || true

# --- Layout del DMG: app + collegamento ad /Applications ---
ln -s /Applications "${STAGE}/Applications"

mkdir -p "${DIST_DIR}"
DMG="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"
rm -f "${DMG}"

echo ">> Creo il DMG..."
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGE}" \
    -ov -format UDZO \
    "${DMG}" >/dev/null

rm -rf "${STAGE}"
echo "OK: creato ${DMG}"
