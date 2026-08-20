local colors = require("colors")
local settings = require("settings")

-- Irrlicht-Sessions in der Bar, mit Popup aus Abo-Limits und Session-Liste.
--
-- Ein 'alias'-Item (das Menüleistensymbol der App spiegeln) scheidet aus:
-- sketchybar erkennt nur klassische NSStatusItem-Icons; Irrlicht taucht in
-- `sketchybar --query default_menu_items` gar nicht erst auf. Stattdessen
-- wird der lokale Daemon direkt abgefragt — dieselbe Quelle, aus der sich
-- auch das Menü der App speist.
--
-- Die Aufbereitung der Antwort steht in helpers/irrlicht_probe.py; dort ist
-- auch beschrieben, woher die Zuordnung Session → Abo kommt und warum der
-- letzte bekannte Stand je Profil zwischengespeichert wird. Gealterte Werte
-- nennen ihr Alter und verlieren die Ampelfarbe — sie sagen, wie es war,
-- nicht wie es ist.

local API = "http://127.0.0.1:7837/api/v1"
local FOCUS = "/Applications/Irrlicht.app/Contents/MacOS/irrlicht-focus"
local MAX_ROWS = 10
local MAX_LIMIT_ROWS = 8   -- drei ccp-Profile mal zwei Fenster, plus andere Adapter
-- Kompakteres Raster als die Bar selbst: die Defaults (14/13pt, 28px hohe
-- Zeilen, 5px Item-Polster) sind für einzelne Items in der Leiste gedacht,
-- in einer Liste aus bis zu sechzehn Zeilen wird daraus viel Leerraum.
--
-- Die Session-Zeilen bekommen bewusst keine feste Breite: eine erzwungene
-- Spaltenbreite hängt hinter jeder kurzen Zeile Leerraum an. Nur die beiden
-- Limit-Spalten sind fest, damit die Zahlen untereinander stehen.
local ROW_FONT = 11.0
-- Ausschlaggebend für die Zeilenhöhe im Popup ist popup.height am Eltern-Item:
-- ohne den Wert (-1) übernimmt jede Zeile die Höhe der Bar, also 40 Punkt.
-- background.height wirkt nur auf den gezeichneten Hintergrund und ändert am
-- Zeilenabstand nichts.
local ROW_HEIGHT = 20
-- Randabstand der Zeilen zum Popup-Rahmen. Wirkt links wie rechts, weil
-- Icon-Polster und Label-Polster denselben Wert verwenden.
local ROW_PAD = 7
-- Breit genug fuer den laengsten Fall mit Altersangabe: "gemini-cli · Woche
-- (5d)" misst 123px, ein Abo am Namensdeckel von zehn Zeichen 136px (SF Pro
-- 11, CoreText). Eine Zeichenzahl garantiert in einer Proportionalschrift
-- keine Breite -- der Deckel in irrlicht_probe.py haelt reale Adapternamen
-- klein, gegen konstruierte Extremfaelle hilft er nicht.
local LIMIT_CAPTION_WIDTH = 138
-- Ist der Text breiter als die Spalte, schneidet sketchybar ihn nicht ab,
-- sondern zeichnet ihn über den Nachbarn. Die Werte-Spalte muss deshalb den
-- laengsten moeglichen Eintrag fassen. Gemessen in SF Mono 11 (CoreText):
-- "100% · 6d 23h" = 89px; ein Anbieter mit laengerem Fenster als einer Woche
-- braucht mehr ("100% · 13d 23h" ≈ 96px), und laut irrlicht_probe.py ist die
-- Fensterlaenge nicht vorgegeben. 104 laesst dafuer Luft.
local LIMIT_VALUE_WIDTH = 104

local PROBE = "curl -s --max-time 3 " .. API ..
  "/sessions | /usr/bin/python3 $CONFIG_DIR/helpers/irrlicht_probe.py"

-- Welche Zeitfenster gemeldet werden, gibt der Anbieter vor: Claude Code
-- nennt 300 und 10080 Minuten, Codex nur 10080. Unbekannte Längen bekommen
-- deshalb eine berechnete Beschriftung statt zu fehlen.
local WINDOW_LABEL = { ["300"] = "5 Std", ["1440"] = "Tag", ["10080"] = "Woche" }

local function window_label(minutes)
  local known = WINDOW_LABEL[minutes]
  if known then return known end
  local n = tonumber(minutes) or 0
  if n >= 10080 then return math.floor(n / 10080) .. " Wo" end
  if n >= 1440 then return math.floor(n / 1440) .. " Tg" end
  if n >= 60 then return math.floor(n / 60) .. " Std" end
  return n .. " Min"
end

local STATE_COLOR = {
  waiting = colors.yellow,
  working = colors.blue,
  ready = colors.green,
}

-- Ab 90 Prozent wird es eng, ab 70 lohnt der Blick auf die Uhr.
local function limit_color(percent)
  if percent >= 90 then return colors.red end
  if percent >= 70 then return colors.orange end
  if percent >= 50 then return colors.yellow end
  return colors.green
end

