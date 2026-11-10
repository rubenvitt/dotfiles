local colors = require("colors")
local icons = require("icons")
local svg = require("helpers.svg_icon")
local settings = require("settings")
local popup = require("helpers.popup")

-- Wetter am aktuellen Standort, mit Popup aus Details und Stundenvorschau.
--
-- Der Nutzer arbeitet als Berater an wechselnden Orten, ein fest eingetragener
-- Ort waere also falsch -- und in einem oeffentlichen Repo obendrein ein
-- Datenleck. Der Standort wird deshalb zur Laufzeit ueber die Ortungsdienste
-- bestimmt und ausserhalb des Repos zwischengespeichert.
--
-- Wie die Daten geholt und gecacht werden, steht in helpers/weather_probe.py;
-- dort ist auch begruendet, warum der Standort deutlich laenger gilt als das
-- Wetter. Faellt das Netz aus, liefert der Helfer den letzten bekannten Stand
-- samt Alter; die Anzeige verliert dann ihre Farbe und nennt das Alter.
--
-- Amtliche Warnungen kommen aus einer zweiten Quelle, helpers/warnings_probe.py:
-- Wetterwarnungen gemeindegenau vom DWD, Bevoelkerungsschutz kreisweit von
-- NINA. Sie haengen an einem eigenen Item links vom Wetter, damit eine Warnung
-- die Wetterlage nicht verdeckt, und an einer eigenen Frist -- ein Unwetter ist
-- zeitkritischer als die Temperatur.

local PROBE = "/usr/bin/python3 $CONFIG_DIR/helpers/weather_probe.py"
local WARN_PROBE = "/usr/bin/python3 $CONFIG_DIR/helpers/warnings_probe.py"

-- Open-Meteo rechnet seinen current-Block im 15-Minuten-Raster fort; die
-- Antwort nennt das selbst als "interval": 900. Haeufiger zu fragen brachte
-- also keinen neuen Wert, kostete aber Kontingent bei einem Dienst, der ohne
-- Schluessel und ohne Gegenleistung antwortet.
local UPDATE_FREQ = 900

-- Ab hier hat die Bar zwei Abfragen in Folge verpasst -- das ist kein
-- Netzhaenger mehr, sondern ein Ausfall, und der gehoert sichtbar.
local STALE_AFTER = 1800

-- Warnungen laufen kuerzer als das Wetter: eine Unwetterwarnung, die eine
-- Viertelstunde zu spaet ankommt, ist keine Warnung mehr. Der Helfer cacht
-- seinerseits fuenf Minuten, ein haeufigerer Takt traefe also nur den Cache.
local WARN_UPDATE_FREQ = 300

-- Ab welcher DWD-Warnstufe die Bar anschlaegt. Stufe 1 ist Alltag und kein
-- Ereignis -- an einem gewoehnlichen Windtag stehen bundesweit mehrere hundert
-- gelbe Gemeindewarnungen; ein Item, das dann dauerhaft leuchtet, wird
-- uebersehen, wenn es einmal wirklich zaehlt. Gelbe Warnungen stehen deshalb
-- nur im Popup. Bevoelkerungsschutz zieht unabhaengig von der Stufe hoch: die
-- kommt nicht taeglich, und wenn, dann geht es nicht ums Wetter.
local BAR_LEVEL = 2

-- Ab welcher Stufe das Warnitem den Ereignisnamen ausschreibt. Darunter steht
-- nur das Dreieck in der Farbe der Stufe: die Bar ist voll, und ein Name wie
-- "Einrichtung von Schutzzonen" frisst mehr Platz als ein ganzes Widget. Was
-- gewarnt wird, steht einen Klick entfernt im Popup. Stufe 4 -- das amtliche
-- Dunkelrot, "extremes Unwetter" -- ist die Ausnahme: da soll man nicht erst
-- klicken muessen.
local BAR_LABEL_LEVEL = 4

-- Wie viele Warnzeilen das Popup zeigt. Der Wert ist gleich der Obergrenze im
-- Helfer: was der ausgibt, steht auch im Popup. Zwischen beiden noch einmal zu
-- kuerzen hiesse, Warnungen stillschweigend zu verschlucken -- die einzige
-- Grenze soll die sein, die im Helfer begruendet steht.
local WARN_ROWS = 5

