#!/bin/bash
# kopia-snapshot.sh - hourly Kopia snapshot, run by launchd.
# Silent skip when backup disk isn't mounted; warns once/day after 5 days offline.
set -euo pipefail

REPO_PATH="/Volumes/Backups/kopia-r-mac"
SOURCE="/Users/rubeen"
LOG_DIR="$HOME/Library/Logs/kopia"
PW_FILE="$HOME/.config/kopia/.password"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/kopia"
LAST_MOUNTED="$STATE_DIR/last-mounted"
LAST_WARNED="$STATE_DIR/last-warned"
WARN_AFTER_DAYS=5
WARN_COOLDOWN_HOURS=24

mkdir -p "$LOG_DIR" "$STATE_DIR"
LOG="$LOG_DIR/snapshot-$(date +%Y-%m).log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

notify_disk_missing() {
  local last_mounted_ts="$1" days_missing="$2"
  local last_iso
  last_iso="$(date -r "$last_mounted_ts" '+%Y-%m-%d %H:%M')"
  log "warning: backup disk missing for $days_missing day(s) (last seen $last_iso)"
  if command -v terminal-notifier >/dev/null 2>&1; then
    terminal-notifier \
      -title "Kopia Backup" \
      -subtitle "Backup-Platte fehlt seit ${days_missing} Tagen" \
      -message "Letztes Backup: ${last_iso}. Platte 'Backups' anschließen." \
      -group "dev.rubeen.kopia.snapshot" \
      >/dev/null 2>&1 || log "warning: terminal-notifier exited non-zero"
  else
    log "warning: terminal-notifier not installed — skipping desktop notification"
  fi
  date +%s > "$LAST_WARNED"
}

# --- disk not mounted: silent skip, with throttled warn after 5 days ---
if [ ! -d "$REPO_PATH" ]; then
  log "skip: $REPO_PATH not mounted"
  # Only warn if we've ever had a successful backup (otherwise this is fresh install).
  if [ -r "$LAST_MOUNTED" ]; then
    last_mounted_ts="$(cat "$LAST_MOUNTED")"
    now="$(date +%s)"
    delta=$(( now - last_mounted_ts ))
    if [ "$delta" -ge $(( WARN_AFTER_DAYS * 86400 )) ]; then
      days_missing=$(( delta / 86400 ))
      # Rate-limit: only warn once per cooldown window.
      if [ -r "$LAST_WARNED" ]; then
        last_warned_ts="$(cat "$LAST_WARNED")"
        if [ $(( now - last_warned_ts )) -lt $(( WARN_COOLDOWN_HOURS * 3600 )) ]; then
          log "warned recently, skipping notification"
          exit 0
        fi
      fi
      notify_disk_missing "$last_mounted_ts" "$days_missing"
    fi
  fi
  exit 0
fi

# --- disk mounted: run backup ---
[ -r "$PW_FILE" ] || { log "error: password file not readable: $PW_FILE"; exit 1; }
export KOPIA_PASSWORD
KOPIA_PASSWORD="$(cat "$PW_FILE")"

log "starting snapshot of $SOURCE"
if ! kopia repository status >/dev/null 2>&1; then
  log "repository not connected, reconnecting"
  kopia repository connect filesystem --path="$REPO_PATH" >> "$LOG" 2>&1 \
    || { log "error: repository connect failed"; exit 1; }
fi
if kopia snapshot create "$SOURCE" --no-progress >> "$LOG" 2>&1; then
  log "snapshot complete"
  date +%s > "$LAST_MOUNTED"
  rm -f "$LAST_WARNED"
else
  log "error: snapshot failed (exit $?)"
  exit 1
fi
