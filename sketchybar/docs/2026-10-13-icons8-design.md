# Icons8-Symbole für die ganze Bar

Stand: 13.10.2026. Vorbild ist das Zunder-Widget (`items/zunder.lua`, ZUN-8), das als erstes Item ein
eingefärbtes Icons8-SVG zeigt.

## Ziel

Alle Symbole der Bar kommen einheitlich aus dem Icons8-Stil **iOS Glyph** und werden wie bisher nach
Zustand eingefärbt. Fehlt eine Datei, zeigt das Item weiter die SF-Symbol-Glyphe.

Voraussetzung ist mbar ab 0.8: `background.image.color` färbt ein Bild durch seinen Alpha-Kanal ein,
SVG wird über AppKit in Retina-Auflösung gerastert. `scale` streckt das Raster nur, deshalb steht die
Zielgröße im SVG selbst.

## Nicht dabei

- App-Icons in den Spaces (eigene Icon-Schrift)
- Apple-Logo (Marke, Icons8 ersetzt es nicht)
- NerdFont-Tabelle in `icons.lua`, sie bleibt Rückfall für `settings.icons = "NerdFont"`
- Texte in Popups, die im `icon`-Feld stehen (Titelspalten)

## Aufbau

| Teil | Ort | Inhalt |
|---|---|---|
| Manifest | `sketchybar/icons8.tsv` (Repo) | eine Zeile je Symbol: `name`, Icons8-ID, Größe in pt (Standard 16) |
| Dateien | `~/.config/mbar/icons/<name>.svg` (außerhalb des Repos) | SVG mit gesetztem `width`/`height` |
| Helfer | `sketchybar/helpers/svg_icon.lua` | `svg.icon(name, color)`, `svg.color(name, color)` |
| Rückfall | `sketchybar/icons.lua` | unverändert |

Die Namen im Manifest folgen den Schlüsseln aus `icons.lua` (`battery._75`, `weather.rain`,
`switch.on` …). Das Repo ist öffentlich und enthält deshalb nur Zuordnungen, keine Icons8-Dateien.

### Helfer

- `svg.icon(name, color)` liefert die vollständige `icon`-Tabelle. Mit Datei: `string = ""`,
  `background = { drawing = true, color = transparent, image = { string = <pfad>, color = color } }`.
  Ohne Datei: `string = <glyphe aus icons.lua>`, `color = color`, `background = { drawing = false }`,
  damit ein Wechsel zwischen beiden Varianten keine Reste hinterlässt.
- `svg.color(name, color)` liefert nur die Farbänderung für den Zustand, ohne das Bild neu zu laden.
- Ob eine Datei existiert, prüft der Helfer einmal je Name beim Laden der Config (`io.open`). Neue
  Dateien wirken nach `sbar`.

### Items

Jede Stelle, die heute `icon = icons.x` oder `icon = { color = … }` setzt, geht über den Helfer.
Items, die ihren Zustand am angezeigten Zeichen ablesen (z. B. `items/spaces.lua:240`,
`query().icon.value == icons.switch.on`), führen ihn stattdessen in einer Lua-Variable, weil `string`
mit SVG leer ist. `items/zunder.lua` wird auf den Helfer umgestellt.

## Abruf

Kein eigenes Skript und kein API-Key im System: Claude ruft die SVGs über den Icons8-MCP ab.

1. `icons8.tsv` lesen.
2. Je Zeile `get_icon_svg(<id>)`, `width`/`height` auf die Größe setzen (`viewBox` bleibt).
3. Mit `NSImage` prüfen, ob die Datei lesbar ist (derselbe Lader wie in mbar). Nur dann atomar nach
   `~/.config/mbar/icons/<name>.svg` schreiben. Ein unlesbares SVG ließe das Symbol unsichtbar, ein
   fehlendes fällt dagegen auf die Glyphe zurück.
4. Lehnt Icons8 ab (Limit: 100 SVGs pro Stunde), die genannte Zeit warten und fortsetzen.

Auf einem neuen Rechner reicht „Icons abrufen“: Claude arbeitet das Manifest ab.

## Auswahl der Symbole

Für jeden Namen sucht Claude einen Kandidaten im Stil iOS Glyph (`platform = ios11`). Vor dem Ablegen
zeigt ein Übersichtsbild alle Kandidaten eingefärbt auf der Bar-Farbe; Ruben tauscht unpassende aus.
Erst danach entstehen Manifest und Dateien.

## Prüfung

- Lua-Selbsttest `helpers/svg_icon_test.lua` (Muster `helpers/otp_test.lua`): Name mit Datei, Name
  ohne Datei, Farbwechsel.
- `sbar` neu laden, `mbar --query` der umgestellten Items ohne Lua-Fehler.
- Jedes Item per Screenshot in der echten Leiste ansehen; zustandsabhängige Symbole von Hand
  umschalten (`mbar --set …`) und danach `mbar --update`.
