return {
  paddings = 3,
  group_paddings = 5,

  icons = "sf-symbols", -- alternatively available: NerdFont

  -- Auf welchem Display die "schweren" Items laufen. Sketchybar zeichnet die
  -- Bar zwar auf allen Displays, aber Bar-Geometrie (height, y_offset, color)
  -- ist global — nur einzelne Items lassen sich per display= begrenzen.
  -- Die Nummer ist der 1-basierte Display-Index; abfragen laesst sie sich
  -- nicht, aber 1 ist der Hauptmonitor — am Schreibtisch der linke PA279CRV
  -- (per Screenshot des Bar-Streifens bei x=0 gegengeprueft).
  -- Sitzen die Widgets auf dem falschen Monitor: hier auf 2 drehen, das ist
  -- die einzige Stelle.
  -- Auf der Zweit-Bar bleiben nur Workspaces, Front-App/Menues und die Uhr.
  primary_display = 1,

  -- This is a font configuration for SF Pro and SF Mono (installed manually)
  font = require("helpers.default_font"),

  -- Alternatively, this is a font config for JetBrainsMono Nerd Font
  -- font = {
  --   text = "JetBrainsMono Nerd Font", -- Used for text
  --   numbers = "JetBrainsMono Nerd Font", -- Used for numbers
  --   style_map = {
  --     ["Regular"] = "Regular",
  --     ["Semibold"] = "Medium",
  --     ["Bold"] = "SemiBold",
  --     ["Heavy"] = "Bold",
  --     ["Black"] = "ExtraBold",
  --   },
  -- },
}
