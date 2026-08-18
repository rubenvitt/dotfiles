local colors = require("colors")
local settings = require("settings")

-- Irrlicht-Sessions in der Bar, mit Popup-Liste.
--
-- Ein 'alias'-Item (das Menüleistensymbol der App spiegeln) scheidet aus:
-- sketchybar erkennt nur klassische NSStatusItem-Icons; Irrlicht taucht in
-- `sketchybar --query default_menu_items` gar nicht erst auf. Stattdessen
-- wird der lokale Daemon direkt abgefragt — dieselbe Quelle, aus der sich
-- auch das Menü der App speist.
--
-- Nicht enthalten: das Wochen-/Tageslimit des Abos. Der Daemon kennt es
-- nicht (limits/usage/quota/account antworten mit 404), er schätzt nur
-- Kosten. Die Tagesschätzung steht deshalb als Schätzung im Popup; die
-- Wochensumme der API ist unbrauchbar (sie zählt kumulative Werte je
-- Bucket erneut und liegt um Größenordnungen daneben).

local API = "http://127.0.0.1:7837/api/v1"
local MENU_URL = "http://127.0.0.1:7837/"
local FOCUS = "/Applications/Irrlicht.app/Contents/MacOS/irrlicht-focus"
local MAX_ROWS = 10
local POPUP_WIDTH = 300

-- Erste Zeile: "<working> <waiting> <gesamt>", danach je Session eine Zeile
-- "<session-id>|<state>|<projekt>". Sortiert nach Dringlichkeit, damit die
-- wartenden Sessions oben stehen.
local SESSIONS_CMD = "curl -s --max-time 3 " .. API .. "/sessions | /usr/bin/python3 -c " .. [['import sys, json
try: d = json.load(sys.stdin)
except Exception: raise SystemExit
rows = []
for g in (d.get("groups") or []):
    for a in (g.get("agents") or []):
        rows.append((a.get("state") or "", a.get("session_id") or "", a.get("project_name") or g.get("name") or "?"))
order = {"waiting": 0, "working": 1, "ready": 2}
rows.sort(key=lambda r: (order.get(r[0], 9), r[2]))
states = [r[0] for r in rows]
print(states.count("working"), states.count("waiting"), len(rows))
for state, sid, project in rows[:%d]:
    print("%%s|%%s|%%s" %% (sid, state, project))']]

SESSIONS_CMD = string.format(SESSIONS_CMD, MAX_ROWS)

local COST_CMD = "curl -s --max-time 3 " .. API .. "/history?range=day\\&chart=cost | /usr/bin/python3 -c " .. [['import sys, json
try: print("%.2f" % json.load(sys.stdin).get("total", 0.0))
except Exception: raise SystemExit']]

local STATE_COLOR = {
  waiting = colors.yellow,
  working = colors.blue,
  ready = colors.green,
}

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
  popup = {
    align = "right",
    background = {
      border_width = 2,
      border_color = colors.popup.border,
      color = colors.popup.bg,
      corner_radius = 9,
    },
  },
  click_script = "sketchybar --set irrlicht popup.drawing=toggle",
})

-- Kopfzeile: geschätzte Tageskosten. Eigenes Update-Intervall, die Zahl
-- ändert sich träge und hängt an einem anderen Endpunkt.
local cost = sbar.add("item", "irrlicht.cost", {
  position = "popup.irrlicht",
  update_freq = 60,
  icon = {
    string = "heute (geschätzt)",
    width = POPUP_WIDTH / 2,
    align = "left",
    color = colors.grey,
  },
  label = {
    string = "—",
    width = POPUP_WIDTH / 2,
    align = "right",
    font = { family = settings.font.numbers },
  },
})

-- Feste Zeilen-Reserve: Items im Update-Callback anzulegen würde bei jedem
-- Durchlauf neue erzeugen (siehe items/menus.lua, gleiches Muster).
local rows = {}
for i = 1, MAX_ROWS do
  rows[i] = sbar.add("item", "irrlicht.session." .. i, {
    position = "popup.irrlicht",
    drawing = false,
    icon = {
      string = "●",
      padding_right = 6,
      color = colors.grey,
    },
    label = {
      string = "",
      width = POPUP_WIDTH - 20,
      align = "left",
    },
  })
end

-- Fußzeile: öffnet die Oberfläche des Daemons, also den Inhalt des
-- Menüleisten-Fensters, im Browser.
sbar.add("item", "irrlicht.menu", {
  position = "popup.irrlicht",
  icon = {
    string = "􀉪",
    padding_right = 6,
    color = colors.grey,
  },
  label = {
    string = "Irrlicht öffnen",
    width = POPUP_WIDTH - 20,
    align = "left",
  },
  click_script = "open " .. MENU_URL .. "; sketchybar --set irrlicht popup.drawing=off",
})

local function update()
  sbar.exec(SESSIONS_CMD, function(out)
    local lines = {}
    for line in string.gmatch(out or "", "[^\r\n]+") do
      lines[#lines + 1] = line
    end

    local working, waiting, total = string.match(lines[1] or "", "(%d+)%s+(%d+)%s+(%d+)")
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

    for i = 1, MAX_ROWS do
      local line = lines[i + 1]
      -- Nur alphanumerische IDs mit Bindestrich weiterreichen — deckt die
      -- UUIDs der Claude-Code-Sessions ab wie auch die kurzen proc-IDs
      -- fertiger Sessions, und nichts davon kann ein click_script verlassen.
      local sid, state, project = string.match(line or "", "^([%w%-]+)|([%a]*)|(.*)$")
      if sid then
        rows[i]:set({
          drawing = true,
          icon = { color = STATE_COLOR[state] or colors.grey },
          label = { string = project .. "  " .. state },
          click_script = FOCUS .. " " .. sid .. "; sketchybar --set irrlicht popup.drawing=off",
        })
      else
        rows[i]:set({ drawing = false })
      end
    end
  end)
end

local function update_cost()
  sbar.exec(COST_CMD, function(out)
    local value = string.match(out or "", "[%d%.]+")
    cost:set({ label = { string = value and ("$" .. value) or "—" } })
  end)
end

irrlicht:subscribe("routine", update)
irrlicht:subscribe("forced", update)
cost:subscribe("routine", update_cost)
cost:subscribe("forced", update_cost)

update()
update_cost()
