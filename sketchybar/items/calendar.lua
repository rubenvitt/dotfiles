local settings = require("settings")
local colors = require("colors")
local icons = require("icons")

-- Uhr. Zwei Anzeigen in der Bar, Rechtsklick schaltet um (wird gemerkt):
--   dtg     – taktische Datums-Zeit-Gruppe ddHHMMmmmyy, z. B. 111423okt26
--   classic – Wochentag, Datum und Uhrzeit
-- Linksklick kopiert die angezeigte Zeit und öffnet ein Popup mit nächstem
-- Termin, Datum, Kalenderwoche, Tag im Jahr, DTG (lokal und Zulu) und dem
-- Monatskalender. Ein Klick auf eine Zeile kopiert ihren Wert.
--
-- Termin-Countdown: eine Stunde vor dem nächsten Termin erscheint links in
-- der Uhr-Insel eine kleine Pille (−42m). Ab 15 Minuten wird sie kräftiger
-- und die Insel färbt sich gelb, ab 5 Minuten rot, zum Beginn steht dort zwei
-- Minuten lang "jetzt". Die Termine liefert helpers/calendar/next_events, ein
-- eigener LaunchAgent (warum, steht dort); die Bar liest nur dessen Datei.
-- Klick auf die Pille öffnet Fantastical.

local MODE_DIR = os.getenv("HOME") .. "/.cache/sketchybar"
local MODE_FILE = MODE_DIR .. "/clock_mode"
local DEFAULT_MODE = "dtg"

local WEEKDAYS = { "Sonntag", "Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag" }
local MONTHS = { "Januar", "Februar", "März", "April", "Mai", "Juni", "Juli",
                 "August", "September", "Oktober", "November", "Dezember" }
local MONTHS_SHORT = { "jan", "feb", "mär", "apr", "mai", "jun",
                       "jul", "aug", "sep", "okt", "nov", "dez" }

local POPUP_WIDTH = 270
local CELL = 24          -- Zeilenhöhe im Popup (popup.height)
local GRID_ROWS = 6
-- Die KW-Spalte ist so schmal wie eine Tageszelle: ihr icon.background dient
-- per x_offset als Markierung für heute (Popup-Items werden auf ihre eigene
-- Zeile beschnitten, ein darübergelegtes Item ginge nicht).
local GRID_KW_WIDTH = 24
local GRID_KW_GAP = 14
local GRID_ADVANCE = 8.036   -- Vorschub SF Mono 13 pt
-- Feste Label-Breite: 20 Zeichen plus Rand für die Markierung am Sonntag.
-- Ohne sie zählt (wie in SketchyBar) nur die Tinte als Breite: führende
-- Leerzeichen verschieben den Text, das Ende wird abgeschnitten.
local GRID_LABEL_WIDTH = 166

local NEXT_FILE = MODE_DIR .. "/next_events"
local NEXT_WINDOW = 60 * 60   -- ab hier erscheint der Countdown
local NEXT_NOW = 2 * 60       -- so lange nach Beginn steht "jetzt" da
local NEXT_STALE = 60 * 60    -- älter: Helfer läuft nicht, nichts anzeigen
-- Feste Breite für fünf Zeichen ("jetzt", "−60m"), damit die Insel nicht
-- bei jedem Stellenwechsel springt.
local NEXT_WIDTH = 40

-- Farbe a zu t Anteilen in Richtung b gemischt (Alpha von a).
local function mix(a, b, t)
  local function ch(c, shift) return (c >> shift) & 0xff end
  local out = a & 0xff000000
  for _, shift in ipairs({ 16, 8, 0 }) do
    local v = math.floor(ch(a, shift) * (1 - t) + ch(b, shift) * t + 0.5)
    out = out | (v << shift)
  end
  return out
end

-- Stufen nach Minuten bis zum Beginn, von dringend nach entspannt.
local NEXT_STAGES = {
  { max = 0,  text = colors.black,  pill = colors.red,
    island = mix(colors.bg2, colors.red, 0.30), border = colors.red },
  { max = 5,  text = colors.red,    pill = colors.with_alpha(colors.red, 0.22),
    island = mix(colors.bg2, colors.red, 0.16), border = colors.red },
  { max = 15, text = colors.yellow, pill = colors.with_alpha(colors.yellow, 0.22),
    island = mix(colors.bg2, colors.yellow, 0.12), border = colors.yellow },
  { max = 60, text = colors.yellow, pill = colors.with_alpha(colors.yellow, 0.10),
    island = colors.bg2, border = colors.grey },
}

