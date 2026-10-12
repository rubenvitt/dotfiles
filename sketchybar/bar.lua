local colors = require("colors")

-- Equivalent to the --bar domain
sbar.bar({
  topmost = "window",
  height = 40,
  color = colors.bar.bg,
  padding_right = 2,
  padding_left = 2,
  -- Die native Menüleiste ist ausgeblendet, deshalb zeichnet macOS den
  -- Privacy-Punkt (Mikrofon/Kamera/Bildschirmaufnahme) über die Bar und
  -- verdeckt die Uhr. mbar-Erweiterung: rechte Items rücken links neben den
  -- Punkt, solange er sichtbar ist.
  privacy_indicator_inset = true,
})
