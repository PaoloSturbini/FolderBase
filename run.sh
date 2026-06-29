#!/usr/bin/env bash
# Compila ed avvia FolderBase usando una build directory esterna (/tmp),
# così la cartella del progetto resta pulita e si evitano problemi di sync.
set -euo pipefail
cd "$(dirname "$0")"
exec swift run --build-path /tmp/folderbase-run FolderBase "$@"