local function read_mode()
  local f = io.open(MODE_FILE, "r")
  if not f then return DEFAULT_MODE end
  local mode = (f:read("l") or ""):gsub("%s", "")
  f:close()
  return (mode == "classic" or mode == "dtg") and mode or DEFAULT_MODE
end

-- Kein os.execute/io.popen im Daemon (hängt nach dem ersten Fork, siehe
-- system_info.lua): das Verzeichnis legt sbar.exec beim Laden an.
sbar.exec("mkdir -p '" .. MODE_DIR .. "'")

local function write_mode(mode)
  local f = io.open(MODE_FILE, "w")
  if f then
    f:write(mode, "\n")
    f:close()
  end
end

local mode = read_mode()

-- ddHHMMmmmyy; zone steht zwischen Minuten und Monat (Z für Zulu).
local function dtg(t, zone)
  return string.format("%02d%02d%02d%s%s%02d",
    t.day, t.hour, t.min, zone or "", MONTHS_SHORT[t.month], t.year % 100)
end

local function copy(text)
  sbar.exec("printf %s '" .. text .. "' | LC_CTYPE=UTF-8 pbcopy")
end

-- Padding item required because of bracket
sbar.add("item", { position = "right", width = settings.group_paddings })

local cal = sbar.add("item", "clock", {
  icon = {
    color = colors.white,
    padding_left = 8,
    font = {
      style = settings.font.style_map["Black"],
      size = 12.0,
    },
  },
  label = {
    color = colors.white,
    padding_right = 8,
    align = "right",
    font = { family = settings.font.numbers },
  },
  position = "right",
  update_freq = 30,
  padding_left = 1,
  padding_right = 1,
  -- Die Füllung trägt die Insel-Klammer, damit die Countdown-Pille mit drin
  -- sitzt.
  background = { drawing = false },
  popup = { align = "right", height = CELL },
})

local next_pill = sbar.add("item", "clock.next", {
  position = "right",
  drawing = false,
  padding_left = 6,
  padding_right = 0,
  icon = { drawing = false },
  label = {
    width = NEXT_WIDTH,
    align = "center",
    padding_left = 0,
    padding_right = 0,
    font = {
      family = settings.font.numbers,
      style = settings.font.style_map["Heavy"],
      size = 10.0,
    },
  },
  background = { height = 16, corner_radius = 8, border_width = 0 },
})

-- Doppelter Rand: innen die Füllung mit dunklem Strich, außen der graue
-- Rahmen, der sich mit dem Countdown einfärbt.
local island = sbar.add("bracket", "clock.island", { cal.name, next_pill.name }, {
  background = {
    color = colors.bg2,
    border_color = colors.black,
    border_width = 1,
  }
})
local frame = sbar.add("bracket", "clock.frame", { cal.name, next_pill.name }, {
  background = {
    color = colors.transparent,
    height = 30,
    border_color = colors.grey,
  }
})

-- Padding item required because of bracket
sbar.add("item", { position = "right", width = settings.group_paddings })

-- Popup ----------------------------------------------------------------------

local popup_pos = "popup." .. cal.name

local header = sbar.add("item", "clock.header", {
  position = popup_pos,
  width = POPUP_WIDTH,
  icon = {
    string = icons.clock.calendar,
    font = { style = settings.font.style_map["Bold"], size = 14.0 },
  },
  label = {
    font = { style = settings.font.style_map["Bold"], size = 14.0 },
  },
  background = { height = 2, color = colors.grey, y_offset = -(CELL / 2 + 2) },
})

local function info_row(name, title, mono)
  return sbar.add("item", name, {
    position = popup_pos,
    icon = {
      string = title,
      width = POPUP_WIDTH / 2,
      align = "left",
      color = colors.grey,
      font = { style = settings.font.style_map["Semibold"], size = 13.0 },
    },
    label = {
      width = POPUP_WIDTH / 2,
      align = "right",
      font = mono and { family = settings.font.numbers, style = settings.font.style_map["Bold"], size = 13.0 }
        or { style = settings.font.style_map["Semibold"], size = 13.0 },
    },
  })
end

