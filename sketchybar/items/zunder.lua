local colors = require("colors")
local icons = require("icons")
local settings = require("settings")

-- Fällige Zunder-Aufgaben in der Bar, die Liste im Popup.
--
-- Gezeigt wird nur, was heute fällig oder schon überfällig ist -- alles
-- Spätere gehört in den Kalender, nicht in die Menüleiste. Ohne offene
-- Aufgaben verschwindet das Item ganz: ein Widget, das dauerhaft "0" anzeigt,
-- kostet Platz und sagt nichts.
--
-- Die große Zahl ist bewusst die der heute fälligen Aufgaben, nicht die des
-- Rückstands. Als Leitzahl stünde der Rückstand monatelang rot in der Leiste,
-- und nach zwei Tagen sähe niemand mehr hin. Er hängt deshalb nur als "+n"
-- hinten dran und färbt nichts ein. Rot gibt es allein für heute fällige
-- Aufgaben, deren Uhrzeit schon verstrichen ist -- die einzige Lage, in der
-- ein Blick in die Leiste heute noch etwas ändert.
--
-- Der API-Token liegt außerhalb dieses Repos in ~/.config/zunder/token
-- (chmod 600), weil das Repo öffentlich ist. Fehlt er, bleibt das Widget
-- still unsichtbar. Damit es von selbst auftaucht, sobald die Datei da ist,
-- braucht es updates = true: default.lua setzt "when_shown", und ein Item,
-- das sich per drawing = false ausblendet, würde sonst nie wieder abfragen.
--
-- Abruf und Auswertung stehen in helpers/zunder_probe.py.

local PROBE = "/usr/bin/python3 $CONFIG_DIR/helpers/zunder_probe.py"
local MAX_ROWS = 8

-- Wie in items/weather.lua: die Vorgaben der Bar (13pt, 40 Punkt Zeilenhöhe)
-- erzeugen in einer Liste vor allem Leerraum.
local ROW_FONT = 11.0
local ROW_HEIGHT = 20
local ROW_PAD = 7
-- Zwei feste Spalten je Zeile: nur so stehen die Fälligkeiten untereinander.
-- Die Breite passt zu den 34 Zeichen, auf die der Helfer kürzt.
local TITLE_WIDTH = 200
local DUE_WIDTH = 62

-- Fälligkeiten stehen tage- oder minutengenau fest; niemand muss von der
-- Menüleiste erfahren, dass eine Aufgabe seit dreißig Sekunden fällig ist.
local UPDATE_FREQ = 900

-- now   = heute fällig, Uhrzeit verstrichen
-- today = heute fällig
-- late  = Rückstand aus früheren Tagen; grau, weil eine Ampelfarbe hier nur
--         abstumpfen würde
local STATE_COLOR = {
  now = colors.red,
  today = colors.yellow,
  late = colors.grey,
}

local zunder = sbar.add("item", "zunder", {
  display = settings.primary_display,
  position = "right",
  -- Startet unsichtbar: der erste Abruf läuft asynchron an.
  drawing = false,
  updates = true,
  icon = {
    string = icons.clipboard,
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
  update_freq = UPDATE_FREQ,
  popup = {
    align = "right",
    height = ROW_HEIGHT,
    background = {
      border_width = 2,
      border_color = colors.popup.border,
      color = colors.popup.bg,
      corner_radius = 9,
    },
  },
  click_script = "sketchybar --set zunder popup.drawing=toggle",
})

-- Feste Reserve statt neuer Items je Durchlauf (siehe items/menus.lua).
-- Eine Popup-Zeile ist ein Item: der Titel steht im icon-Feld, die
-- Fälligkeit im label -- zwei Items je Zeile wären zwei Zeilen.
local rows = {}
for i = 1, MAX_ROWS do
  rows[i] = sbar.add("item", "zunder.task." .. i, {
    position = "popup.zunder",
    drawing = false,
    padding_left = ROW_PAD,
    padding_right = ROW_PAD,
    icon = {
      string = "",
      width = TITLE_WIDTH,
      align = "left",
      padding_left = ROW_PAD,
      padding_right = 0,
      color = colors.white,
      font = { family = settings.font.text, size = ROW_FONT },
    },
    label = {
      string = "",
      width = DUE_WIDTH,
      align = "right",
      padding_left = 0,
      padding_right = ROW_PAD,
      font = { family = settings.font.numbers, size = ROW_FONT },
    },
  })
end

-- Wie viele Abrufe hintereinander misslungen sind. Ein einzelner Fehler darf
-- den Stand stehen lassen; hält er an -- widerrufener Token, dauerhaft kein
-- Netz --, ist die Zahl nur noch Erinnerung und verliert ihre Farbe.
local misses = 0
local STALE_AFTER = 4  -- vier Fehlversuche, also rund eine Stunde

local function update()
  sbar.exec(PROBE, function(out)
    local counts, tasks = nil, {}
    for line in string.gmatch(out or "", "[^\r\n]+") do
      if string.match(line, "^T|") then
        tasks[#tasks + 1] = line
      elseif not counts then
        counts = line
      end
    end

    -- Kein Token: still verschwinden, kein Fehler, keine Log-Zeile.
    if counts == "OFF" then
      misses = 0
      zunder:set({ drawing = false })
      for i = 1, MAX_ROWS do rows[i]:set({ drawing = false }) end
      return
    end

    local today, late, urgent = string.match(counts or "", "^C|(%d+)|(%d+)|(%d+)$")
    -- ERR oder Unfug: der letzte bekannte Stand bleibt stehen.
    if not today then
      misses = misses + 1
      if misses == STALE_AFTER then
        -- Nicht schlicht grau: Grau ist die normale Farbe des Rückstands, ein
        -- veralteter Stand sähe damit aus wie ein gesunder.
        local stale = colors.with_alpha(colors.grey, 0.5)
        zunder:set({ icon = { color = stale }, label = { color = stale } })
      end
      return
    end
    misses = 0
    today, late, urgent = tonumber(today), tonumber(late), tonumber(urgent)

    local label, color
    if today > 0 then
      label = tostring(today) .. (late > 0 and ("+" .. late) or "")
      color = urgent > 0 and colors.red or colors.yellow
    else
      label = "+" .. late
      color = colors.grey
    end

    zunder:set({
      drawing = (today + late) > 0,
      icon = { color = color },
      label = { string = label, color = color },
    })

    for i = 1, MAX_ROWS do
      local state, due, url, title =
        string.match(tasks[i] or "", "^T|(%a+)|([^|]*)|([^|]*)|(.*)$")
      if state then
        -- Die URL landet in einer Shell. Der Helfer baut sie nur aus einer
        -- geprüften ID, hier noch einmal: nur dieser Host, nur [A-Za-z0-9]
        -- in der ID. Eine Zeile ohne brauchbare Adresse bleibt ohne Klick
        -- sichtbar -- sie zählt zur Zahl in der Leiste.
        local safe = string.match(url, "^https://zunder%.rubeen%.dev/#/aufgabe/%w+$")
        rows[i]:set({
          drawing = true,
          icon = { string = title },
          label = { string = due, color = STATE_COLOR[state] or colors.grey },
          click_script = safe and ("open '" .. url ..
            "'; sketchybar --set zunder popup.drawing=off") or "",
        })
      else
        rows[i]:set({ drawing = false })
      end
    end
  end)
end

zunder:subscribe("routine", update)
zunder:subscribe("forced", update)
-- Nach dem Aufwachen ist der Stand von vor dem Zuklappen meist überholt.
zunder:subscribe("system_woke", update)

update()
