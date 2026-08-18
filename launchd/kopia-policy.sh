#!/bin/bash
# kopia-policy.sh - declarative, idempotent Kopia-Policy-Setup.
#
# Setzt globale Ignore-Regeln. Aufruf manuell oder aus mac-setup.sh.
# Bestehende Regeln werden via `--add-ignore` ergaenzt (Kopia dedupliziert);
# Regeln, die hier entfernt werden, bleiben in der Policy bestehen, bis sie
# manuell via `kopia policy set --global --remove-ignore=...` entfernt werden.

set -euo pipefail

REPO_PATH="/Volumes/Backups/kopia-r-mac"
PW_FILE="$HOME/.config/kopia/.password"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

if [ ! -d "$REPO_PATH" ]; then
  echo "error: backup disk not mounted at $REPO_PATH" >&2
  exit 1
fi
[ -r "$PW_FILE" ] || { echo "error: password file not readable: $PW_FILE" >&2; exit 1; }

export KOPIA_PASSWORD
KOPIA_PASSWORD="$(cat "$PW_FILE")"

if ! kopia repository status >/dev/null 2>&1; then
  echo "repository not connected, reconnecting"
  kopia repository connect filesystem --path="$REPO_PATH"
fi

# Single source of truth fuer Ignore-Regeln (Pfade relativ zum Snapshot-Root).
# Gruppiert nach Thema. Keine Duplikate hinzufuegen.
IGNORES=(
  # generic build/cache markers
  "*.pyc"
  "*.pyo"
  ".DS_Store"
  ".cache"
  ".env.local"
  "__pycache__"
  "build"
  "dist"
  "node_modules"
  "target"
  "venv"

  # macOS metadata
  ".DocumentRevisions-V100"
  ".Spotlight-V100"
  ".TemporaryItems"
  ".Trash"
  ".Trashes"
  ".fseventsd"

  # language toolchains / package caches
  ".bundle"
  ".cargo/registry"
  ".gradle"
  ".kube/cache"
  ".next"
  ".npm"
  ".nuxt"
  ".parcel-cache"
  ".pnpm-store"
  ".rustup"
  ".svelte-kit"
  ".terraform"
  ".turbo"
  ".venv"
  ".yarn/cache"
  "go/pkg"

  # JetBrains
  "IdeaSnapshots/"
  "Library/Application Support/JetBrains"

  # macOS system Library noise
  "Library/Accounts"
  "Library/Application Support/CrashReporter"
  "Library/Application Support/com.apple.TCC"
  "Library/Application Support/com.apple.sharedfilelist"
  "Library/Application Support/com.apple.spotlight"
  "Library/Assistant"
  "Library/Biome"
  "Library/Caches"
  "Library/Calendars"
  "Library/Cookies"
  "Library/CoreFollowUp"
  "Library/Daemon Containers"
  "Library/Developer"
  "Library/Developer/CoreSimulator"
  "Library/Developer/Xcode/DerivedData"
  "Library/DuetExpertCenter"
  "Library/Family"
  "Library/HTTPStorages"
  "Library/HomeKit"
  "Library/IdentityServices"
  "Library/IntelligencePlatform"
  "Library/Java"
  "Library/Keychains"
  "Library/Logs"
  "Library/Mail"
  "Library/Messages"
  "Library/Metadata/CoreSpotlight"
  "Library/PersonalizationPortrait"
  "Library/Photos"
  "Library/PreferencePanes"
  "Library/Reminders"
  "Library/Safari"
  "Library/SafariSafeBrowsing"
  "Library/Sharing"
  "Library/Shortcuts"
  "Library/StatusKit"
  "Library/Suggestions"
  "Library/Sync"
  "Library/Tips"
  "Library/Translation"
  "Library/Trial"
  "Library/UnifiedAssetFramework"
  "Library/Voice Trigger"
  "Library/Weather"
  "Library/com.apple.aiml.instrumentation"
  "Library/pnpm"

  # Apple Containers / Group Containers
  "Library/Containers/*com.apple*"
  "Library/Containers/com.apple"
  "Library/Containers/com.apple*"
  "Library/Group Containers/*com.apple*"
  "Library/Group Containers/group.com.apple*"

  # iCloud (Mirror, ohnehin in der Cloud)
  "Library/CloudStorage"
  "Library/Application Support/CloudDocs"
  "Library/Application Support/FileProvider"
  "Library/Mobile Documents"

  # Google / Drive / Razer / Steam / Minecraft / MacWhisper / Zed / Claude
  "Library/Application Support/Claude"
  "Library/Application Support/Google"
  "Library/Application Support/MacWhisper"
  "Library/Application Support/Steam"
  "Library/Application Support/Zed"
  "Library/Application Support/minecraft"
  "Library/Razer"
  "Library/Thunderbird"

  # Container-Runtimes (Docker/Orbstack)
  "Library/Application Support/Docker Desktop"
  "Library/Containers/*orbstack*"
  "Library/Containers/com.docker.docker"
  "Library/Group Containers/*orbstack*"
  "Library/Group Containers/group.com.docker"
  "OrbStack"
  "OrbStack/"
  "Parallels/"

  # Kopia mountpoints
  "kopia-mount"
  "kopia-mount/"

  # Photos Library: lokaler iCloud-Photos-Mirror, bringt ohne iCloud-Auth nichts
  "Pictures/Photos Library.photoslibrary"

  # Wallpaper-Caches (mehrere GB Apple-eigene Renderings)
  "Library/Application Support/com.apple.wallpaper"
)

echo "Applying ${#IGNORES[@]} ignore rules to global Kopia policy..."
for rule in "${IGNORES[@]}"; do
  kopia policy set --global --add-ignore="$rule" >/dev/null
done
echo "Done."