-- Nächster Termin: Titel links, Beginn rechts; ohne Termin ausgeblendet.
local next_row = sbar.add("item", "clock.next.row", {
  position = popup_pos,
  drawing = false,
  icon = {
    width = POPUP_WIDTH - 60,
    align = "left",
    max_chars = 30,
    font = { style = settings.font.style_map["Semibold"], size = 13.0 },
  },
  label = {
    width = 60,
    align = "right",
    font = { family = settings.font.numbers, style = settings.font.style_map["Bold"], size = 13.0 },
  },
})

local week_row = info_row("clock.week", "Kalenderwoche")
local day_row = info_row("clock.day", "Tag im Jahr")
local dtg_row = info_row("clock.dtg", "DTG", true)
local zulu_row = info_row("clock.zulu", "DTG Zulu", true)

-- Monatskalender in SF Mono: Spalte KW im Icon, sieben Tage im Label.
local grid_font = { family = settings.font.numbers, style = settings.font.style_map["Regular"], size = 13.0 }

local function grid_item(name, props)
  local base = {
    position = popup_pos,
    padding_left = 24,
    icon = {
      width = GRID_KW_WIDTH,
      align = "left",
      color = colors.grey,
      padding_left = 8,
      padding_right = 0,   -- bei fester Breite ohne Wirkung, Abstand im Label
      font = grid_font,
      background = {
        drawing = false,
        color = colors.with_alpha(colors.orange, 0.55),
        height = CELL - 6,
        corner_radius = 6,
        border_width = 0,
      },
    },
    label = {
      width = GRID_KW_GAP + GRID_LABEL_WIDTH,   -- feste Breite schließt das Padding ein
      align = "left",
      padding_left = GRID_KW_GAP,
      padding_right = 8,
      font = grid_font,
    },
    background = { color = colors.transparent, border_width = 0, height = CELL - 4, corner_radius = 6 },
  }
  for k, v in pairs(props or {}) do
    if type(v) == "table" and type(base[k]) == "table" then
      for kk, vv in pairs(v) do base[k][kk] = vv end
    else
      base[k] = v
    end
  end
  return sbar.add("item", name, base)
end

grid_item("clock.grid.head", {
  icon = { string = "KW" },
  label = { string = "Mo Di Mi Do Fr Sa So", color = colors.grey },
})

local grid = {}
for i = 1, GRID_ROWS do
  grid[i] = grid_item("clock.grid." .. i)
end

local function render_popup()
  local now = os.time()
  local t = os.date("*t", now)
  local u = os.date("!*t", now)
  local days_in_year = os.date("*t", os.time({ year = t.year, month = 12, day = 31, hour = 12 })).yday

  header:set({
    label = string.format("%s, %d. %s %d", WEEKDAYS[t.wday], t.day, MONTHS[t.month], t.year),
  })
  week_row:set({ label = "KW " .. tonumber(os.date("%V", now)) })
  day_row:set({ label = string.format("%d von %d", t.yday, days_in_year) })
  dtg_row:set({
    icon = t.isdst and "DTG (MESZ)" or "DTG (MEZ)",
    label = dtg(t),
  })
  zulu_row:set({ label = dtg(u, "Z") })

  local first = os.time({ year = t.year, month = t.month, day = 1, hour = 12 })
  local days_in_month = os.date("*t", os.time({ year = t.year, month = t.month + 1, day = 0, hour = 12 })).day
  local lead = (os.date("*t", first).wday + 5) % 7   -- Montag = 0
  local today_index = lead + t.day - 1
  local today_row = today_index // 7 + 1
  local today_col = today_index % 7

  for r = 1, GRID_ROWS do
    local start = (r - 1) * 7 - lead + 1          -- Tag im Monat am Montag
    if start > days_in_month then
      grid[r]:set({ drawing = false })
    else
      local cells = {}
      for c = 0, 6 do
        local d = start + c
        local in_month = d >= 1 and d <= days_in_month
        cells[c + 1] = in_month and string.format("%2d", d) or "  "
      end
      local monday = os.time({ year = t.year, month = t.month, day = start, hour = 12 })
      local current = r == today_row
      grid[r]:set({
        drawing = true,
        icon = {
          string = tostring(tonumber(os.date("%V", monday))),
          color = current and colors.orange or colors.grey,
          background = {
            drawing = current,
            -- Von der Mitte des KW-Felds zur Mitte der heutigen Zelle
            -- (zwei Zeichen ab Zeichen 3 * Spalte).
            x_offset = math.floor(GRID_KW_WIDTH / 2 + GRID_KW_GAP
              + (today_col * 3 + 1) * GRID_ADVANCE + 0.5),
          },
        },
        label = table.concat(cells, " "),
        background = { color = current and colors.bg2 or colors.transparent },
      })
    end
  end
