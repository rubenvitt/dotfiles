local colors = require("colors")
local icons = require("icons")
local settings = require("settings")

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

-- Kompaktes Popup-Raster: die Vorgaben aus default.lua (14/13pt,
-- 28px Zeilen) sind fuer einzelne Items in der Leiste gedacht und erzeugen in
-- einer Liste vor allem Leerraum.
local ROW_FONT = 11.0
-- Zeilenhoehe kommt von popup.height am Eltern-Item; ohne den Wert erbt jede
-- Zeile die Hoehe der Bar. background.height genuegt dafuer nicht.
local ROW_HEIGHT = 20
local ROW_PAD = 7
local CAPTION_WIDTH = 78
local VALUE_WIDTH = 116
local FORECAST_ROWS = 3

-- WMO-Wettercodes, wie Open-Meteo sie in weather_code liefert, auf Zustand und
-- Farbe. Zustaende statt Codes, weil mehrere Codes dasselbe Bild ergeben: die
-- drei Niesel-Stufen 51/53/55 unterscheiden sich in einem Balkendiagramm, nicht
-- in einem 14 Punkt grossen Symbol.
local CONDITION = {
  [0] = { "clear", colors.yellow },        -- klar
  [1] = { "clear", colors.yellow },        -- ueberwiegend klar
  [2] = { "partly", colors.white },        -- teilweise bewoelkt
  [3] = { "cloudy", colors.grey },         -- bedeckt
  [45] = { "fog", colors.grey },           -- Nebel
  [48] = { "fog", colors.grey },           -- Reifnebel
  [51] = { "drizzle", colors.blue },       -- Niesel, leicht
  [53] = { "drizzle", colors.blue },
  [55] = { "drizzle", colors.blue },
  [56] = { "sleet", colors.blue },         -- gefrierender Niesel
  [57] = { "sleet", colors.blue },
  [61] = { "rain", colors.blue },          -- Regen
  [63] = { "rain", colors.blue },
  [65] = { "heavy_rain", colors.blue },    -- Starkregen
  [66] = { "sleet", colors.blue },         -- gefrierender Regen
  [67] = { "sleet", colors.blue },
  [71] = { "snow", colors.white },         -- Schneefall
  [73] = { "snow", colors.white },
  [75] = { "snow", colors.white },
  [77] = { "snow_grains", colors.white },  -- Schneegriesel
  [80] = { "showers", colors.blue },       -- Regenschauer
  [81] = { "showers", colors.blue },
  [82] = { "heavy_rain", colors.blue },    -- heftige Schauer
  [85] = { "snow", colors.white },         -- Schneeschauer
  [86] = { "snow", colors.white },
  [95] = { "thunder", colors.orange },     -- Gewitter
  [96] = { "hail", colors.orange },        -- Gewitter mit Hagel
  [99] = { "hail", colors.orange },
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
  local entry = CONDITION[code] or { "cloudy", colors.grey }
  local key = entry[1]
  if DAY_NIGHT[key] then
    key = key .. (is_day and "_day" or "_night")
  end
  return icons.weather[key] or icons.weather.cloudy, entry[2]
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
  icon = {
    string = icons.weather.cloudy,
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
  click_script = "sketchybar --set weather popup.drawing=toggle",
})

-- Zeilen einmal anlegen: im Update-Callback erzeugt entstuende bei jedem
-- Durchlauf ein neuer Satz Items (siehe items/menus.lua).
local function add_row(name, value_font, caption_width, value_width)
  return sbar.add("item", "weather." .. name, {
    position = "popup.weather",
    drawing = false,
    padding_left = ROW_PAD,
    padding_right = ROW_PAD,
    icon = {
      string = "",
      width = caption_width or CAPTION_WIDTH,
      align = "left",
      color = colors.grey,
      padding_left = ROW_PAD,
      padding_right = 0,
      font = { family = settings.font.text, size = ROW_FONT },
    },
    label = {
      string = "",
      width = value_width or VALUE_WIDTH,
      align = "right",
      padding_left = 0,
      padding_right = ROW_PAD,
      font = { family = value_font, size = ROW_FONT },
    },
  })
end

