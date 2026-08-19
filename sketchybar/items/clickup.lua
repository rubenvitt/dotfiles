local colors = require("colors")
local icons = require("icons")
local settings = require("settings")

-- Faellige ClickUp-Aufgaben in der Bar, die Liste im Popup.
--
-- Gezeigt wird nur, was heute faellig oder schon ueberfaellig ist -- alles
-- Spaetere gehoert in den Kalender, nicht in die Menuleiste. Ohne offene
-- Aufgaben verschwindet das Item ganz: ein Widget, das dauerhaft "0" anzeigt,
-- kostet Platz und sagt nichts.
--
-- Die grosse Zahl ist bewusst die der heute faelligen Aufgaben, nicht die des
-- Rueckstands. Der Rueckstand ist hier dreistellig und teils Monate alt; als
-- Leitzahl stuende monatelang dieselbe rote Zahl in der Leiste, an die man
-- sich nach zwei Tagen gewoehnt haette. Er haengt deshalb nur als "+n" hinten
-- dran und faerbt nichts ein. Rot gibt es allein fuer heute faellige Aufgaben,
-- deren Uhrzeit schon verstrichen ist -- das ist die einzige Lage, in der ein
-- Blick in die Leiste heute noch etwas aendert.
--
-- Der API-Token liegt ausserhalb dieses Repos in ~/.config/clickup/token
-- (chmod 600), weil das Repo oeffentlich ist. Fehlt er, bleibt das Widget
-- still unsichtbar. Damit es von selbst auftaucht, sobald die Datei da ist,
-- braucht es updates = true: default.lua setzt "when_shown", und ein Item,
-- das sich per drawing = false ausblendet, wuerde sonst nie wieder abfragen.
--
-- Abruf und Auswertung stehen in helpers/clickup_probe.py.

local PROBE = "/usr/bin/python3 $CONFIG_DIR/helpers/clickup_probe.py"
local MAX_ROWS = 8

-- Wie in irrlicht.lua: die Vorgaben der Bar (13pt, 40 Punkt Zeilenhoehe)
-- erzeugen in einer Liste vor allem Leerraum.
local ROW_FONT = 11.0
local ROW_HEIGHT = 20
local ROW_PAD = 7
-- Zwei feste Spalten je Zeile, wie bei den Limit-Zeilen in irrlicht.lua:
-- nur so stehen die Faelligkeiten untereinander, obwohl die Titel
-- unterschiedlich lang sind. Die Breite passt zu den 34 Zeichen, auf die
-- der Helfer kuerzt.
local TITLE_WIDTH = 200
local DUE_WIDTH = 62

-- Zehn bis fuenfzehn Minuten reichen: Faelligkeiten stehen tagegenau fest,
-- und niemand muss von der Menuleiste erfahren, dass eine Aufgabe seit
-- dreissig Sekunden ueberfaellig ist. ClickUp erlaubt 100 Requests pro
-- Minute je Token -- eine Frage alle 900 Sekunden laesst davon reichlich
-- fuer alles andere uebrig, was den Token benutzt.
local UPDATE_FREQ = 900

-- now  = heute faellig, Uhrzeit verstrichen
-- today = heute faellig
-- late  = Rueckstand aus frueheren Tagen; grau wie die gealterten Werte in
--         irrlicht.lua, weil eine Ampelfarbe hier nur abstumpfen wuerde
local STATE_COLOR = {
  now = colors.red,
  today = colors.yellow,
  late = colors.grey,
}

local clickup = sbar.add("item", "clickup", {
  position = "right",
  -- Startet unsichtbar: der erste Abruf laeuft asynchron an, und solange er
  -- nicht geantwortet hat, gibt es nichts zu zeigen.
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
  click_script = "sketchybar --set clickup popup.drawing=toggle",
})

-- Feste Reserve statt neuer Items je Durchlauf (siehe items/menus.lua).
-- Eine Popup-Zeile ist ein Item: der Titel steht im icon-Feld, die
-- Faelligkeit im label -- zwei Items je Zeile waeren zwei Zeilen.
local rows = {}
for i = 1, MAX_ROWS do
  rows[i] = sbar.add("item", "clickup.task." .. i, {
    position = "popup.clickup",
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

-- Wie viele Abrufe hintereinander misslungen sind. Ein einzelner Fehler ist
-- ein Schluckauf und darf den Stand stehen lassen; haelt er an -- widerrufener
-- Token, dauerhaft kein Netz --, ist die Zahl irgendwann nur noch Erinnerung.
-- Dann verliert sie ihre Farbe, statt weiter Dringlichkeit zu behaupten.
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
      clickup:set({ drawing = false })
      for i = 1, MAX_ROWS do rows[i]:set({ drawing = false }) end
      return
    end

    local today, late, urgent = string.match(counts or "", "^C|(%d+)|(%d+)|(%d+)$")
    -- ERR oder Unfug: der letzte bekannte Stand bleibt stehen. Ein Netz-
    -- fehler ist kein Grund, eine Viertelstunde lang nichts zu wissen.
    if not today then
      misses = misses + 1
      if misses == STALE_AFTER then
        -- Nicht schlicht grau: Grau ist seit dem Umbau die normale Farbe des
        -- Rueckstands, ein veralteter Stand saehe damit aus wie ein gesunder.
        -- Halbtransparent ist er als das erkennbar, was er ist.
        local stale = colors.with_alpha(colors.grey, 0.5)
        clickup:set({ icon = { color = stale }, label = { color = stale } })
      end
      return
    end
    misses = 0
    today, late, urgent = tonumber(today), tonumber(late), tonumber(urgent)

    -- Ohne etwas fuer heute bleibt nur der Rueckstand, und der meldet sich
    -- als blosses "+n" in Grau: sichtbar fuer den, der hinsieht, aber ohne
    -- Anspruch darauf, gerade jetzt wichtig zu sein.
    local label, color
    if today > 0 then
      label = tostring(today) .. (late > 0 and ("+" .. late) or "")
      color = urgent > 0 and colors.red or colors.yellow
    else
      label = "+" .. late
      color = colors.grey
    end

    clickup:set({
      drawing = (today + late) > 0,
      icon = { color = color },
      label = { string = label, color = color },
    })

    for i = 1, MAX_ROWS do
      -- Die URL kommt aus der API und landet in einer Shell. Der Helfer
      -- prueft sie schon, hier noch einmal: nur app.clickup.com und nur
      -- Zeichen, die kein Kommando beenden koennen.
      local state, due, url, title =
        string.match(tasks[i] or "", "^T|(%a+)|([^|]*)|([^|]*)|(.*)$")
      if state then
        -- Eine Zeile ohne brauchbare Adresse bleibt sichtbar, nur eben ohne
        -- Klick: sie zaehlt zur Zahl in der Leiste, und ein Loch mitten in
        -- der Liste waere schwerer zu deuten als ein Eintrag ohne Ziel.
        local safe = string.match(url, "^https://app%.clickup%.com/[%w/_%.%-]+$")
        rows[i]:set({
          drawing = true,
          icon = { string = title },
          label = { string = due, color = STATE_COLOR[state] or colors.grey },
          click_script = safe and ("open " .. url ..
            "; sketchybar --set clickup popup.drawing=off") or "",
        })
      else
        rows[i]:set({ drawing = false })
      end
    end
  end)
end

clickup:subscribe("routine", update)
clickup:subscribe("forced", update)
-- Nach dem Aufwachen ist der Stand von vor dem Zuklappen meist ueberholt,
-- und bis zum naechsten regulaeren Abruf koennen 15 Minuten vergehen.
clickup:subscribe("system_woke", update)

update()
