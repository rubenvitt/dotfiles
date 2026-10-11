local settings = require("settings")
local colors = require("colors")
local icons = require("icons")

-- Uhr. Zwei Anzeigen in der Bar, Rechtsklick schaltet um (wird gemerkt):
--   dtg     – taktische Datums-Zeit-Gruppe ddHHMMmmmyy, z. B. 111423okt26
--   classic – Wochentag, Datum und Uhrzeit
-- Linksklick öffnet ein Popup mit Datum, Kalenderwoche, Tag im Jahr, DTG
-- (lokal und Zulu) und dem Monatskalender. Ein Klick auf eine Zeile kopiert
-- ihren Wert.

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
-- Ohne sie misst mbar den Text ohne führende Leerzeichen und schneidet das
-- Ende ab.
local GRID_LABEL_WIDTH = 166

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

local cal = sbar.add("item", {
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
  background = {
    color = colors.bg2,
    border_color = colors.black,
    border_width = 1
  },
  popup = { align = "right", height = CELL },
})

-- Double border for calendar using a single item bracket
sbar.add("bracket", { cal.name }, {
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

-- Bar ------------------------------------------------------------------------

local popup_open = false

local function update()
  local t = os.date("*t")
  if mode == "dtg" then
    cal:set({
      icon = { drawing = false },
      label = { string = dtg(t), width = "dynamic", padding_left = 8 },
    })
  else
    local date_fmt = settings.compact and "%a %d.%m." or "%a. %d %b."
    cal:set({
      icon = { drawing = true, string = os.date(date_fmt) },
      label = { string = os.date("%H:%M"), width = 49, padding_left = settings.paddings },
    })
  end
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
  popup_open = not popup_open
  if popup_open then render_popup() end
  cal:set({ popup = { drawing = popup_open } })
end)

cal:subscribe("mouse.exited.global", function()
  popup_open = false
  cal:set({ popup = { drawing = false } })
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