-- Nur die groebste Einheit -- fuer das Alter eines Wertes reicht die
-- Groessenordnung, und die Beschriftungsspalte hat kein Platz fuer mehr.
local function coarse_eta(seconds)
  if seconds >= 86400 then return math.floor(seconds / 86400) .. "d" end
  if seconds >= 3600 then return math.floor(seconds / 3600) .. "h" end
  return math.max(0, math.floor(seconds / 60)) .. "m"
end

-- Restzeit knapp halten: Tage, Stunden oder Minuten, nie alles zusammen.
local function human_eta(seconds)
  if seconds >= 86400 then
    return math.floor(seconds / 86400) .. "d " .. math.floor((seconds % 86400) / 3600) .. "h"
  elseif seconds >= 3600 then
    return math.floor(seconds / 3600) .. "h " .. math.floor((seconds % 3600) / 60) .. "m"
  end
  return math.max(0, math.floor(seconds / 60)) .. "m"
end

local irrlicht = sbar.add("item", "irrlicht", {
  display = settings.primary_display,
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
    height = ROW_HEIGHT,
    background = {
      border_width = 2,
      border_color = colors.popup.border,
      color = colors.popup.bg,
      corner_radius = 9,
    },
  },
  click_script = "sketchybar --set irrlicht popup.drawing=toggle",
})

-- Feste Reserve für Limit- und Session-Zeilen: im Update-Callback angelegt
-- würden bei jedem Durchlauf neue Items entstehen (siehe items/menus.lua).
local limit_rows = {}
for i = 1, MAX_LIMIT_ROWS do
  limit_rows[i] = sbar.add("item", "irrlicht.limit." .. i, {
    position = "popup.irrlicht",
    drawing = false,
    padding_left = ROW_PAD,
    padding_right = ROW_PAD,
    icon = {
      string = "",
      width = LIMIT_CAPTION_WIDTH,
      align = "left",
      color = colors.grey,
      padding_left = ROW_PAD,
      padding_right = 0,
      font = { family = settings.font.text, size = ROW_FONT },
    },
    label = {
      string = "",
      width = LIMIT_VALUE_WIDTH,
      align = "right",
      padding_left = 0,
      padding_right = ROW_PAD,
      font = { family = settings.font.numbers, size = ROW_FONT },
    },
  })
end

local session_rows = {}
for i = 1, MAX_ROWS do
  session_rows[i] = sbar.add("item", "irrlicht.session." .. i, {
    position = "popup.irrlicht",
    drawing = false,
    padding_left = ROW_PAD,
    padding_right = ROW_PAD,
    icon = {
      string = "●",
      padding_left = ROW_PAD,
      padding_right = 4,
      color = colors.grey,
      font = { family = settings.font.text, size = ROW_FONT },
    },
    label = {
      string = "",
      align = "left",
      padding_left = 0,
      padding_right = ROW_PAD,
      font = { family = settings.font.text, size = ROW_FONT },
    },
  })
end

local function update()
  sbar.exec(PROBE, function(out)
    local counts, limits, sessions = nil, {}, {}
    for line in string.gmatch(out or "", "[^\r\n]+") do
      if string.match(line, "^L|") then
        limits[#limits + 1] = line
      elseif string.match(line, "^S|") then
        sessions[#sessions + 1] = line
      elseif not counts then
        counts = line
      end
    end

    local working, waiting, total = string.match(counts or "", "(%d+)%s+(%d+)%s+(%d+)")
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

    for i = 1, MAX_LIMIT_ROWS do
      local profile, minutes, percent, eta, age =
        string.match(limits[i] or "", "^L|([%w%-_]+)|(%d+)|(%d+)|(%d+)|(%d+)$")
      if profile then
        percent = tonumber(percent)
        age = tonumber(age) or 0
        -- Solange eine Session des Profils läuft, ist der Wert sekundenaktuell.
        -- Erst wenn er merklich altert, gehört sein Alter dazu.
        local caption = profile .. " · " .. window_label(minutes)
        if age > 300 then
          caption = caption .. " (" .. coarse_eta(age) .. ")"
        end
        limit_rows[i]:set({
          drawing = true,
          icon = { string = caption },
          label = {
            string = percent .. "% · " .. human_eta(tonumber(eta) or 0),
            color = age > 300 and colors.grey or limit_color(percent),
          },
        })
      else
        limit_rows[i]:set({ drawing = false })
      end
    end

    for i = 1, MAX_ROWS do
      -- Nur alphanumerische IDs mit Bindestrich weiterreichen — deckt die
      -- UUIDs der Claude-Code-Sessions ab wie auch die kurzen proc-IDs
      -- fertiger Sessions, und nichts davon kann ein click_script verlassen.
      local sid, state, project =
        string.match(sessions[i] or "", "^S|([%w%-]+)|([%a]*)|(.*)$")
      if sid then
        session_rows[i]:set({
          drawing = true,
          icon = { color = STATE_COLOR[state] or colors.grey },
          label = { string = project .. " · " .. state },
          click_script = FOCUS .. " " .. sid .. "; sketchybar --set irrlicht popup.drawing=off",
        })
      else
        session_rows[i]:set({ drawing = false })
      end
    end
  end)
end

irrlicht:subscribe("routine", update)
irrlicht:subscribe("forced", update)

update()