-- Popup im Stil des macOS-Wettermenüs (helpers/popup.lua): Kopf mit Ort,
-- großer Temperatur und Lage, darunter Stunden und Details als Listen.
local CAPTION_WIDTH = 130
-- Spalte, in der das Wettersymbol der Stundenliste steht.
local SYMBOL_X = popup.INSET + 170
local FORECAST_ROWS = 3

-- WMO-Wettercodes, wie Open-Meteo sie in weather_code liefert, auf Zustand und
-- Farbe. Zustaende statt Codes, weil mehrere Codes dasselbe Bild ergeben: die
-- drei Niesel-Stufen 51/53/55 unterscheiden sich in einem Balkendiagramm, nicht
-- in einem 14 Punkt grossen Symbol.
local CONDITION = {
  [0] = { "clear", colors.yellow, "Klar" },        -- klar
  [1] = { "clear", colors.yellow, "Überwiegend klar" },        -- ueberwiegend klar
  [2] = { "partly", colors.white, "Teils bewölkt" },        -- teilweise bewoelkt
  [3] = { "cloudy", colors.grey, "Bedeckt" },         -- bedeckt
  [45] = { "fog", colors.grey, "Nebel" },           -- Nebel
  [48] = { "fog", colors.grey, "Reifnebel" },           -- Reifnebel
  [51] = { "drizzle", colors.blue, "Nieselregen" },       -- Niesel, leicht
  [53] = { "drizzle", colors.blue, "Nieselregen" },
  [55] = { "drizzle", colors.blue, "Nieselregen" },
  [56] = { "sleet", colors.blue, "Gefrierender Niesel" },         -- gefrierender Niesel
  [57] = { "sleet", colors.blue, "Gefrierender Niesel" },
  [61] = { "rain", colors.blue, "Regen" },          -- Regen
  [63] = { "rain", colors.blue, "Regen" },
  [65] = { "heavy_rain", colors.blue, "Starkregen" },    -- Starkregen
  [66] = { "sleet", colors.blue, "Gefrierender Regen" },         -- gefrierender Regen
  [67] = { "sleet", colors.blue, "Gefrierender Regen" },
  [71] = { "snow", colors.white, "Schneefall" },         -- Schneefall
  [73] = { "snow", colors.white, "Schneefall" },
  [75] = { "snow", colors.white, "Schneefall" },
  [77] = { "snow_grains", colors.white, "Schneegriesel" },  -- Schneegriesel
  [80] = { "showers", colors.blue, "Regenschauer" },       -- Regenschauer
  [81] = { "showers", colors.blue, "Regenschauer" },
  [82] = { "heavy_rain", colors.blue, "Heftige Schauer" },    -- heftige Schauer
  [85] = { "snow", colors.white, "Schneeschauer" },         -- Schneeschauer
  [86] = { "snow", colors.white, "Schneeschauer" },
  [95] = { "thunder", colors.orange, "Gewitter" },     -- Gewitter
  [96] = { "hail", colors.orange, "Gewitter mit Hagel" },        -- Gewitter mit Hagel
  [99] = { "hail", colors.orange, "Gewitter mit Hagel" },
}

-- DWD-Warnstufen in der Reihenfolge des amtlichen Farbschemas: gelb, orange,
-- rot -- und fuer Stufe 4 amtlich Dunkelrot. Dafuer steht hier Magenta: ein
-- Dunkelrot auf dem fast schwarzen Untergrund der Leiste waere kaum vom
-- Hintergrund zu unterscheiden, und ausgerechnet die schwerste Stufe darf
-- nicht die unauffaelligste sein. Magenta liegt jenseits von Rot, ohne
-- unleserlich zu werden. Stufe 0 sind Vorabinformationen und Meldungen ohne
-- Angabe -- grau, weil sie ankuendigen statt zu warnen.
local WARN_COLOR = {
  [0] = colors.grey,
  [1] = colors.yellow,
  [2] = colors.orange,
  [3] = colors.red,
  [4] = colors.magenta,
}

-- Nur wo Sonne oder Mond im Symbol vorkommt, lohnt die Unterscheidung; ein
-- bedeckter Himmel sieht nachts aus wie tagsueber.
local DAY_NIGHT = { clear = true, partly = true, showers = true }

