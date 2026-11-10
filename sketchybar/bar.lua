local colors = require("colors")

-- Equivalent to the --bar domain
sbar.bar({
  -- "on" legt die Bar über die macOS-Menüleiste (Ebene 25 statt 3). Die Leiste
  -- bleibt eingeblendet: ausgeblendet fängt macOS 27 Klicks in den oberen 39 pt
  -- ab, und die Items reagieren erst beim zweiten Klick.
  topmost = "on",
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
