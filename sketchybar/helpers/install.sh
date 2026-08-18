#!/bin/bash
# Einmaliges Setup für diese Sketchybar-Konfiguration.
# Die Brew-Pakete stehen auch im Brewfile — hier bleiben sie, damit die
# Config eigenständig aufsetzbar ist.

set -euo pipefail

# Packages
brew tap felixkratz/formulae
brew install lua switchaudio-osx nowplaying-cli
brew install sketchybar borders

# Fonts.
# sf-symbols/font-sf-* sind pkg-Installer und fragen nach dem Admin-Passwort —
# dieser Schritt läuft nicht unbeaufsichtigt durch.
brew install --cask sf-symbols font-sf-mono font-sf-pro

curl -L https://github.com/kvndrsslr/sketchybar-app-font/releases/download/v2.0.36/sketchybar-app-font.ttf \
  -o "$HOME/Library/Fonts/sketchybar-app-font.ttf"

# SbarLua — die Lua-Bindings, die sketchybarrc erwartet.
# Landet in ~/.local/share/sketchybar_lua/sketchybar.so (Pfad steckt in helpers/init.lua).
(git clone https://github.com/FelixKratz/SbarLua.git /tmp/SbarLua \
  && cd /tmp/SbarLua/ && make install && rm -rf /tmp/SbarLua/)

# Helper-Binaries (cpu_load, network_load, menus) bauen
make -C "$(dirname "$0")"

echo
echo "Fertig. Start:  brew services start felixkratz/formulae/sketchybar"
echo "Sketchybar braucht dieselbe Bedienungshilfen-Berechtigung wie AeroSpace"
echo "(helpers/menus liest die Menüleiste über die Accessibility-API)."
