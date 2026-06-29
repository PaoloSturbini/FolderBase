#!/usr/bin/env bash
# Compila FolderBase (senza avviarlo) usando una build directory esterna (/tmp).
# Passa eventuali argomenti extra a swift build, es: ./build.sh -c release
set -euo pipefail
cd "$(dirname "$0")"
exec swift build --build-path /tmp/folderbase-run "$@"