local function condition(code, is_day)
  local entry = CONDITION[code] or { "cloudy", colors.grey, "Bedeckt" }
  local key = entry[1]
  if DAY_NIGHT[key] then
    key = key .. (is_day and "_day" or "_night")
  end
  -- Name für svg_icon; die Glyphe dazu liefert svg.glyph.
  return "weather." .. (icons.weather[key] and key or "cloudy"), entry[2], entry[3]
end

-- Ob eine Vorschaustunde noch in den Tag faellt. Gemessen wird die Mitte der
-- Stunde, sonst gaebe die abgeschnittene Stundenzahl der Zeile 20 Uhr bei
-- Sonnenuntergang um 20:30 faelschlich ein Mondsymbol.
local function minutes(hhmm)
  return tonumber(string.sub(hhmm, 1, 2)) * 60 + tonumber(string.sub(hhmm, 4, 5))
end

local function daylight_at(hour, sunrise, sunset)
  if not sunrise then return nil end
  local middle = tonumber(hour) * 60 + 30
  return middle >= minutes(sunrise) and middle < minutes(sunset)
end

-- Alter knapp halten: eine Einheit genuegt.
local function human_age(seconds)
  if seconds >= 86400 then return math.floor(seconds / 86400) .. "d" end
  if seconds >= 3600 then return math.floor(seconds / 3600) .. "h" end
  return math.max(1, math.floor(seconds / 60)) .. "m"
end

local weather = sbar.add("item", "weather", {
  display = settings.primary_display,
  position = "right",
  -- default.lua setzt updates = "when_shown". Dieses Item blendet sich ohne
  -- Daten selbst aus und bekaeme danach nie wieder einen Durchlauf.
  updates = true,
  update_freq = UPDATE_FREQ,
  drawing = false,
  icon = svg.icon("weather.cloudy", colors.grey, { padding_right = 4 }),
  label = {
    font = {
      family = settings.font.numbers,
      style = settings.font.style_map["Bold"],
    },
    color = colors.grey,
  },
  popup = popup.host("right"),
})

-- Zeilen einmal anlegen: im Update-Callback erzeugt entstuende bei jedem
-- Durchlauf ein neuer Satz Items (siehe items/menus.lua).
--
local function add_row(name, opts)
  opts = opts or {}
  opts.caption_width = opts.caption_width or CAPTION_WIDTH
  return popup.row("weather", "weather." .. name, opts)
end

local function add_rule(name, color, height)
  return popup.rule("weather", "weather." .. name, {
    color = color or colors.transparent,
    height = height,
  })
end

local top_gap = add_rule("gap.top", nil, 8)

-- Warnzeilen zuerst: sketchybar ordnet ein Popup in der Reihenfolge, in der
-- seine Zeilen angelegt werden, und eine amtliche Warnung gehoert ueber das
-- Wetter. Ereignisname und Zeitraum teilen sich die Breite anders als die
-- übrigen Zeilen: "13 – 18 Uhr" braucht gut 75 Punkte, der Name den Rest.
local warn_rows = {}
for i = 1, WARN_ROWS do
  warn_rows[i] = add_row("warning." .. i, {
    caption_width = popup.WIDTH - 2 * popup.INSET - 90,
  })
end
local warn_rule = add_rule("rule.warning", colors.popup.hairline)
local warn_gap = add_rule("gap.warning", nil, 8)

-- Kopf: Ort und Lage, darunter groß die Temperatur und der Tagesbereich.
local head_place = add_row("head.place", {
  height = 22,
  caption_font = popup.font("Bold", 15.0),
  value_font = popup.font("Semibold", 12.0),
})
local head_temp = add_row("head.temp", {
  height = 46,
  caption_font = popup.font("Light", 38.0),
  value_font = popup.font("Semibold", 12.0),
})

local hour_rule = add_rule("rule.hours", colors.popup.hairline)
local forecast_rows = {}
for i = 1, FORECAST_ROWS do
  forecast_rows[i] = add_row("forecast." .. i)
end

add_rule("rule.details", colors.popup.hairline):set({ drawing = true })
local detail_rows = {
  feels = add_row("feels"),
  wind = add_row("wind"),
  rain = add_row("rain"),
  sun = add_row("sun"),
}

