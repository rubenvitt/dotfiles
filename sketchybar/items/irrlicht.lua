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
-- Die Abo-Limits stecken nicht in einem eigenen Endpunkt, sondern je
-- Session unter metrics.rate_limit: ein Fenster über 300 Minuten (5 Std)
-- und eines über 10080 Minuten (7 Tage), jeweils mit Prozentwert und
-- Reset-Zeitpunkt. Gesetzt ist das Feld nur bei Sessions, die zuletzt
-- tatsächlich mit der API gesprochen haben — deshalb gewinnt der Eintrag
-- mit dem jüngsten sampled_at.

local API = "http://127.0.0.1:7837/api/v1"
local MENU_URL = "http://127.0.0.1:7837/"
local FOCUS = "/Applications/Irrlicht.app/Contents/MacOS/irrlicht-focus"
local MAX_ROWS = 10
local POPUP_WIDTH = 300

-- Erste Zeile: "<working> <waiting> <gesamt>", danach je Session eine Zeile
-- "<session-id>|<state>|<projekt>". Sortiert nach Dringlichkeit, damit die
-- wartenden Sessions oben stehen.
local SESSIONS_CMD = "curl -s --max-time 3 " .. API .. "/sessions | /usr/bin/python3 -c " .. [['import sys, json, time
try: d = json.load(sys.stdin)
except Exception: raise SystemExit
rows, limit, sampled = [], None, -1
for g in (d.get("groups") or []):
    for a in (g.get("agents") or []):
        rows.append((a.get("state") or "", a.get("session_id") or "", a.get("project_name") or g.get("name") or "?"))
        rl = (a.get("metrics") or {}).get("rate_limit") or {}
        if rl.get("windows") and rl.get("sampled_at", 0) > sampled:
            sampled, limit = rl["sampled_at"], rl["windows"]
order = {"waiting": 0, "working": 1, "ready": 2}
rows.sort(key=lambda r: (order.get(r[0], 9), r[2]))
states = [r[0] for r in rows]
print(states.count("working"), states.count("waiting"), len(rows))
now = time.time()
for minutes in (300, 10080):
    w = next((x for x in (limit or []) if x.get("window_minutes") == minutes), None)
    if w:
        print("L|%%d|%%d|%%d" %% (minutes, w.get("used_percent", 0), max(0, w.get("resets_at", 0) - now)))
    else:
        print("L|%%d||" %% minutes)
for state, sid, project in rows[:%d]:
    print("S|%%s|%%s|%%s" %% (sid, state, project))']]

SESSIONS_CMD = string.format(SESSIONS_CMD, MAX_ROWS)

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

-- Kopfzeilen: die beiden Limit-Fenster des Abos.
local LIMIT_LABELS = { [300] = "5 Std", [10080] = "Woche" }
local limits = {}
for _, minutes in ipairs({ 300, 10080 }) do
  limits[minutes] = sbar.add("item", "irrlicht.limit." .. minutes, {
    position = "popup.irrlicht",
    icon = {
      string = LIMIT_LABELS[minutes],
      width = POPUP_WIDTH / 3,
      align = "left",
      color = colors.grey,
    },
    label = {
      string = "—",
      width = POPUP_WIDTH / 3 * 2,
      align = "right",
      font = { family = settings.font.numbers },
    },
  })
end

-- Ab 90 Prozent wird es eng, ab 70 lohnt der Blick auf die Uhr.
local function limit_color(percent)
  if percent >= 90 then return colors.red end
  if percent >= 70 then return colors.orange end
  if percent >= 50 then return colors.yellow end
  return colors.green
end

-- Restzeit knapp: Stunden ab einer Stunde, darunter Minuten.
local function human_eta(seconds)
  if seconds >= 86400 then
    return math.floor(seconds / 86400) .. "d " .. math.floor((seconds % 86400) / 3600) .. "h"
  elseif seconds >= 3600 then
    return math.floor(seconds / 3600) .. "h " .. math.floor((seconds % 3600) / 60) .. "m"
  end
  return math.max(0, math.floor(seconds / 60)) .. "m"
end

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

    for _, minutes in ipairs({ 300, 10080 }) do
      local item = limits[minutes]
      local percent, eta
      for _, line in ipairs(lines) do
        local m, p, e = string.match(line, "^L|(%d+)|(%d*)|(%d*)$")
        if m and tonumber(m) == minutes then percent, eta = p, e end
      end
      if percent and percent ~= "" then
        percent = tonumber(percent)
        item:set({
          drawing = true,
          label = {
            string = percent .. "%  ·  " .. human_eta(tonumber(eta) or 0),
            color = limit_color(percent),
          },
        })
      else
        -- Kein Fenster gemeldet: keine Session hat zuletzt mit der API
        -- gesprochen, ein alter Wert wäre irreführend.
        item:set({ drawing = true, label = { string = "—", color = colors.grey } })
      end
    end

    -- Session-Zeilen stehen nach den beiden L-Zeilen.
    local session_lines = {}
    for _, line in ipairs(lines) do
      if string.match(line, "^S|") then session_lines[#session_lines + 1] = line end
    end

    for i = 1, MAX_ROWS do
      local line = session_lines[i]
      -- Nur alphanumerische IDs mit Bindestrich weiterreichen — deckt die
      -- UUIDs der Claude-Code-Sessions ab wie auch die kurzen proc-IDs
      -- fertiger Sessions, und nichts davon kann ein click_script verlassen.
      local sid, state, project = string.match(line or "", "^S|([%w%-]+)|([%a]*)|(.*)$")
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

irrlicht:subscribe("routine", update)
irrlicht:subscribe("forced", update)

update()
