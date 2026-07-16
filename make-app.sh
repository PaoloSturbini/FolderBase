#!/usr/bin/env bash
# Compila FolderBase in RELEASE e crea un vero bundle .app con icona, installandolo
# in /Applications. Da lanciare sul Mac:  ./make-app.sh
#
# Icona: salva l'immagine come "AppIcon.png" (idealmente 1024x1024) nella cartella
# del progetto, accanto a questo script.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="FolderBase"
CONFIG="release"
BUILD_PATH="/tmp/folderbase-run"
ICON_PNG="AppIcon.png"
INSTALL_DIR="/Applications"
BUNDLE_ID="com.paolosturbini.folderbase"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: PAOLO ANTONIO STURBIN (F9SXX7XX48)}"

echo ">> Compilo in ${CONFIG}..."
swift build -c "${CONFIG}" --build-path "${BUILD_PATH}"

BIN="${BUILD_PATH}/${CONFIG}/${APP_NAME}"
if [ ! -f "${BIN}" ]; then
    echo "Errore: eseguibile non trovato in ${BIN}"
    exit 1
fi

APP="${INSTALL_DIR}/${APP_NAME}.app"
echo ">> Creo il bundle ${APP}..."
rm -rf "${APP}"
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
    <key>CFBundleShortVersionString</key> <string>1.5.7</string>
    <key>CFBundleVersion</key>            <string>14</string>
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

# Copia le guide HTML (Italiano/Inglese) tra le risorse del bundle, così che
# HelpService le trovi via Bundle.main e le apra nel browser.
for help_file in FolderBase/Resources/help_it.html FolderBase/Resources/help_en.html; do
    if [ -f "${help_file}" ]; then
        cp "${help_file}" "${APP}/Contents/Resources/"
        echo ">> Copiata guida $(basename "${help_file}")"
    else
        echo "Attenzione: ${help_file} non trovato, la guida non sara' inclusa nel bundle."
    fi
done

if [ -f "${ICON_PNG}" ]; then
    echo ">> Genero l'icona da ${ICON_PNG}..."
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

# Firma Developer ID con hardened runtime e timestamp Apple, prerequisiti per
# Gatekeeper e notarizzazione. La chiave privata resta nel Portachiavi locale.
echo ">> Firmo con ${SIGN_IDENTITY}..."
codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "${SIGN_IDENTITY}" \
    "${APP}"
codesign --verify --deep --strict --verbose=2 "${APP}"

# Forza il refresh dell'icona nel Finder/Dock.
touch "${APP}"
echo "OK: installata in ${APP}"
