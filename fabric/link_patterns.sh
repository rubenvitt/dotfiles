#!/bin/bash

CUSTOM_PATTERNS_DIR="$HOME/.config/fabric/custom_patterns"
PATTERNS_DIR="$HOME/.config/fabric/patterns"

echo "Verknüpfe Muster von $CUSTOM_PATTERNS_DIR nach $PATTERNS_DIR"

# Stelle sicher, dass das Zielverzeichnis existiert
mkdir -p "$PATTERNS_DIR"

# Entferne bestehende Links im Zielverzeichnis
find "$PATTERNS_DIR" -type l -delete

# Durchlaufe alle Einträge im custom_patterns Verzeichnis
for item in "$CUSTOM_PATTERNS_DIR"/*; do
    if [ -d "$item" ]; then
        name=$(basename "$item")
        echo "Erstelle Link für $name"
        ln -s "$item" "$PATTERNS_DIR/$name"
    fi
done

echo "Fertig. Hier sind die erstellten Links:"
ls -l "$PATTERNS_DIR"
