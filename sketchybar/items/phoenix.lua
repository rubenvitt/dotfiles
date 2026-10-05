local colors = require("colors")
local icons = require("icons")
local settings = require("settings")

-- Aktuelle Position in der Phönix-Progression: Woche des laufenden
-- Feuersturms in der Bar, die ganze Pyramide (Ära → Zyklus → Feuersturm →
-- Feuer) samt Scores und Wochenverlauf im Popup.
--
-- Die Quelle ist der Obsidian-Vault, gelesen von helpers/phoenix_probe.py --
-- dort steht auch, welche Notizen und Tabellen die Wahrheit tragen. Die Bar
-- rechnet nichts nach: Woche, Zustand und Scores kommen fertig vom Helfer,
-- damit die Regeln (wann ist eine Woche Urlaub, was zaehlt als Score) an
-- einer Stelle liegen.
--
-- Farben folgen der Feuer/Asche-Idee des Systems: Orange fuer eine laufende
-- Feuer-Woche, Blau fuer Ruhephasen (Urlaub, Aschezeit), Grau wenn kein
-- Feuersturm laeuft. Der Wochen-Score der Vorwoche faerbt seine Zeile im
-- Popup: ab 85 gilt man im System als "im Feuer", darunter wird analysiert.

local PROBE = "/usr/bin/python3 $CONFIG_DIR/helpers/phoenix_probe.py"
local MOC = os.getenv("HOME") .. "/rnotes/20-lebensbereiche/Phönix-Progression/Phönix-Progression MOC.md"

-- Die Notizen aendern sich ein paarmal am Tag, von Hand. Fuenf Minuten sind
-- schnell genug, dass ein frisch geschriebenes Review in der Bar ankommt,
-- bevor man es vergessen hat.
local UPDATE_FREQ = 300

-- Schwellen aus dem Konzept: > 85 ist "im Feuer", unter 60 die rote Zone.
local SCORE_FIRE = 85
local SCORE_WARN = 60

-- Popup-Raster wie in items/weather.lua.
local ROW_FONT = 11.0
local ROW_HEIGHT = 20
local ROW_PAD = 7
local CAPTION_WIDTH = 84
local VALUE_WIDTH = 236
local MAX_TEXT_CHARS = 36

local STATE = {
  feuer  = { icon = icons.phoenix.fire,     color = colors.orange, label = "Feuer" },
  urlaub = { icon = icons.phoenix.vacation, color = colors.blue,   label = "Urlaub" },
  asche  = { icon = icons.phoenix.ash,      color = colors.blue,   label = "Aschezeit" },
  none   = { icon = icons.phoenix.rest,     color = colors.grey,   label = "kein Feuersturm" },
}

local function score_color(score)
  if not score then return colors.grey end
  if score >= SCORE_FIRE then return colors.green end
  if score >= SCORE_WARN then return colors.yellow end
  return colors.red
end

local function truncate(text)
  if utf8.len(text) and utf8.len(text) > MAX_TEXT_CHARS then
    return string.sub(text, 1, utf8.offset(text, MAX_TEXT_CHARS) - 1) .. "…"
  end
  return text
end