-- Warnzeilen zuerst: sketchybar ordnet ein Popup in der Reihenfolge, in der
-- seine Zeilen angelegt werden, und eine amtliche Warnung gehoert ueber die
-- Stundenvorschau.
--
-- Die Spalten sind breiter als unten (146 + 80 gegen 78 + 116). Ein
-- Ereignisname und ein Zeitraum passen in 194 Punkte schlicht nicht beide
-- hinein -- ausgemessen: das Dreieck kostet 26 Punkte, ein Zeichen gut 5, und
-- "13 – 18 Uhr" braucht 75. Das Popup ist also breiter, solange eine Warnung
-- ansteht. Das ist der bessere Handel als eine Zeile, die scrollt oder
-- abschneidet: Warnungen sind die Ausnahme, und wenn eine da ist, darf sie
-- den Platz haben.
local WARN_CAPTION_WIDTH = 146
local WARN_VALUE_WIDTH = 80

local warn_rows = {}
for i = 1, WARN_ROWS do
  warn_rows[i] = add_row("warning." .. i, settings.font.numbers,
    WARN_CAPTION_WIDTH, WARN_VALUE_WIDTH)
end

-- Der Ortsname ist Fliesstext, alles andere sind Zahlen, die untereinander
-- stehen sollen -- daher zwei verschiedene Schriften in der Wertspalte.
local place_row = add_row("place", settings.font.text)
local detail_rows = {
  feels = add_row("feels", settings.font.numbers),
  wind = add_row("wind", settings.font.numbers),
  rain = add_row("rain", settings.font.numbers),
  sun = add_row("sun", settings.font.numbers),
  today = add_row("today", settings.font.numbers),
}

local forecast_rows = {}
for i = 1, FORECAST_ROWS do
  forecast_rows[i] = add_row("forecast." .. i, settings.font.numbers)
end

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
  icon = {
    string = icons.warning,
    color = colors.orange,
    padding_right = 4,
  },
  label = { color = colors.orange },
  click_script = "sketchybar --set weather popup.drawing=toggle",
})

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
    local symbol, color = condition(tonumber(code), is_day == "1")
    if stale then color = colors.grey end
    -- Gealterte Werte verlieren die Farbe im ganzen Popup, nicht nur in der
    -- Bar -- sie sagen geschlossen, wie es war, nicht wie es ist.
    local value_color = stale and colors.grey or colors.white

    weather:set({
      drawing = true,
      icon = { string = symbol, color = color },
      label = { string = temp .. "°", color = color },
    })

    -- Ein Ort aus der Geo-IP-Rueckfallebene ist die Adresse des Providers und
    -- kann Hunderte Kilometer danebenliegen; das Zeichen sagt, dass hier
    -- geraten und nicht gemessen wurde. Gemessene Orte bleiben unmarkiert --
    -- der Normalfall braucht keine Beschriftung.
    local shown = place or "unbekannt"
    if place and origin == "ip" then shown = "≈ " .. place end

    place_row:set({
      drawing = place ~= nil or stale,
      icon = { string = "Ort" },
      label = {
        -- Der Ortsname stammt aus einer fremden Antwort und landet nur hier,
        -- nie in einem click_script.
        string = shown,
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

    local tmax, tmin, sunrise, sunset =
      string.match(day or "", "^D|(%-?%d+)|(%-?%d+)|([%d:]+)|([%d:]+)$")
    detail_rows.today:set({
      drawing = tmax ~= nil,
      icon = { string = "Heute" },
      label = { string = tmax and (tmin .. "° – " .. tmax .. "°") or "", color = value_color },
    })
    detail_rows.sun:set({
      drawing = sunrise ~= nil,
      icon = { string = "Sonne" },
      label = { string = sunrise and (sunrise .. " – " .. sunset) or "", color = value_color },
    })

    for i = 1, FORECAST_ROWS do
      local hour, hcode, htemp, hrain =
        string.match(hours[i] or "", "^H|(%d+)|(%d+)|(%-?%d+)|(%d+)$")
      if hour then
        -- Das Symbol steht in der Beschriftungsspalte, weil nur die in der
        -- Textschrift gesetzt ist; die Wertspalte laeuft in SF Mono, dort
        -- faende sich kein Glyph dafuer.
        local hday = daylight_at(hour, sunrise, sunset)
        if hday == nil then hday = (is_day == "1") end
        local hsymbol = condition(tonumber(hcode), hday)
        forecast_rows[i]:set({
          drawing = true,
          icon = { string = hsymbol .. "  " .. hour .. " Uhr" },
          label = { string = htemp .. "° · " .. hrain .. " %", color = value_color },
        })
      else
        forecast_rows[i]:set({ drawing = false })
      end
    end

    -- Gealterte Daten sagen, wie es war, nicht wie es ist -- das gehoert
    -- dazugeschrieben, sonst sieht die Bar nur falsch aus.
    if stale then
      place_row:set({ icon = { string = "Ort · vor " .. human_age(age) } })
    end
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
        color = color,
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
