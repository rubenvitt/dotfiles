local settings = require("settings")

-- Irrlicht-Menüleisten-Item in die Bar spiegeln.
--
-- Die Sketchybar liegt über der macOS-Menüleiste, deren Icons damit verdeckt
-- sind. Ein 'alias'-Item zeichnet das Original an eine frei wählbare Stelle
-- der Bar. Das setzt die Berechtigung "Bildschirmaufnahme" für Sketchybar
-- voraus (Systemeinstellungen → Datenschutz & Sicherheit); ohne sie bleibt
-- das Item leer und `sketchybar --query default_menu_items` meldet den
-- fehlenden Zugriff. Nach dem Erteilen muss Sketchybar neu starten, ein
-- --reload genügt nicht.
--
-- Der Alias-Name ist der Prozessname der App; für Apps mit mehreren
-- Menüleisten-Items lautet er "Owner,Item-Titel" (siehe man sketchybar).
-- Ohne gesetzte alias-Farbe behält das Item sein Original-Aussehen.

sbar.add("alias", "Irrlicht", {
  position = "right",
  padding_left = settings.paddings,
  padding_right = settings.paddings,
  update_freq = 5,
  background = { drawing = false },
})
