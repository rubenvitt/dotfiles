#!/bin/bash
# kopia-mirror.sh - startet `backup mirror`, sobald alle Bedingungen stimmen:
# Backup-Platte angeschlossen, Netzteil dran, Ethernet-Kabel aktiv.
# Run by launchd (alle 5 Minuten und bei jedem Mount); still, solange eine
# Bedingung fehlt. Fällt Strom oder Kabel während des Laufs weg, wird der
# Spiegel beendet -- `mirror` wertet das als Unterbrechung, der nächste Lauf
# setzt fort.
#
#   kopia-mirror.sh           prüfen und ggf. spiegeln
#   kopia-mirror.sh --check   nur anzeigen, was entschieden würde
set -euo pipefail

REPO_PATH="/Volumes/Backups/kopia-r-mac"
BACKUP="/Users/rubeen/.dotfiles/r-tools/backup"
LOG_DIR="$HOME/Library/Logs/kopia"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/kopia"
# Nach einem erfolgreichen Lauf erst wieder nach diesem Abstand. Schon das
# Auflisten der Blobs dauert über eine Stunde -- stündlich wäre Dauerbetrieb.
MIN_INTERVAL="${MIRROR_MIN_INTERVAL:-21600}"
# Nach einem echten Fehler nicht alle fünf Minuten gegen dieselbe Wand laufen.
ERROR_BACKOFF="${MIRROR_ERROR_BACKOFF:-3600}"
POLL=60

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin"

mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/mirror-trigger-$(date +%Y-%m).log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1
say() { [ "$CHECK" = 1 ] && printf '%s\n' "$*" || true; }

state() { cat "$STATE_DIR/offsite-$1" 2>/dev/null || true; }

# --- Bedingungen ------------------------------------------------------------

disk_ok() { [ -d "$REPO_PATH" ]; }

ac_ok() { pmset -g ps | head -1 | grep -q "AC Power"; }

# ethernet_iface: erstes kabelgebundenes Interface mit Link und IPv4-Adresse.
# Bewusst nicht die Default-Route: mit Tailscale-Exit-Node zeigt sie auf
# utun*, obwohl das Kabel steckt. Ausgewählt nach dem Namen des Hardware-Ports
# ("USB 10/100/1G/2.5G LAN", "Ethernet Adapter (en4)", "Thunderbolt Ethernet"),
# ohne Thunderbolt Bridge.
ethernet_iface() {
  local dev
  for dev in $(networksetup -listallhardwareports | awk '
      /^Hardware Port:/ { port = $0 }
      /^Device:/ && port ~ /Ethernet|LAN/ && port !~ /Bridge/ { print $2 }'); do
    if ifconfig "$dev" 2>/dev/null | grep -q "status: active" \
       && ifconfig "$dev" 2>/dev/null | grep -q "inet "; then
      printf '%s' "$dev"
      return 0
    fi
  done
  return 1
}

mirror_running() { pgrep -f 'kopia repository sync[-]to' >/dev/null 2>&1; }

# due: ist ein neuer Lauf fällig? Gelesen aus den Zustandsdateien von `mirror`.
due() {
  local st now last
  st="$(state status)"
  now="$(date +%s)"
  case "$st" in
    # Unterbrochen, oder hart getötet und nie aus "running" herausgekommen
    # (hier läuft nachweislich nichts, das ist vorher geprüft): weitermachen.
    interrupted|running|"")
      say "fällig: Zustand '${st:-nie gelaufen}'"
      return 0 ;;
    error)
      last="$(state last-attempt)"; last="${last:-0}"
      if [ $(( now - last )) -ge "$ERROR_BACKOFF" ]; then
        say "fällig: letzter Fehler liegt $(( (now - last) / 60 )) min zurück"
        return 0
      fi
      say "nicht fällig: Fehler vor $(( (now - last) / 60 )) min, Backoff $(( ERROR_BACKOFF / 60 )) min"
      return 1 ;;
    *)
      last="$(state last-success)"; last="${last:-0}"
      if [ $(( now - last )) -ge "$MIN_INTERVAL" ]; then
        say "fällig: letzter Erfolg vor $(( (now - last) / 3600 )) h"
        return 0
      fi
      say "nicht fällig: letzter Erfolg vor $(( (now - last) / 60 )) min, Abstand $(( MIN_INTERVAL / 3600 )) h"
      return 1 ;;
  esac
}

# conditions: alle Voraussetzungen außer der Fälligkeit. Setzt $MISSING.
conditions() {
  MISSING=""
  disk_ok || MISSING="$MISSING Platte"
  ac_ok   || MISSING="$MISSING Netzteil"
  ETH="$(ethernet_iface || true)"
  [ -n "$ETH" ] || MISSING="$MISSING Ethernet"
  [ -z "$MISSING" ]
}

# --- Entscheidung -----------------------------------------------------------

if [ "$CHECK" = 1 ]; then
  disk_ok && say "Platte:    ja ($REPO_PATH)" || say "Platte:    nein"
  ac_ok   && say "Netzteil:  ja" || say "Netzteil:  nein"
  e="$(ethernet_iface || true)"
  [ -n "$e" ] && say "Ethernet:  ja ($e)" || say "Ethernet:  nein"
  mirror_running && say "Spiegel:   läuft bereits" || say "Spiegel:   läuft nicht"
fi

if ! conditions; then
  say "=> nichts zu tun, es fehlt:$MISSING"
  exit 0
fi
if mirror_running; then
  say "=> nichts zu tun, ein Spiegel läuft bereits"
  exit 0
fi
if ! due; then
  say "=> nichts zu tun"
  exit 0
fi
if [ "$CHECK" = 1 ]; then
  say "=> würde jetzt spiegeln"
  exit 0
fi

# --- Lauf mit Wächter -------------------------------------------------------

log "Bedingungen erfüllt (Ethernet $ETH), starte backup mirror"
"$BACKUP" mirror >> "$LOG" 2>&1 &
mpid=$!

# Ohne diesen Wächter liefe ein 17-GB-Upload nach dem Abstöpseln über WLAN
# oder Hotspot weiter -- genau das, was die Bedingungen verhindern sollen.
stopped=""
while kill -0 "$mpid" 2>/dev/null; do
  sleep "$POLL"
  kill -0 "$mpid" 2>/dev/null || break
  if ! conditions; then
    stopped="$MISSING"
    log "Bedingung weggefallen:$MISSING -- beende Spiegel"
    kill -TERM "$mpid" 2>/dev/null || true
    break
  fi
done

rc=0
wait "$mpid" || rc=$?

# `mirror` nimmt kopia beim TERM über caffeinate mit. Falls doch etwas übrig
# bleibt, nicht verwaist weiterhochladen lassen.
if [ -n "$stopped" ] && mirror_running; then
  sleep 10
  pkill -TERM -f 'kopia repository sync[-]to' 2>/dev/null || true
  log "kopia nach TERM noch aktiv -- direkt beendet"
fi

log "backup mirror beendet (exit $rc)${stopped:+, abgebrochen wegen:$stopped}"
exit "$rc"
