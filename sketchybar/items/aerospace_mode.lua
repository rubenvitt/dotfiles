local colors = require("colors")
local settings = require("settings")

-- Anzeige des aktiven AeroSpace-Binding-Modus.
--
-- In resize und service gelten die main-Bindings nicht mehr: Tastendrücke
-- laufen ins Leere oder lösen etwas anderes aus, und ohne Anzeige merkt man
-- den Zustand erst daran. Im main-Modus bleibt das Item deshalb unsichtbar --
-- es soll nur den Ausnahmefall melden, nicht dauerhaft Platz belegen.
--
-- Gespeist aus on-mode-changed in aerospace.toml. AeroSpace setzt in diesem
-- Callback keine Variable mit dem neuen Modus, daher fragt der Callback ihn
-- ab und reicht ihn als MODE durch.

local AEROSPACE = "/opt/homebrew/bin/aerospace"

sbar.add("event", "aerospace_mode_change")

local mode = sbar.add("item", "aerospace_mode", {
  display = settings.primary_display,
  position = "left",
  -- default.lua setzt updates = "when_shown"; damit würde das Item nach dem
  -- ersten drawing = false keine Events mehr bekommen und nie zurückkommen.
  updates = true,
  drawing = false,
  icon = { drawing = false },
  label = {
    font = {
      family = settings.font.text,
      style = settings.font.style_map["Bold"],
    },
    color = colors.bg1,
    padding_left = 8,
    padding_right = 8,
  },
  background = {
    color = colors.orange,
    border_color = colors.orange,
  },
})

-- Toleriert den Zeilenumbruch aus list-modes und leere Ausgaben.
local function update(out)
  local name = string.match(out or "", "%S+")
  local active = name ~= nil and name ~= "main"
  mode:set({
    drawing = active,
    label = { string = active and name or "" },
  })
end

mode:subscribe("aerospace_mode_change", function(env)
  update(env.MODE)
end)

-- on-mode-changed feuert beim Start nicht -- Initialzustand selbst holen.
sbar.exec(AEROSPACE .. " list-modes --current", update)
