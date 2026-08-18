# photobackup — Design

**Datum:** 2026-07-23
**Status:** genehmigt, Implementierung

## Ziel

Vollständiges, nach Jahr sortiertes Backup der iCloud-Fotomediathek auf eine
externe Platte — inklusive der Originale, die durch „Mac-Speicher optimieren"
nur als Platzhalter auf dem Mac liegen.

## Ausgangslage (ermittelt am 2026-07-23)

- Mediathek: `~/Pictures/Photos Library.photoslibrary`
- **104.500 Assets** laut Photos-DB (101.610 Fotos, 2.890 Videos)
- Nur **~24.000 Originale (63 GB)** tatsächlich auf dem Mac; **~80.000** liegen
  nur in der iCloud → „Mac-Speicher optimieren" ist aktiv.
- Interne Platte: nur **~48 GB frei** → ein kompletter Download *auf den Mac*
  ist unmöglich; Originale müssen beim Export gestreamt werden.
- Ziel: `/Volumes/Backups` (3,2 TB frei, keine Time-Machine-Platte).

## Warum osxphotos statt rsync/cp

Die Originale liegen unter `originals/` nach UUID, nicht nach Datum; ~77 % sind
gar nicht auf der Platte. `rsync`/`cp` können weder nach Aufnahmedatum sortieren
noch fehlende Originale aus der iCloud laden. `osxphotos` liest die Photos-DB,
kennt das echte (auch manuell korrigierte) Aufnahmedatum, lädt fehlende
Originale (`--download-missing`) und ist per `--update` wiederaufsetzbar.

## Kern-Kommando

```bash
osxphotos export "$DEST" \
  --library "$HOME/Pictures/Photos Library.photoslibrary" \
  --directory "{created.year}" \
  --download-missing --use-photokit \
  --update \
  --sidecar xmp \
  --retry 3 \
  --report "$LOGDIR/report-<timestamp>.csv" \
  --verbose --timestamp
```

- Bearbeitete Versionen (`_edited`) und Live-Photo-`.mov` exportiert osxphotos
  standardmäßig mit.
- Ergebnisstruktur: `$DEST/2007/…`, `$DEST/2008/…`

## Wrapper-Sicherheitsnetze (das eigentliche Skript)

1. **Vorab-Checks:** `osxphotos` vorhanden? Zielvolume gemountet & beschreibbar?
   Mediathek vorhanden?
2. **Speicher-Wächter:** Hintergrund-Watchdog prüft alle 60 s den freien Platz
   der *internen* Platte; fällt er unter `PHOTOBACKUP_MIN_FREE_GB` (Default 15),
   wird der Export per SIGINT sauber gestoppt (dank `--update` fortsetzbar).
3. **`caffeinate -i`** hält den Mac während des tagelangen Downloads wach.
4. **Logging:** zeitgestempeltes Logfile + `report.csv` auf der Zielplatte.
5. **Wiederaufsetzbar:** einfach erneut starten → macht via Export-DB weiter.

## Erwartungen

Erst-Lauf lädt ~210+ GB über die Internetleitung; je nach Bandbreite mehrere
Stunden bis Tage, Apple drosselt große iCloud-Downloads. Abbrechen & Fortsetzen
ist deshalb Kernanforderung, kein Nice-to-have.

## Nicht im Scope

- Kein `--cleanup` (löscht Ziel-Dateien, die nicht mehr in der Mediathek sind) —
  bewusst weggelassen, um versehentliche Löschungen auf der geteilten Platte
  auszuschließen.
- Kein automatisches Installieren von `osxphotos` — nur Hinweis.