add_rule("rule.open", colors.popup.hairline):set({ drawing = true })
popup.action("weather", "weather.open", "„Wetter“ öffnen",
  "open -a Weather; sketchybar --set weather popup.drawing=off")
add_rule("gap.bottom", nil, 6):set({ drawing = true })
top_gap:set({ drawing = true })

-- Eigenes Item statt eines getauschten Wettersymbols: bei Sturm will man beides
-- wissen, dass gewarnt ist und wie das Wetter gerade ist. Es steht links vom
-- Wetter, weil rechts angelegte Items bei sketchybar von rechts nach links
-- einruecken -- dieses hier entsteht nach dem Wetter, landet also daneben.
-- Es teilt sich dessen Popup; ein zweites waere derselbe Inhalt.
local alert = sbar.add("item", "weather.alert", {
  display = settings.primary_display,
  position = "right",
  -- Wie beim Wetter: das Item blendet sich ohne Warnung selbst aus und
  -- bekaeme unter der Vorgabe "when_shown" nie wieder einen Durchlauf.
  updates = true,
  update_freq = WARN_UPDATE_FREQ,
  drawing = false,
  icon = svg.icon("warning", colors.orange, { padding_right = 4 }),
  label = { color = colors.orange },
})

weather:subscribe("mouse.clicked", function() popup.toggle("weather") end)
alert:subscribe("mouse.clicked", function() popup.toggle("weather") end)

