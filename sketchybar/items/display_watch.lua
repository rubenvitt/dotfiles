local settings = require("settings")

-- Kompakt- oder Expanded-Modus wird einmal beim Laden der Config aus der
-- Display-Breite abgeleitet (helpers/system_info.lua). Kommt danach ein
-- externer Monitor dazu oder geht weg, stimmt die Bar nicht mehr — also
-- neu laden, aber nur, wenn der Modus wirklich kippen wuerde. display_change
-- feuert naemlich mehrfach pro An-/Abstecken, und jeder Reload kostet unter
-- Last Sekunden.
--
-- Die Pruefung laeuft komplett in der Shell: ein io.popen nach dem ersten
-- Fork haengt (siehe system_info.lua), sbar.exec ist asynchron und sicher.
-- Das nohup + & ist noetig, weil `--reload` genau den Lua-Prozess killt, aus
-- dem der Befehl abgesetzt wurde — der Reload muss ihn ueberleben.

local compact_now = settings.compact and "true" or "false"
local sbar_tool = os.getenv("HOME") .. "/.dotfiles/r-tools/sbar"

local check = table.concat({
  "compact=$(sketchybar --query displays | jq -r '([.[].frame.w] | max) < 2500')",
  -- Leere Antwort (Bar gerade mitten im Reload) ist kein Moduswechsel.
  '[ -z "$compact" ] && exit 0',
  '[ "$compact" = "' .. compact_now .. '" ] && exit 0',
  "nohup " .. sbar_tool .. " reload >/dev/null 2>&1 &",
}, "; ")

local watch = sbar.add("item", "display_watch", {
  drawing = false,
  updates = true,
})

watch:subscribe("display_change", function()
  sbar.exec(check)
end)