local function fields(line)
  local out = {}
  for f in (line .. "|"):gmatch("([^|]*)|") do out[#out + 1] = f end
  return out
end

local phoenix = sbar.add("item", "phoenix", {
  display = settings.primary_display,
  position = "right",
  updates = true,
  update_freq = UPDATE_FREQ,
  drawing = false,
  icon = {
    string = icons.phoenix.rest,
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
  click_script = "sketchybar --set phoenix popup.drawing=toggle",
})

local function add_row(name, value_font)
  return sbar.add("item", "phoenix." .. name, {
    position = "popup.phoenix",
    drawing = false,
    padding_left = ROW_PAD,
    padding_right = ROW_PAD,
    icon = {
      string = "",
      width = CAPTION_WIDTH,
      align = "left",
      color = colors.grey,
      padding_left = ROW_PAD,
      padding_right = 0,
      font = { family = settings.font.text, size = ROW_FONT },
    },
    label = {
      string = "",
      width = VALUE_WIDTH,
      align = "right",
      padding_left = 0,
      padding_right = ROW_PAD,
      font = { family = value_font or settings.font.text, size = ROW_FONT },
    },
    -- Ein Klick auf eine Zeile oeffnet das Dashboard im Vault. Der Pfad ist
    -- fest und stammt nicht aus der Probe-Ausgabe.
    click_script = "open 'obsidian://open?path=" .. MOC .. "'; sketchybar --set phoenix popup.drawing=off",
  })
end

local rows = {
  aera = add_row("aera"),
  zyklus = add_row("zyklus"),
  feuersturm = add_row("feuersturm"),
  woche = add_row("woche"),
  fokus = add_row("fokus"),
  vorwoche = add_row("vorwoche", settings.font.numbers),
  schnitt = add_row("schnitt", settings.font.numbers),
  verlauf = add_row("verlauf"),
}

local function update()
  sbar.exec(PROBE, function(out)
    local s, aera, zyklus, fs, feuer, weeks = nil, nil, nil, nil, nil, {}
    for line in string.gmatch(out or "", "[^\r\n]+") do
      local f = fields(line)
      if f[1] == "S" then s = f
      elseif f[1] == "A" then aera = f
      elseif f[1] == "Z" then zyklus = f
      elseif f[1] == "F" then fs = f
      elseif f[1] == "E" then feuer = f
      elseif f[1] == "W" then weeks[#weeks + 1] = f
      end
    end

    if not s then
      -- Vault nicht lesbar: lieber nichts zeigen als eine erfundene Woche.
      phoenix:set({ drawing = false })
      return
    end

    local state = STATE[s[2]] or STATE.none
    local week, total, days_left = tonumber(s[3]) or 0, tonumber(s[4]) or 12, tonumber(s[5]) or 0
    local last_week, last_score = s[6], tonumber(s[7])
    local avg, n = s[8], tonumber(s[9]) or 0

    phoenix:set({
      drawing = true,
      icon = { string = state.icon, color = state.color },
      label = {
        -- In der Aschezeit gibt es keine Woche zu zählen, wohl aber einen
        -- Countdown: die Bar zeigt die Tage bis zum nächsten Feuersturm.
        string = week > 0 and ("W" .. week .. "/" .. total)
          or (s[2] == "asche" and (days_left .. " T")) or "—",
        color = state.color,
      },
    })

    rows.aera:set({
      drawing = aera ~= nil,
      icon = { string = "Ära" },
      label = { string = aera and aera[2] or "", color = colors.white },
    })
    rows.zyklus:set({
      drawing = zyklus ~= nil,
      icon = { string = "Zyklus" },
      label = {
        string = zyklus and (zyklus[2]:gsub("^Zyklus ", "") .. "  ·  " .. zyklus[3]:gsub("%.(%d%d%d%d) –", " –"):gsub("(%d%d%.%d%d%.)%d%d%d%d$", "%1")) or "",
        color = colors.white,
      },
    })

    local fs_text = ""
    if fs then
      fs_text = fs[2]:gsub("^Feuersturm ", "")
      if fs[4] ~= "" then fs_text = fs_text .. " (" .. fs[4] .. "/" .. fs[5] .. ")" end
      -- Nur das Ende: der Anfang steht schon im Zyklus, und die Zeile ist
      -- eng.
      local ende = fs[3]:match("– (.+)$") or fs[3]
      fs_text = fs_text .. "  ·  bis " .. ende
    end
    rows.feuersturm:set({
      drawing = fs ~= nil,
      icon = { string = "Feuersturm" },
      label = { string = fs_text, color = colors.white },
    })

    local week_text = state.label
    if week > 0 then
      week_text = "W" .. week .. "/" .. total .. "  ·  " .. state.label
        .. "  ·  noch " .. days_left .. " Tage"
    elseif s[2] == "asche" then
      week_text = state.label .. "  ·  noch " .. days_left .. " Tage"
    end
    rows.woche:set({
      drawing = true,
      icon = { string = "Woche" },
      label = { string = week_text, color = state.color },
    })

    rows.fokus:set({
      drawing = feuer ~= nil and feuer[3] ~= "",
      icon = { string = "Fokus" },
      label = { string = feuer and truncate(feuer[3]) or "", color = colors.white },
    })

    rows.vorwoche:set({
      drawing = last_score ~= nil,
      icon = { string = "Vorwoche" },
      label = {
        string = last_score and ("W" .. last_week .. "  ·  " .. last_score .. "/100") or "",
        color = score_color(last_score),
      },
    })
    rows.schnitt:set({
      drawing = n > 0,
      icon = { string = "Ø Score" },
      label = {
        string = n > 0 and (avg:gsub("%.", ",") .. "  ·  " .. n .. " Wochen") or "",
        color = score_color(tonumber(avg)),
      },
    })

    -- Der Wochenverlauf als Symbolzeile, so wie er im Vault steht. Die
    -- Symbole sind die aus der Notiz; die Bar deutet sie nicht um.
    local strip = {}
    for i, w in ipairs(weeks) do strip[i] = w[3] ~= "" and w[3] or "·" end
    rows.verlauf:set({
      drawing = #weeks > 0,
      icon = { string = "Verlauf" },
      label = { string = table.concat(strip, " "), color = colors.white },
    })
  end)
end

phoenix:subscribe({ "routine", "forced", "system_woke" }, update)
update()
