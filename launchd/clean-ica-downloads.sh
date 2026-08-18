#!/bin/bash
# clean-ica-downloads.sh - löscht alle *.ica Dateien in ~/Downloads.
# Citrix ICA-Launcher-Dateien sind nach dem Öffnen wertlos und sammeln sich an.
set -euo pipefail

DOWNLOADS="$HOME/Downloads"
LOG_DIR="$HOME/Library/Logs/clean-ica"

[ -d "$DOWNLOADS" ] || exit 0

mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$(date +%Y-%m).log"

# -maxdepth 1: nur direkt in Downloads, keine Unterordner.
# -print -delete: vor dem Löschen Pfad ausgeben, damit das Log aussagekräftig ist.
deleted=$(find "$DOWNLOADS" -maxdepth 1 -type f -iname '*.ica' -print -delete)

if [ -n "$deleted" ]; then
  {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] deleted:"
    echo "$deleted" | sed 's/^/  /'
  } >> "$LOG"
fi
