local colors = require("colors")
local settings = require("settings")

-- Irrlicht-Sessions in der Bar.
--
-- Ein 'alias'-Item (das Menüleistensymbol der App spiegeln) scheidet aus:
-- sketchybar erkennt nur klassische NSStatusItem-Icons, Irrlicht rendert sein
-- Menüleisten-Item anders und taucht in `sketchybar --query
-- default_menu_items` gar nicht erst auf. Stattdessen wird hier direkt die
-- Datenquelle angezapft, die auch das Menü der App füllt.
--
-- Der Zustand, der zum Handeln auffordert, ist 'waiting' — eine Session
-- wartet auf eine Antwort. Er bestimmt deshalb die Farbe; 'working' läuft von
-- allein weiter.

local IRRLICHT = "/Applications/Irrlicht.app/Contents/MacOS/irrlicht-ls"

-- Gibt "<working> <waiting> <gesamt>" aus; bei fehlendem Binary oder
-- kaputter Ausgabe bleibt die Zeile leer und das Item blendet sich aus.
local COUNT_CMD = IRRLICHT .. [[ -format json 2>/dev/null | /usr/bin/python3 -c 'import sys,json
try: d = json.load(sys.stdin)
except Exception: raise SystemExit
s = [a.get("state") for g in (d.get("groups") or []) for a in (g.get("agents") or [])]
print(s.count("working"), s.count("waiting"), len(s))' 2>/dev/null]]

local irrlicht = sbar.add("item", "irrlicht", {
  position = "right",
  icon = {
    string = "􀫥",
    color = colors.grey,
    padding_right = 4,
  },
  label = {
    font = {
      family = settings.font.numbers,
      style = settings.font.style_map["Bold"],
    },
    color = colors.grey,
  },
  update_freq = 5,
  click_script = "open -a Irrlicht",
})

local function update()
  sbar.exec(COUNT_CMD, function(out)
    local working, waiting, total = string.match(out or "", "(%d+)%s+(%d+)%s+(%d+)")
    if not total then
      irrlicht:set({ drawing = false })
      return
    end

    working, waiting, total = tonumber(working), tonumber(waiting), tonumber(total)

    local color = colors.grey
    if waiting > 0 then
      color = colors.yellow
    elseif working > 0 then
      color = colors.blue
    end

    irrlicht:set({
      drawing = total > 0,
      icon = { color = color },
      label = {
        string = waiting > 0 and (waiting .. "/" .. total) or tostring(total),
        color = color,
      },
    })
  end)
end

irrlicht:subscribe("routine", update)
irrlicht:subscribe("forced", update)
update()