end

-- Termin-Countdown -------------------------------------------------------------

local function fields(line)
  local out = {}
  for f in (line .. "|"):gmatch("([^|]*)|") do out[#out + 1] = f end
  return out
end

-- Nächster Termin aus der Datei des Helfers, der noch nicht länger als
-- NEXT_NOW läuft; nil, wenn keiner da ist oder die Datei veraltet ist.
local function next_event(now)
  local f = io.open(NEXT_FILE, "r")
  if not f then return nil end
  local found, fresh = nil, false
  for line in f:lines() do
    local v = fields(line)
    if v[1] == "T" then
      fresh = v[3] == "ok" and now - (tonumber(v[2]) or 0) <= NEXT_STALE
    elseif v[1] == "E" and not found then
      local start = tonumber(v[2])
      if start and start - now > -NEXT_NOW then
        found = { start = start, title = table.concat(v, "|", 4) }
      end
    end
  end
  f:close()
  return fresh and found or nil
end

local function render_next()
  local now = os.time()
  local event = next_event(now)
  local diff = event and event.start - now
  local minutes = diff and math.max(0, math.ceil(diff / 60))
  local stage
  if diff and diff <= NEXT_WINDOW then
    for _, s in ipairs(NEXT_STAGES) do
      if minutes <= s.max then stage = s break end
    end
  end

  if stage then
    next_pill:set({
      drawing = true,
      label = { string = minutes == 0 and "jetzt" or ("−" .. minutes .. "m"), color = stage.text },
      background = { color = stage.pill },
    })
  else
    next_pill:set({ drawing = false })
  end
  island:set({ background = { color = stage and stage.island or colors.bg2 } })
  frame:set({ background = { border_color = stage and stage.border or colors.grey } })

  if event then
    next_row:set({
      drawing = true,
      icon = event.title,
      label = os.date("%H:%M", event.start),
    })
  else
    next_row:set({ drawing = false })
  end
end

-- Bar ------------------------------------------------------------------------

local popup_open = false

-- Was die Bar gerade zeigt: Icon (nur klassisch) und Label.
local function bar_text()
  if mode == "dtg" then return nil, dtg(os.date("*t")) end
  local date_fmt = settings.compact and "%a %d.%m." or "%a. %d %b."
  return os.date(date_fmt), os.date("%H:%M")
end

local function update()
  local date, time = bar_text()
  if mode == "dtg" then
    cal:set({
      icon = { drawing = false },
      label = { string = time, width = "dynamic", padding_left = 8 },
    })
  else
    cal:set({
      icon = { drawing = true, string = date },
      label = { string = time, width = 49, padding_left = settings.paddings },
    })
  end
  render_next()
  if popup_open then render_popup() end
end

-- Pünktlich zur vollen Minute aktualisieren statt bis zu 30 s zu spät;
-- routine bleibt als Rückfallebene (z. B. nach dem Aufwachen).
local function schedule_minute()
  local sec = os.date("*t").sec
  sbar.delay(60 - sec + 0.05, function()
    update()
    schedule_minute()
  end)
end

cal:subscribe({ "forced", "routine", "system_woke" }, update)

cal:subscribe("mouse.clicked", function(env)
  if env.BUTTON == "right" then
    mode = mode == "dtg" and "classic" or "dtg"
    write_mode(mode)
    update()
    return
  end
  local date, time = bar_text()
  copy(date and (date .. " " .. time) or time)
  popup_open = not popup_open
  if popup_open then render_popup() end
  cal:set({ popup = { drawing = popup_open } })
end)

cal:subscribe("mouse.exited.global", function()
  popup_open = false
  cal:set({ popup = { drawing = false } })
end)

next_pill:subscribe("mouse.clicked", function()
  sbar.exec("open -a Fantastical")
end)

-- Klick auf eine Popup-Zeile kopiert ihren Wert.
header:subscribe("mouse.clicked", function() copy(os.date("%Y-%m-%d")) end)
for _, row in ipairs({ week_row, day_row, dtg_row, zulu_row }) do
  row:subscribe("mouse.clicked", function(env)
    copy(sbar.query(env.NAME).label.value)
  end)
end

render_popup()
update()
schedule_minute()