-- relocate laesst den Helfer den Standort neu bestimmen statt seinen Cache zu
-- benutzen. Genau dafuer ist system_woke da: zwischen Zuklappen und Aufklappen
-- liegt der Ortswechsel, den die Frist im Helfer sonst verschweigen wuerde.
local function update(relocate)
  sbar.exec(relocate and (PROBE .. " --relocate") or PROBE, function(out)
    local current, place, origin, day, hours = nil, nil, nil, nil, {}
    for line in string.gmatch(out or "", "[^\r\n]+") do
      local tag = string.sub(line, 1, 1)
      if tag == "W" then
        current = line
      elseif tag == "O" then
        origin, place = string.match(line, "^O|(%a+)|(.+)$")
      elseif tag == "D" then
        day = line
      elseif tag == "H" then
        hours[#hours + 1] = line
      end
    end

    local code, is_day, temp, feels, wind, rain, age =
      string.match(current or "",
        "^W|(%-?%d+)|(%d)|(%-?%d+)|(%-?%d+)|(%d+)|(%d+)|(%d+)$")
    if not code then
      -- Weder Netz noch Cache: lieber nichts zeigen als eine erfundene Zahl.
      weather:set({ drawing = false })
      return
    end

    age = tonumber(age)
    local stale = age > STALE_AFTER
    local symbol, color, text = condition(tonumber(code), is_day == "1")
    if stale then color = colors.grey end
    -- Gealterte Werte verlieren die Farbe im ganzen Popup, nicht nur in der
    -- Bar -- sie sagen geschlossen, wie es war, nicht wie es ist.
    local value_color = stale and colors.grey or colors.white

    weather:set({
      drawing = true,
      icon = svg.icon(symbol, color),
      label = { string = temp .. "°", color = color },
    })

    -- Ein Ort aus der Geo-IP-Rueckfallebene ist die Adresse des Providers und
    -- kann Hunderte Kilometer danebenliegen; das Zeichen sagt, dass hier
    -- geraten und nicht gemessen wurde. Gemessene Orte bleiben unmarkiert --
    -- der Normalfall braucht keine Beschriftung. Gealterte Daten sagen, wie
    -- es war, nicht wie es ist -- das gehoert dazugeschrieben.
    -- Der Ortsname stammt aus einer fremden Antwort und landet nur hier, nie
    -- in einem click_script.
    local shown = place or "Unbekannter Ort"
    if place and origin == "ip" then shown = "≈ " .. place end
    if stale then shown = shown .. " · vor " .. human_age(age) end

    local tmax, tmin, sunrise, sunset =
      string.match(day or "", "^D|(%-?%d+)|(%-?%d+)|([%d:]+)|([%d:]+)$")

    head_place:set({
      drawing = true,
      icon = { string = shown, color = value_color },
      label = { string = text, color = value_color },
    })
    head_temp:set({
      drawing = true,
      icon = { string = temp .. "°", color = value_color },
      label = {
        string = tmax and ("H: " .. tmax .. "°  T: " .. tmin .. "°") or "",
        color = value_color,
      },
    })

    detail_rows.feels:set({
      drawing = true,
      icon = { string = "Gefühlt" },
      label = { string = feels .. "°", color = value_color },
    })
    detail_rows.wind:set({
      drawing = true,
      icon = { string = "Wind" },
      label = { string = wind .. " km/h", color = value_color },
    })
    detail_rows.rain:set({
      drawing = true,
      icon = { string = "Regen" },
      label = { string = rain .. " %", color = value_color },
    })
    detail_rows.sun:set({
      drawing = sunrise ~= nil,
      icon = { string = "Sonne" },
      label = { string = sunrise and (sunrise .. " – " .. sunset) or "", color = value_color },
    })

    local any_hour = false
    for i = 1, FORECAST_ROWS do
      local hour, hcode, htemp, hrain =
        string.match(hours[i] or "", "^H|(%d+)|(%d+)|(%-?%d+)|(%d+)$")
      if hour then
        any_hour = true
        local hday = daylight_at(hour, sunrise, sunset)
        if hday == nil then hday = (is_day == "1") end
        local hsymbol, hcolor = condition(tonumber(hcode), hday)
        if stale then hcolor = colors.grey end
        -- Regen nur, wenn er droht: eine Spalte voller "0 %" ist Rauschen.
        local value = htemp .. "°"
        if tonumber(hrain) >= 10 then value = hrain .. " %   " .. value end
        -- Das Symbol steht als Bild des Zeilenhintergrunds in einer festen
        -- Spalte; nur ohne SVG wandert die Glyphe in den Wert.
        local path = svg.path(hsymbol)
        if not path then value = svg.glyph(hsymbol) .. "   " .. value end
        forecast_rows[i]:set({
          drawing = true,
          icon = { string = hour .. " Uhr", color = value_color },
          label = { string = value, color = value_color },
          background = {
            image = {
              drawing = path ~= nil,
              string = path or "",
              color = hcolor,
              padding_left = SYMBOL_X,
            },
          },
        })
      else
        forecast_rows[i]:set({ drawing = false })
      end
    end
    hour_rule:set({ drawing = any_hour })
  end)
end

-- Farbe einer Warnung. Grau steht in dieser Leiste fuer "gealtert" -- eine
-- Meldung des Bevoelkerungsschutzes ohne Stufenangabe grau zu zeichnen hiesse
-- also, sie fuer veraltet zu erklaeren. Sie bekommt deshalb die mildeste
-- Warnfarbe. Beim DWD bleibt Stufe 0 grau: das sind Vorabinformationen, die
-- ankuendigen statt zu warnen.
local function warn_color(w)
  if w.src == "nina" and w.level == 0 then return colors.yellow end
  return WARN_COLOR[w.level] or colors.grey
end

-- Aktualisiert Warnitem und Warnzeilen. Bewusst getrennt von update(): die
-- beiden Quellen haben eigene Fristen und eigene Ausfaelle, und ein stiller
-- Wetterdienst darf keine Warnung loeschen (und umgekehrt).
local function update_warnings()
  sbar.exec(WARN_PROBE, function(out)
    local state, age, warnings = nil, 0, {}
    for line in string.gmatch(out or "", "[^\r\n]+") do
      if string.sub(line, 1, 1) == "S" then
        state, age = string.match(line, "^S|(%a+)|(%d+)$")
        age = tonumber(age) or 0
      else
        local src, level, name, span =
          string.match(line, "^A|(%a+)|(%d)|([^|]*)|([^|]*)$")
        if src then
          -- Der Text stammt aus einer fremden Antwort und landet nur in
          -- Beschriftungen, nie in einem click_script.
          warnings[#warnings + 1] = {
            src = src, level = tonumber(level), name = name, span = span,
          }
        end
      end
    end

    -- "abroad" heisst, dass hier niemand warnt, "unknown" heisst, dass wir es
    -- nicht wissen. Beides fuehrt zur selben leeren Anzeige, denn eine
    -- erfundene Entwarnung waere schlimmer als gar keine Aussage -- der
    -- Unterschied steht deshalb im Helfer und nicht in der Bar.
    if state ~= "de" then
      alert:set({ drawing = false })
      for i = 1, WARN_ROWS do warn_rows[i]:set({ drawing = false }) end
      warn_rule:set({ drawing = false })
      warn_gap:set({ drawing = false })
      return
    end

    -- Gealterte Warnungen verlieren die Farbe, wie das gealterte Wetter. Der
    -- Helfer wirft abgelaufene Warnungen selbst heraus, hier bleibt also nur
    -- der Fall "seit einer Weile nichts Neues gehoert".
    local stale = age > STALE_AFTER

    for i = 1, WARN_ROWS do
      local w = warnings[i]
      if w then
        warn_rows[i]:set({
          drawing = true,
          icon = {
            string = icons.warning .. "  " .. w.name,
            color = stale and colors.grey or warn_color(w),
          },
          label = { string = w.span, color = stale and colors.grey or colors.white },
        })
      else
        warn_rows[i]:set({ drawing = false })
      end
    end
    warn_rule:set({ drawing = warnings[1] ~= nil })
    warn_gap:set({ drawing = warnings[1] ~= nil })

    -- In der Bar steht nur, was die Schwelle nimmt: ab Stufe 2, und jede
    -- Meldung des Bevoelkerungsschutzes. Der Helfer sortiert nach Stufe, die
    -- erste passende ist also die schaerfste.
    local lead, others = nil, 0
    for _, w in ipairs(warnings) do
      if w.level >= BAR_LEVEL or w.src == "nina" then
        if lead then others = others + 1 else lead = w end
      end
    end

    if not lead then
      alert:set({ drawing = false })
      return
    end

    -- Unterhalb von Stufe 4 bleibt das Item ein blosses Dreieck. Ein Zaehler
    -- fuer weitere Warnungen stuende hier gut, waere aber genau das Stueck
    -- Text, das die Bar nicht hergibt -- wie viele es sind, steht im Popup.
    local label = ""
    if lead.level >= BAR_LABEL_LEVEL then
      -- Auf die Laenge achtet der Helfer; er kuerzt auf das Mass der
      -- Popup-Zeile. Hier ein zweites Mal zu schneiden gaebe zwei Ellipsen.
      label = lead.name
      if others > 0 then label = label .. " +" .. others end
    end
    local color = stale and colors.grey or warn_color(lead)

    alert:set({
      drawing = true,
      icon = {
        -- Glyphe färbt color, das SVG background.image.color; das jeweils
        -- andere bleibt ohne Wirkung.
        color = color,
        background = { image = { color = color } },
        -- Ohne Beschriftung sitzt das Dreieck sonst links an der Kante: der
        -- rechte Abstand ist fuer den Text da, den es dann nicht gibt.
        padding_right = label == "" and settings.paddings or 4,
      },
      -- Eine leere Beschriftung ist nicht umsonst: sketchybar rechnet ihre
      -- Polster mit, auch wenn nichts darin steht -- gemessen sieben Punkte,
      -- die hinter dem Dreieck verpuffen. Sie gehört also ausgeblendet und
      -- nicht bloß geleert. Und wieder eingeblendet, sobald ein Name kommt:
      -- sonst bliebe sie nach dem ersten blanken Dreieck für immer weg.
      label = { string = label, color = color, drawing = label ~= "" },
    })
  end)
end

-- Zwei Abonnements statt eines mit env.SENDER: welches Ereignis den Durchlauf
-- ausgeloest hat, steht damit im Code und nicht in einer Zeichenkette.
weather:subscribe({ "routine", "forced" }, function() update(false) end)
weather:subscribe("system_woke", function() update(true) end)

-- Das Warnitem haengt an seiner eigenen Frist, holt sich beim Aufwachen aber
-- denselben Anstoss: nach dem Zuklappen kann ein Ortswechsel liegen, und der
-- Standort, den der Helfer liest, ist dann gerade neu bestimmt worden.
alert:subscribe({ "routine", "forced", "system_woke" }, update_warnings)

update(false)
update_warnings()
